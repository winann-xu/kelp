#!/usr/bin/env python3
"""海带 (Kelp) 组网只读面板 —— 后端

设计要点：
- 仅用 Python 标准库（无第三方依赖），单进程 + 后台轮询线程 + HTTP 服务
- 数据源：各节点 EasyTier 的 RPC（easytier-cli -p <addr>:15888 -o json peer/node）
- 只读：不向节点下发任何配置；不落库（内存快照 + 最后在线时间）
- 安全：HTTP Basic 认证；`node` 返回的 config 字段含网络密钥，解析时立即丢弃
"""
from __future__ import annotations

import base64
import hashlib
import ssl
import hmac
import json
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from panel_admin import (ADMIN_HTML, change_panel_password, current_secret, rotate_secret,
                         validate_password, validate_secret, verify_password)

CONFIG_PATH = Path(os.environ.get("KELP_PANEL_CONFIG", "/etc/kelp/panel.json"))
UI_PATH = Path(os.environ.get("KELP_PANEL_UI", "/opt/kelp/panel_ui.html"))
DOWNLOAD_DIR = Path(os.environ.get("KELP_DOWNLOAD_DIR", "/opt/kelp/downloads"))
PRIVATE_DIR = Path(os.environ.get("KELP_PRIVATE_DIR", "/opt/kelp/private"))
CLI = os.environ.get("KELP_EASYTIER_CLI", "/usr/local/bin/easytier-cli")
CST = timezone(timedelta(hours=8))

CONFIG: dict = {}
STATE: dict = {"generated_at": None, "nodes": [], "devices": [], "summary": {}}
STATE_LOCK = threading.Lock()
LAST_SEEN: dict[str, str] = {}

# 省流量：无人访问时不再经组网去问远端节点的 RPC（空转出网 = 公网节点计费）
# 本机(127.0.0.1)节点始终刷新——它不产生公网流量
IDLE_AFTER = float(os.environ.get("KELP_IDLE_AFTER", "120"))
VIEWERS = {"last": time.time()}
LAST_REC: dict = {}

# ---------------------------------------------------------------- 配置


def load_config() -> dict:
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    cfg.setdefault("listen", "0.0.0.0")
    cfg.setdefault("port", 18080)
    cfg.setdefault("poll_interval", 5)
    cfg.setdefault("cli_timeout", 6)
    cfg.setdefault("devices", [])
    cfg.setdefault("traffic", {})
    cfg["traffic"].setdefault("alert_gb_per_day", 5.0)
    cfg["traffic"].setdefault("price_per_gb", 0.8)
    cfg["traffic"].setdefault("state_file", "/var/lib/kelp/traffic.json")
    return cfg


def password_ok(user: str, password: str) -> bool:
    auth = CONFIG.get("auth", {})
    if not auth:
        return False
    salt = str(auth.get("salt", ""))
    want = str(auth.get("sha256", ""))
    got = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return hmac.compare_digest(str(auth.get("user", "")), user) and hmac.compare_digest(want, got)


# ---------------------------------------------------------------- 采集


def run_cli(rpc: str, *args: str, timeout: int = 6) -> tuple[bool, object]:
    """调用 easytier-cli，返回 (是否成功, 解析后的 JSON 或错误文本)"""
    cmd = [CLI, "-p", rpc, "-o", "json", *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "RPC 超时"
    except FileNotFoundError:
        return False, "找不到 easytier-cli"
    if proc.returncode != 0:
        return False, (proc.stderr or proc.stdout or "RPC 失败").strip()[:200]
    try:
        return True, json.loads(proc.stdout or "null")
    except json.JSONDecodeError as exc:
        return False, f"JSON 解析失败: {exc}"


def summarize_listeners(items: list[str]) -> str:
    """把 tcp://0.0.0.0:11010、udp://[::]:11010 之类压成 TCP/UDP :11010 · WS :11011 的紧凑形式。"""
    seen: dict[tuple[str, str], None] = {}
    order: list[tuple[str, str]] = []
    for item in items:
        m = re.match(r"([a-z0-9]+)://(?:\[[^\]]+\]|[0-9.]+):(\d+)", item)
        if not m:
            continue
        proto, port = m.group(1).upper(), m.group(2)
        key = (proto, port)
        if key not in seen:
            seen[key] = None
            order.append(key)
    merged: dict[str, list[str]] = {}
    for proto, port in order:
        merged.setdefault(port, []).append(proto)
    # 用不换行空格连接协议与端口，避免浏览器把 "WSS/QUIC" 与 ":11012" 拆到两行
    return " · ".join(f"{'/'.join(protos)}\u00A0:{port}" for port, protos in merged.items())


def sanitize_node_info(info: object) -> dict:
    """保留展示所需字段，丢弃含网络密钥的 config"""
    if not isinstance(info, dict):
        return {}
    stun = info.get("stun_info") or {}
    nat_map = {0: "Unknown", 1: "OpenInternet", 2: "NoPAT", 3: "FullCone",
               4: "Restricted", 5: "PortRestricted", 6: "Symmetric"}
    return {
        "hostname": info.get("hostname", ""),
        "ipv4_addr": info.get("ipv4_addr", ""),
        "proxy_cidrs": info.get("proxy_cidrs") or [],
        "listeners": summarize_listeners([x for x in (info.get("listeners") or [])
                                          if not x.startswith("ring://")]),
        "public_ip": stun.get("public_ip") or [],
        "nat_type": nat_map.get(int(stun.get("udp_nat_type", 0)), "Unknown"),
        "version": info.get("version", ""),
        "peer_id": info.get("peer_id"),
    }


def pick(value: object, pattern: str) -> str:
    m = re.search(pattern, str(value))
    return m.group(0) if m else str(value)


def parse_metrics(peer: dict) -> dict:
    return {
        "cost": str(peer.get("cost", "-")),
        "lat_ms": str(peer.get("lat_ms", "-")),
        "loss": str(peer.get("loss_rate", "-")),
        "rx": pick(peer.get("rx_bytes", "-"), r"[0-9.]+ ?[kMG]?B"),
        "tx": pick(peer.get("tx_bytes", "-"), r"[0-9.]+ ?[kMG]?B"),
        "tunnel": str(peer.get("tunnel_proto", "-")),
        "nat": str(peer.get("nat_type", "-")),
        "version": str(peer.get("version", "-")),
    }


def collect_portal(rpc: str, record: dict) -> None:
    """采集 WireGuard 门户的已接入客户端。注意：client_config 内含客户端私钥，绝不外传。"""
    ok, info = run_cli(rpc, "vpn-portal")
    if not ok or not isinstance(info, dict):
        record["portal"] = {"ok": False, "error": str(info)[:120]}
        return
    clients = [str(c) for c in (info.get("connected_clients") or [])]
    record["portal"] = {"ok": True, "type": str(info.get("vpn_type", "wireguard")),
                        "count": len(clients), "clients": clients[:20]}


def human_rate(text: str) -> float:
    m = re.match(r"([0-9.]+) ?([kMG]?)B", text.strip())
    if not m:
        return 0.0
    value = float(m.group(1))
    return value * {"": 1, "k": 1e3, "M": 1e6, "G": 1e9}[m.group(2)]


def human_bytes(value: float) -> str:
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if value < 1000 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1000
    return f"{value:.2f} TB"


# ---------------------------------------------------------------- 流量护栏


def read_egress_bytes() -> int:
    """本机所有非 lo 接口的累计发出字节。阿里云按"公网出网流量"计费，故只看出方向。"""
    total = 0
    try:
        for line in Path("/proc/net/dev").read_text().splitlines()[2:]:
            name, _, rest = line.partition(":")
            if not rest or name.strip() == "lo":
                continue
            fields = rest.split()
            if len(fields) >= 9:
                total += int(fields[8])  # tx bytes
    except Exception:
        return -1
    return total


def update_traffic(now: datetime) -> dict:
    """统计"今日/本月"出网流量，超阈值即告警（FR7 流量护栏，替代云监控控制台）。"""
    tr = CONFIG["traffic"]
    path = Path(tr["state_file"])
    state: dict = {}
    if path.exists():
        try:
            state = json.loads(path.read_text())
        except Exception:
            state = {}
    tx = read_egress_bytes()
    if tx < 0:
        return {"available": False}
    day, month = now.strftime("%Y-%m-%d"), now.strftime("%Y-%m")
    if state.get("day") != day:
        state["day"] = day
        state["day_base"] = state.get("last_tx", tx)
    if state.get("month") != month:
        state["month"] = month
        state["month_base"] = state.get("last_tx", tx)
    state.setdefault("day_base", tx)
    state.setdefault("month_base", tx)
    state["last_tx"] = tx
    state["checked_at"] = now.isoformat(timespec="seconds")
    day_bytes = max(0, tx - int(state["day_base"]))
    month_bytes = max(0, tx - int(state["month_base"]))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state))
    except Exception:
        pass
    limit_bytes = float(tr["alert_gb_per_day"]) * 1e9
    price = float(tr["price_per_gb"])
    return {
        "available": True,
        "day_bytes": day_bytes,
        "month_bytes": month_bytes,
        "day": human_bytes(day_bytes),
        "month": human_bytes(month_bytes),
        "limit": f"{tr['alert_gb_per_day']:g} GB/日",
        "price_per_gb": price,
        "day_cost": round(day_bytes / 1e9 * price, 2),
        "month_cost": round(month_bytes / 1e9 * price, 2),
        "alert": day_bytes > limit_bytes,
    }


def collect_node(node_conf: dict) -> dict:
    """采集单个节点的自述信息与邻居表"""
    name = node_conf.get("name") or node_conf.get("key") or node_conf.get("rpc", "?")
    rpc = node_conf.get("rpc", "")
    record = {
        "key": node_conf.get("key", rpc),
        "name": name,
        "rpc": rpc,
        "note": node_conf.get("note", ""),
        "portal_enabled": bool(node_conf.get("vpn_portal")),
        "hostname": node_conf.get("hostname", ""),
        "online": False,
        "error": "",
        "peers": [],
        "self": {},
    }
    ok, info = run_cli(rpc, "node", timeout=CONFIG["cli_timeout"])
    if ok:
        record["online"] = True
        record["self"] = sanitize_node_info(info)
        if not record["hostname"]:
            record["hostname"] = record["self"].get("hostname", "")
    else:
        record["error"] = str(info)
    ok, peers = run_cli(rpc, "peer", timeout=CONFIG["cli_timeout"])
    if ok and isinstance(peers, list):
        record["online"] = True
        record["peers"] = [parse_metrics(p) | {"ipv4": p.get("ipv4", ""), "hostname": p.get("hostname", "")}
                           for p in peers]
    elif not record["error"]:
        record["error"] = str(peers)
    return record


COST_RANK = {"Local": 0, "p2p": 1, "-": 1}


def cost_rank(cost: object) -> int:
    """路径优劣排序：Local < p2p（含未知）< 中继等（越大越差，越需要暴露）。"""
    if cost is None:
        return 1
    return COST_RANK.get(str(cost), 2)


def merge_devices(nodes: list[dict]) -> tuple[list[dict], dict]:
    """把各节点视角的邻居表合并成统一设备列表（同一设备取最新指标）"""
    now = datetime.now(CST).strftime("%H:%M:%S")
    by_ip: dict[str, dict] = {}
    for node in nodes:
        for peer in node["peers"]:
            ip = peer["ipv4"]
            if not ip:
                continue
            item = by_ip.setdefault(ip, {"ipv4": ip, "hostname": peer["hostname"], "seen_by": []})
            item["hostname"] = item["hostname"] or peer["hostname"]
            item["seen_by"].append(node["name"])
            # 保守取值：只要有任一采集节点报告"更差"的路径（例如 relay），就用它覆盖。
            # 原因：hub 通常看到的是 p2p，而两站点之间可能已在走中继（要计费），取最优会漏报。
            if cost_rank(peer["cost"]) > cost_rank(item.get("cost")) or item.get("cost") is None:
                item.update(peer)
                item["cost_from"] = node["name"]
            if peer["cost"] != "Local":
                LAST_SEEN[ip] = now
    devices = []
    for spec in CONFIG["devices"]:
        ip = spec.get("ipv4", "")
        live = by_ip.get(ip, {})
        if live.get("cost"):
            LAST_SEEN[ip] = now
        devices.append({
            "ipv4": ip,
            "hostname": live.get("hostname") or spec.get("hostname", ""),
            "label": spec.get("label", ""),
            "role": spec.get("role", ""),
            "expect": bool(spec.get("expect", True)),
            "online": bool(live.get("cost")),
            "cost": live.get("cost", "-"),
            "lat_ms": live.get("lat_ms", "-"),
            "loss": live.get("loss", "-"),
            "rx": live.get("rx", "-"),
            "tx": live.get("tx", "-"),
            "tunnel": live.get("tunnel", "-"),
            "nat": live.get("nat", "-"),
            "version": live.get("version", "-"),
            "cost_from": live.get("cost_from", ""),
            "last_seen": LAST_SEEN.get(ip, ""),
        })
    known = {d["ipv4"] for d in devices}
    for ip, live in by_ip.items():
        if ip in known or not live.get("cost"):
            continue
        devices.append({
            "ipv4": ip, "hostname": live.get("hostname", ""), "label": "", "role": "",
            "expect": False, "online": True, "cost": live.get("cost", "-"),
            "lat_ms": live.get("lat_ms", "-"), "loss": live.get("loss", "-"),
            "rx": live.get("rx", "-"), "tx": live.get("tx", "-"),
            "tunnel": live.get("tunnel", "-"), "nat": live.get("nat", "-"),
            "version": live.get("version", "-"), "last_seen": LAST_SEEN.get(ip, ""),
        })
    online = [d for d in devices if d["online"]]
    summary = {
        "total": len(devices),
        "online": len(online),
        "expect": len([d for d in devices if d["expect"] and d["online"]]),
        "expect_total": len([d for d in devices if d["expect"]]),
        "p2p": len([d for d in online if d["cost"] == "p2p"]),
        "relay": len([d for d in online if d["cost"] not in ("p2p", "Local", "-")]),
        "rx_total": sum(human_rate(d["rx"]) for d in online),
        "tx_total": sum(human_rate(d["tx"]) for d in online),
    }
    return devices, summary


def refresh_once(force: bool = False) -> None:
    idle = (not force) and (time.time() - VIEWERS["last"]) > IDLE_AFTER
    nodes = []
    for n in CONFIG["nodes"]:
        key = str(n.get("key", n.get("name", "")))
        rpc = str(n.get("rpc", ""))
        is_local = rpc.startswith("127.0.0.1") or rpc.startswith("localhost")
        if idle and not is_local and key in LAST_REC:
            # 无人看页面：远端节点沿用上次结果，省下公网出网流量
            rec = dict(LAST_REC[key])
            rec["stale"] = True
            nodes.append(rec)
            continue
        rec = collect_node(n)
        if n.get("vpn_portal"):
            collect_portal(rpc, rec)
        rec["stale"] = False
        LAST_REC[key] = rec
        nodes.append(rec)
    devices, summary = merge_devices(nodes)
    summary["rx_total"] = human_bytes(summary["rx_total"])
    summary["tx_total"] = human_bytes(summary["tx_total"])
    with STATE_LOCK:
        STATE.update({
            "generated_at": datetime.now(CST).strftime("%Y-%m-%d %H:%M:%S"),
            "nodes": nodes,
            "devices": devices,
            "summary": summary,
            "network": CONFIG.get("network_name", ""),
            "poll_interval": CONFIG["poll_interval"],
            "traffic": update_traffic(datetime.now(CST)),
            "mobile": mobile_summary(nodes),
        })


def mobile_summary(nodes: list[dict]) -> dict:
    clients: list[dict] = []
    for n in nodes:
        portal = n.get("portal") or {}
        if not portal.get("ok"):
            continue
        for c in portal.get("clients", []):
            clients.append({"via": n.get("name", ""), "addr": c})
    return {"count": len(clients), "clients": clients, "enabled": any(n.get("portal_enabled") for n in nodes)}


def poller() -> None:
    while True:
        try:
            refresh_once()
        except Exception as exc:  # 保活：任何异常都不能让面板线程死掉
            with STATE_LOCK:
                STATE["last_error"] = f"{type(exc).__name__}: {exc}"
        time.sleep(CONFIG["poll_interval"])


# ---------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "kelp-panel"

    def log_message(self, format, *args):  # noqa: A002  保持 journal 干净
        return

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(header[6:]).decode("utf-8")
        except Exception:
            return False
        user, _, password = raw.partition(":")
        return password_ok(user, password)

    def reply(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def reject(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Kelp", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ------------------------------------------------------ 管理动作（可写）

    def read_json(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return {}
        if length <= 0 or length > 8192:
            return {}
        try:
            raw = self.rfile.read(length)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def json_reply(self, payload: dict, code: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0]
        if not self.authorized():
            return self.reject()
        if path not in ("/admin/password", "/admin/secret"):
            return self.reply(404, b"not found", "text/plain; charset=utf-8")

        data = self.read_json()
        user = CONFIG.get("auth", {}).get("user", "")
        # 表单里必须带当前口令：既是二次确认，也顺带挡掉跨站表单伪造
        given = data.get("old_password") or data.get("password") or ""
        if not verify_password(user, given):
            return self.json_reply({"ok": False, "error": "当前口令不正确"}, 403)

        if path == "/admin/password":
            new_pw = str(data.get("new_password", ""))
            err = validate_password(new_pw)
            if err:
                return self.json_reply({"ok": False, "error": err}, 400)
            if new_pw == given:
                return self.json_reply({"ok": False, "error": "新口令与当前口令相同"}, 400)
            try:
                return self.json_reply(change_panel_password(new_pw))
            except Exception as exc:
                return self.json_reply({"ok": False, "error": f"写入配置失败: {exc}"}, 500)

        new_secret = str(data.get("new_secret", ""))
        err = validate_secret(new_secret)
        if err:
            return self.json_reply({"ok": False, "error": err}, 400)
        if new_secret == current_secret():
            return self.json_reply({"ok": False, "error": "新密钥与当前相同"}, 400)
        try:
            return self.json_reply(rotate_secret(new_secret))
        except Exception as exc:
            return self.json_reply({"ok": False, "error": f"轮换失败: {exc}"}, 500)

    # ------------------------------------------------------ 下载页（公开）

    DL_TYPES = {".exe": "application/octet-stream", ".dmg": "application/octet-stream",
                ".apk": "application/vnd.android.package-archive", ".zip": "application/zip",
                ".png": "image/png", ".txt": "text/plain; charset=utf-8",
                ".conf": "text/plain; charset=utf-8", ".html": "text/html; charset=utf-8"}

    def serve_downloads(self, path: str) -> None:
        rel = path[len("/dl"):].lstrip("/")
        if not rel:
            return self.reply(200, download_index(DOWNLOAD_DIR).encode("utf-8"),
                              "text/html; charset=utf-8")
        target = (DOWNLOAD_DIR / rel).resolve()
        if not str(target).startswith(str(DOWNLOAD_DIR.resolve())) or not target.is_file():
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        ctype = self.DL_TYPES.get(target.suffix.lower(), "application/octet-stream")
        size = target.stat().st_size

        # 支持 Range（断点续传 / 手机浏览器分段下载）
        start, end = 0, size - 1
        partial = False
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            spec = rng[6:].split(",")[0].strip()
            a, _, b = spec.partition("-")
            if a.isdigit():
                start = int(a)
                if b.isdigit():
                    end = min(int(b), size - 1)
            elif b.isdigit():
                start = max(0, size - int(b))
            if 0 <= start <= end < size:
                partial = True
            else:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Content-Disposition", f'attachment; filename="{target.name}"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command == "HEAD":
            return
        remaining = end - start + 1
        with target.open("rb") as fh:
            fh.seek(start)
            while remaining > 0:
                chunk = fh.read(min(262144, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                self.wfile.write(chunk)

    def serve_private(self, path: str) -> None:
        """鉴权区：WireGuard 手机配置与二维码（含私钥，必须认证后可见）"""
        name = Path(path[len("/wg/"):]).name
        target = PRIVATE_DIR / name
        if not target.is_file():
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        ctype = self.DL_TYPES.get(target.suffix.lower(), "text/plain; charset=utf-8")
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):  # noqa: N802  各写出函数均按 self.command 判断是否写正文
        return self.do_GET()

    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path == "/dl" or path.startswith("/dl/"):
            return self.serve_downloads(path)
        if not self.authorized():
            return self.reject()
        if path.startswith("/wg/"):
            return self.serve_private(path)
        if path in ("/", "/index.html"):
            VIEWERS["last"] = time.time()
            body = UI_PATH.read_bytes() if UI_PATH.exists() else b"<h1>UI missing</h1>"
            return self.reply(200, body, "text/html; charset=utf-8")
        if path == "/api/status":
            was_idle = (time.time() - VIEWERS["last"]) > IDLE_AFTER
            VIEWERS["last"] = time.time()
            if was_idle:
                try:
                    refresh_once(force=True)   # 有人来了：立刻取一次最新数据，避免首屏是旧值
                except Exception:
                    pass
            with STATE_LOCK:
                payload = json.dumps(STATE, ensure_ascii=False).encode("utf-8")
            return self.reply(200, payload, "application/json; charset=utf-8")
        if path == "/admin":
            return self.reply(200, ADMIN_HTML.encode("utf-8"), "text/html; charset=utf-8")
        if path == "/healthz":
            return self.reply(200, b'{"ok":true}', "application/json")
        return self.reply(404, b"not found", "text/plain; charset=utf-8")


DL_PAGE_CSS = """
  :root{--bg:#080c18;--card:#141b2f;--card2:#1a2338;--line:#243050;--txt:#e8edf9;
        --dim:#8d9ab5;--dim2:#67748f;--ok:#35e08b;--accent:#5b8cff;--warn:#ffc453}
  *{box-sizing:border-box}
  body{margin:0;padding:26px 16px 60px;background:radial-gradient(1000px 500px at 15% -10%,#16224a 0,transparent 60%),
       radial-gradient(800px 420px at 110% 5%,#123a3a 0,transparent 55%),var(--bg);
       color:var(--txt);font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;min-height:100vh}
  .wrap{max-width:900px;margin:0 auto}
  h1{font-size:22px;margin:0 0 6px} h1 span{color:var(--accent)}
  .sub{color:var(--dim);font-size:13.5px;margin-bottom:20px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px 18px;margin-bottom:14px;
        box-shadow:0 10px 30px rgba(0,0,0,.35)}
  .card h2{font-size:16px;margin:0 0 4px;display:flex;align-items:center;gap:8px}
  .badge{font-size:11.5px;border-radius:8px;padding:2px 8px;border:1px solid var(--line);color:var(--dim);background:var(--card2)}
  .badge.p2p{color:#0a1a12;background:var(--ok);border-color:transparent;font-weight:650}
  .badge.paid{color:#241c05;background:var(--warn);border-color:transparent;font-weight:650}
  .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:8px 0;border-top:1px dashed var(--line)}
  .row:first-of-type{border-top:0}
  .fname{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;color:var(--dim)}
  .size{font-size:12px;color:var(--dim2);margin-left:auto}
  a.btn{display:inline-flex;align-items:center;gap:6px;text-decoration:none;font-size:13.5px;font-weight:600;
        color:#0a1a12;background:var(--ok);border-radius:10px;padding:7px 13px}
  a.btn.alt{background:var(--accent);color:#06122b}
  a.btn.line{background:transparent;border:1px solid var(--line);color:var(--txt);font-weight:500}
  .note{margin-top:20px;color:var(--dim);font-size:13px}
  .note code{background:var(--card2);border:1px solid var(--line);border-radius:6px;padding:1px 6px;font-size:12.5px}
  .sum{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:var(--dim2);
       margin-left:auto;word-break:break-all;max-width:62%;text-align:right}
  .qr{display:flex;align-items:center;gap:14px}
  .qr img{width:132px;height:132px;background:#fff;padding:6px;border-radius:10px}
"""


def human_size(n: float) -> str:
    """1024 进制的人类可读大小。注意：每轮只除一次，别再在返回语句里除第二次。"""
    for unit in ("B", "kB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def dl_row(label: str, filename: str, note: str = "") -> str:
    f = DOWNLOAD_DIR / filename
    if not f.is_file():
        return ""
    size = human_size(f.stat().st_size)
    return (f'<div class="row"><a class="btn" href="/dl/{filename}">下载</a>'
            f'<b>{label}</b><span class="fname">{filename}</span>'
            f'<span class="size">{size}</span></div>')


def download_index(dl_dir: Path) -> str:
    rows_android = "".join([
        dl_row("Android 64 位（绝大多数手机）", "app-arm64-release.apk"),
        dl_row("Android 32 位（老设备备用）", "app-arm-release.apk"),
    ])
    rows_pc = "".join([
        dl_row("Windows 图形界面（推荐）", "easytier-gui_2.6.4_x64-setup.exe"),
        dl_row("Windows 命令行版（服务端 / 进阶）", "easytier-windows-x86_64-v2.6.4.zip"),
        dl_row("macOS Apple 芯片（M 系列）", "easytier-gui_2.6.4_aarch64.dmg"),
        dl_row("macOS Intel 芯片", "easytier-gui_2.6.4_x64.dmg"),
    ])
    rows_linux = "".join([
        dl_row("Linux x86_64（命令行，节点 / 服务端用）", "easytier-linux-x86_64-v2.6.4.zip"),
    ])
    # SHA-256 校验值：读预生成的 SHA256SUMS（避免每次请求重算 140MB+ 哈希）
    sums = []
    sums_file = DOWNLOAD_DIR / "SHA256SUMS"
    if sums_file.is_file():
        for line in sums_file.read_text().splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                sums.append(f'<div class="row"><span class="fname">{parts[1].strip().lstrip("*")}</span>'
                            f'<span class="sum">{parts[0]}</span></div>')
    rows_sums = "".join(sums) or f'<div class="row"><span class="fname">SHA256SUMS 尚未生成</span></div>'
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>海带 · Kelp 客户端下载</title><style>{DL_PAGE_CSS}</style></head>
<body><div class="wrap">
<h1>海带 <span>·</span> Kelp 客户端下载</h1>
<div class="sub">EasyTier v2.6.4（与组网节点同版本）· 镜像自 GitHub 官方 Release · 文件由本机直出</div>

<div class="card">
  <h2>手机 / 平板 <span class="badge p2p">P2P 直连</span><span class="badge">免费</span></h2>
  <div class="row">
    <a class="btn" href="/dl/app-arm64-release.apk">下载 APK</a>
    <b>Android · EasyTier 原生客户端</b>
    <span class="fname">app-arm64-release.apk</span>
    <span class="size">{human_size((dl_dir / 'app-arm64-release.apk').stat().st_size) if (dl_dir / 'app-arm64-release.apk').is_file() else '—'}</span>
  </div>
  {rows_android or '<div class="row">文件准备中…</div>'}
  <div class="row">
    <a class="btn line" href="https://apps.apple.com/us/app/wireguard/id1441195209">App Store</a>
    <b>iPhone / iPad · WireGuard</b><span class="fname">iOS 无独立安装包，走 App Store</span>
    <span class="size">配置在面板 <code>/wg/conf</code> 取</span>
  </div>
  <div class="note" style="margin-top:8px">
    · Android 装 APK 后，填入网络名与密钥即可（面板顶部品牌栏有名，密钥在部署会话中提供）。<br>
    · iOS 用 WireGuard：在面板打开 <code>/wg/conf</code> 下载配置，或用 <code>/wg/qr.png</code> 扫码导入。
  </div>
</div>

<div class="card">
  <h2>电脑（Windows / macOS）<span class="badge p2p">P2P 直连</span><span class="badge">免费</span></h2>
  {rows_pc or '<div class="row">文件准备中…</div>'}
  <div class="note" style="margin-top:8px">Windows / macOS 用 EasyTier 原生客户端<b>不需要</b> WireGuard；原生客户端走 P2P，不计公网节点流量费。</div>
</div>

<div class="card">
  <h2>Linux 节点 / 服务器 <span class="badge p2p">P2P 直连</span><span class="badge">免费</span></h2>
  {rows_linux or '<div class="row">文件准备中…</div>'}
  <div class="note" style="margin-top:8px">解包后 <code>easytier-core</code>（核心）+ <code>easytier-cli</code>（管理）；本机部署脚本见项目 <code>scripts/install-mesh-node.sh</code>。</div>
</div>

<div class="card">
  <h2>面板证书（自签，可选导入）<span class="badge">消除浏览器警告</span></h2>
  <div class="row">
    <a class="btn" href="/dl/kelp-panel.crt" download="kelp-panel.crt">下载证书</a>
    <b>kelp-panel.crt</b>
    <span class="fname">导入并信任后，浏览器访问面板不再弹警告</span>
  </div>
  <div class="note" style="margin-top:8px">
    <b>Windows</b>：双击 → 安装证书 → 本地计算机 → 受信任的根证书颁发机构<br>
    <b>macOS</b>：双击 → 钥匙串访问 → 始终信任；或命令行 <code>security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db kelp-panel.crt</code><br>
    <b>iOS</b>：设置 → 通用 → VPN与设备管理 → 安装描述文件，再到「关于本机 → 证书信任设置」里打开
  </div>
</div>

<div class="card">
  <h2>装好后打不开？<span class="badge">macOS / Windows 常见拦截</span></h2>
  <div class="note" style="margin-top:2px">
    <b>macOS 提示"已损坏，无法打开"</b>——这不是文件坏了（可用上面的 SHA-256 核对），而是应用<b>未做苹果公证</b>（adhoc 签名），被 Gatekeeper 拦下。二选一：<br>
    · 命令行（推荐，一次搞定）：<code>xattr -dr com.apple.quarantine /Applications/easytier-gui.app</code><br>
    · 图形界面：系统设置 → 隐私与安全性 → 拉到最下面点"仍要打开"<br>
    <b>Windows 提示 SmartScreen</b>：点"更多信息 → 仍要运行"。<br>
    <b>手机</b>：Android 需允许"安装未知来源应用"；iOS 无独立安装包（EasyTier iOS 在外区 App Store，或直接用 WireGuard）。
  </div>
</div>

<div class="card">
  <h2>SHA-256 校验值</h2>
  {rows_sums or '<div class="row">—</div>'}
</div>

<div class="card">
  <h2>WireGuard 官方客户端（备用通道）<span class="badge paid">经公网节点 · 0.8 元/GB</span></h2>
  <div class="row"><a class="btn line" href="https://apps.apple.com/us/app/wireguard/id1441195209">App Store</a><b>iOS</b><span class="fname">官方站</span></div>
  <div class="row"><a class="btn line" href="https://play.google.com/store/apps/details?id=com.wireguard.android">Google Play</a><b>Android</b><span class="fname">官方站</span></div>
  <div class="row"><a class="btn line" href="https://www.wireguard.com/install/">wireguard.com/install</a><b>Windows / macOS / Linux</b>
      <span class="fname">官方站（国内网络可能不可达）</span></div>
  <div class="note" style="margin-top:8px">⚠️ WireGuard 门户的流量<b>全程经公网节点转发</b>，按出网 0.8 元/GB 计费（看一部 2GB 电影约 1.6 元）。大流量请优先用上面的原生客户端。</div>
</div>

<div class="card">
  <div class="qr">
    <img src="/dl/dl-url.png" alt="下载页二维码">
    <div>
      <b>手机扫码直接打开本页</b><br>
      <span class="fname">https://47.116.73.216:18080/dl/</span>
      <div class="note" style="margin-top:6px">证书是自签的：首次访问点「高级 → 继续前往」即可。</div>
    </div>
  </div>
</div>

<div class="note">
  组网面板：<code>https://47.116.73.216:18080</code>（需登录，可看设备在线/延迟/中继与出网流量）<br>
  项目档案：<code>~/01-project/07-kelp</code>（任务书 / checkpoint / 验收记录）
</div>
</div></body></html>"""


def main() -> None:
    global CONFIG
    CONFIG = load_config()
    refresh_once()
    threading.Thread(target=poller, daemon=True).start()
    srv = ThreadingHTTPServer((CONFIG["listen"], int(CONFIG["port"])), Handler)
    cert, key = CONFIG.get("tls_cert", ""), CONFIG.get("tls_key", "")
    scheme = "http"
    if cert and key and Path(cert).exists() and Path(key).exists():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(certfile=cert, keyfile=key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = "https"
    print(f"kelp-panel listening on {scheme}://{CONFIG['listen']}:{CONFIG['port']} "
          f"({len(CONFIG['nodes'])} nodes / {len(CONFIG['devices'])} registered devices)", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
