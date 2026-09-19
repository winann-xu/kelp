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

CONFIG_PATH = Path(os.environ.get("KELP_PANEL_CONFIG", "/etc/kelp/panel.json"))
UI_PATH = Path(os.environ.get("KELP_PANEL_UI", "/opt/kelp/panel_ui.html"))
CLI = os.environ.get("KELP_EASYTIER_CLI", "/usr/local/bin/easytier-cli")
CST = timezone(timedelta(hours=8))

CONFIG: dict = {}
STATE: dict = {"generated_at": None, "nodes": [], "devices": [], "summary": {}}
STATE_LOCK = threading.Lock()
LAST_SEEN: dict[str, str] = {}

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


def refresh_once() -> None:
    nodes = [collect_node(n) for n in CONFIG["nodes"]]
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
        })


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

    def do_GET(self):  # noqa: N802
        if not self.authorized():
            return self.reject()
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            body = UI_PATH.read_bytes() if UI_PATH.exists() else b"<h1>UI missing</h1>"
            return self.reply(200, body, "text/html; charset=utf-8")
        if path == "/api/status":
            with STATE_LOCK:
                payload = json.dumps(STATE, ensure_ascii=False).encode("utf-8")
            return self.reply(200, payload, "application/json; charset=utf-8")
        if path == "/healthz":
            return self.reply(200, b'{"ok":true}', "application/json")
        return self.reply(404, b"not found", "text/plain; charset=utf-8")


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
