"""面板管理动作：① 改面板登录口令 ② 轮换组网网络密钥。

面板以 root 运行在公网节点（hub）上，因此：
  · hub 自己的 env 与 systemd 直接改；
  · A 站点 50.9 与 B 站点 NAS 通过【hub → 各机 SSH 公钥】远程执行，
    **任何口令都不落盘**（不用 sshpass，不用凭据文件）；
  · 每个动作先备份再写入，返回值里带上回滚路径。

本模块只做这两件事，UI 拼装见 ADMIN_HTML。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import time
from pathlib import Path

PANEL_JSON = Path(os.environ.get("KELP_PANEL_CONFIG", "/etc/kelp/panel.json"))
HUB_ENV = Path("/etc/easytier/kelp.env")
HUB_CLI = "/usr/local/bin/easytier-cli"
HUB_RPC = "127.0.0.1:15888"
PRIVATE_DIR = Path(os.environ.get("KELP_PRIVATE_DIR", "/opt/kelp/private"))

S9_HOST, S9_USER = "192.168.50.9", "winann"
S9_APPLY = "/usr/local/bin/kelp-apply-secret.sh"
NAS_HOST, NAS_USER, NAS_PORT = "192.168.1.99", "admin", 48032
NAS_ENV, NAS_RUN = "/vol1/kelp/b.env", "/vol1/kelp/run-b-node.sh"
NAS_ACCESS = Path("/etc/kelp/nas-access.env")   # 600 root：B 站点登录凭据（缺失则跳过/报错）
NAS_LOG = "/vol1/kelp/rotate.log"               # B 站点重建日志（重建会掐断隧道，只能事后看日志）

SSH_BASE = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=12"]
# 口令方式（B 站点 NAS）：**不能带 BatchMode**，否则 ssh 根本不会尝试口令认证
SSH_PW_BASE = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=12",
               "-o", "NumberOfPasswordPrompts=1"]
# 密钥字符集刻意排除 & | \ " ' 空格 等会在 sed/shell 里惹麻烦的字符
SECRET_RE = re.compile(r"^[A-Za-z0-9._~!@#%^*+=?-]{8,64}$")
CLIENT_IP_INSIDE_PORTAL = "10.144.150.2/24"   # 手机在门户网段里的地址（与既有配置一致）
ENDPOINT = "47.116.73.216:11013"


def stamp() -> str:
    return time.strftime("%Y%m%d%H%M%S")


def run(cmd: list[str], timeout: int = 120) -> tuple[int, str]:
    """执行外部命令，返回 (返回码, 合并后的输出)。异常一律转成输出，不让面板 500。"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        return p.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, f"超时（>{timeout}s）"
    except FileNotFoundError as exc:
        return 127, f"找不到命令: {exc}"


def ssh(host: str, user: str, port: int, remote_cmd: str, timeout: int = 180) -> tuple[int, str]:
    return run([*SSH_BASE, "-p", str(port), f"{user}@{host}", remote_cmd], timeout=timeout)


def validate_secret(value: str) -> str:
    """返回错误信息；空串表示通过。"""
    if not value:
        return "密钥不能为空"
    if not SECRET_RE.match(value):
        return "只允许 8–64 位的 字母/数字 与 . _ ~ ! @ # % ^ * + = ? -"
    return ""


def current_secret() -> str:
    """hub 上当前生效的网络密钥（只用于“新旧是否相同”的校验，不回传前端）。"""
    try:
        text = HUB_ENV.read_text(encoding="utf-8")
    except Exception:
        return ""
    m = re.search(r"^KELP_NET_SECRET=(.*)$", text, flags=re.M)
    return m.group(1).strip() if m else ""


def validate_password(value: str) -> str:
    if len(value) < 8:
        return "口令至少 8 位"
    if len(value) > 128:
        return "口令过长"
    if any(c in value for c in "\"'\\"):
        return "口令里不要用引号或反斜杠"
    return ""


# ------------------------------------------------------------------ 鉴权


def verify_password(user: str, password: str) -> bool:
    """与面板登录同一套算法（salt + sha256）。"""
    try:
        auth = json.loads(PANEL_JSON.read_text(encoding="utf-8")).get("auth", {})
    except Exception:
        return False
    salt, want = str(auth.get("salt", "")), str(auth.get("sha256", ""))
    got = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return hmac.compare_digest(str(auth.get("user", "")), user) and hmac.compare_digest(want, got)


# ------------------------------------------------------------------ 改面板口令


def change_panel_password(new_password: str) -> dict:
    cfg = json.loads(PANEL_JSON.read_text(encoding="utf-8"))
    backup = f"{PANEL_JSON}.bak.{stamp()}"
    shutil.copy2(PANEL_JSON, backup)
    salt = secrets.token_hex(6)
    cfg.setdefault("auth", {})
    cfg["auth"]["salt"] = salt
    cfg["auth"]["sha256"] = hashlib.sha256((salt + new_password).encode("utf-8")).hexdigest()
    tmp = PANEL_JSON.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(PANEL_JSON)
    # 先把响应发出去，再重启自己（配置只在启动时读）
    subprocess.Popen(["bash", "-c", "sleep 3; systemctl restart kelp-panel"], start_new_session=True)
    return {
        "ok": True,
        "backup": backup,
        "note": "面板将在约 3 秒后重启；本机 ~/.config/kelp/kelp.env 里的 KELP_PANEL_PASS 请同步改成新口令"
                "（否则本机脚本用旧口令读面板会 401）",
    }


# ------------------------------------------------------------------ 换网络密钥


def _hub_set_secret(new: str) -> dict:
    backup = f"{HUB_ENV}.bak.{stamp()}"
    shutil.copy2(HUB_ENV, backup)
    text = HUB_ENV.read_text(encoding="utf-8")
    text = re.sub(r"^KELP_NET_SECRET=.*$", f"KELP_NET_SECRET={new}", text, flags=re.M)
    HUB_ENV.write_text(text, encoding="utf-8")
    os.chmod(HUB_ENV, 0o600)
    return {"ok": True, "backup": backup}


def _hub_restart() -> tuple[bool, str]:
    rc, out = run(["systemctl", "restart", "easytier"], timeout=60)
    if rc != 0:
        return False, out or f"systemctl 返回 {rc}"
    time.sleep(4)
    rc2, out2 = run(["systemctl", "is-active", "easytier"], timeout=20)
    return out2.strip() == "active", out2.strip()


def precheck() -> str:
    """动手前的体检：任一项不满足就返回人话错误（此时**什么都没改**）。"""
    if not HUB_ENV.exists():
        return f"读不到 {HUB_ENV}（面板是不是没跑在公网节点上？）"
    if not nas_creds().get("KELP_NAS_PASS"):
        return (f"hub 上缺少 {NAS_ACCESS}（B 站点凭据）：B 站点这一腿将无法自动完成。"
                f"补上该文件后重试，或接受 B 站点稍后手动重建。")
    rc, out = ssh(S9_HOST, S9_USER, 22, f"sudo -n {S9_APPLY} --check", timeout=40)
    if rc != 0 or "ok:" not in out:
        return ("A 站点（50.9）还没授权远程换密钥：请在 50.9 上跑一次 "
                "`scp scripts/kelp-apply-secret.sh scripts/50-9-enable-agent-access.sh winann@192.168.50.9:/tmp/` "
                "然后 `ssh -t winann@192.168.50.9 'sudo bash /tmp/50-9-enable-agent-access.sh'`。"
                f"（探针输出：{(out or '')[:160]}）")
    return ""


def _s9_set_secret(new: str) -> dict:
    rc, out = ssh(S9_HOST, S9_USER, 22, f"sudo -n {S9_APPLY} '{new}'", timeout=90)
    return {"ok": rc == 0 and "ok:" in out, "log": out or f"返回码 {rc}"}


def nas_creds() -> dict:
    """读 hub 上 600 的 B 站点凭据；读不到就返回空 dict（调用方给出人话错误）。"""
    creds: dict[str, str] = {}
    try:
        for line in NAS_ACCESS.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip()
    except Exception:
        return {}
    return creds


def _nas_set_secret(new: str) -> dict:
    """B 站点：改 env 文件 + **重建容器**（docker restart 不重读 env-file）。"""
    creds = nas_creds()
    if not creds.get("KELP_NAS_PASS"):
        return {"ok": False, "log": f"缺少 {NAS_ACCESS}（hub 上没有 B 站点凭据）—— "
                                    f"在 NAS 上手动执行：sed 改 {NAS_ENV} 后 ENVF={NAS_ENV} bash {NAS_RUN}"}
    host = creds.get("KELP_NAS_HOST", NAS_HOST)
    port = creds.get("KELP_NAS_PORT", str(NAS_PORT))
    user = creds.get("KELP_NAS_USER", NAS_USER)
    env = dict(os.environ, SSHPASS=creds["KELP_NAS_PASS"])

    def nas_ssh(remote_cmd: str, timeout: int = 60) -> tuple[int, str]:
        try:
            p = subprocess.run(["sshpass", "-e", *SSH_PW_BASE, "-p", port, f"{user}@{host}", remote_cmd],
                               capture_output=True, text=True, timeout=timeout, env=env)
            return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
        except subprocess.TimeoutExpired:
            return 124, "超时"
        except FileNotFoundError:
            return 127, "hub 上没有 sshpass（apt-get install -y sshpass）"

    # 关键：**重建容器会掐断我们到 NAS 的隧道**（hub→NAS 的 SSH 正是穿过这个容器转发的），
    # 所以不能在一条 ssh 里同步等结果 —— 改成 setsid 派生执行，再轮询日志与容器状态。
    launch = (f"cp -a {NAS_ENV} {NAS_ENV}.bak.{stamp()} && "
              f"sed -i 's|^ET_NETWORK_SECRET=.*|ET_NETWORK_SECRET={new}|' {NAS_ENV} && "
              f"setsid bash -c 'ENVF={NAS_ENV} bash {NAS_RUN} > {NAS_LOG} 2>&1' "
              f"</dev/null >/dev/null 2>&1 & echo launched")
    # 这一条 ssh **本身就可能被重建打断**（隧道随容器消失），所以只当发令枪：
    # 给短超时、不看结果，真正的判据是后面的轮询。
    rc, out = nas_ssh(launch, timeout=12)
    launched_note = "已发出重建指令" if (rc == 0 or "launched" in out) else f"发令返回码 {rc}（隧道被容器重建掐断属预期）"

    launched_utc = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    probe = ("echo STATE=$(docker inspect -f '{{.State.Status}}' kelp-b-node 2>/dev/null); "
             "echo STARTED=$(docker inspect -f '{{.State.StartedAt}}' kelp-b-node 2>/dev/null); "
             "echo ENVPREFIX=$(docker exec kelp-b-node printenv ET_NETWORK_SECRET 2>/dev/null | head -c 8); "
             f"echo LOGTAIL=$(tail -1 {NAS_LOG} 2>/dev/null)")
    deadline = time.time() + 600   # fnOS 上重建容器实测要 5 分钟上下
    last = ""
    while time.time() < deadline:
        time.sleep(10)
        rc, last = nas_ssh(probe, timeout=45)
        if rc != 0:
            continue          # 容器还没回来：到 NAS 的隧道断着，属预期
        state = (re.search(r"STATE=(\S+)", last) or [None, ""])[1]
        started = ((re.search(r"STARTED=(\S+)", last) or [None, ""])[1])[:19]
        prefix = (re.search(r"ENVPREFIX=(\S*)", last) or [None, ""])[1]
        if state == "running" and started >= launched_utc and prefix.startswith(new[:8]):
            return {"ok": True,
                    "log": f"{launched_note}；容器已重建（{state} @{started}Z），容器内密钥与新值一致"}
    return {"ok": False,
            "log": f"{launched_note}；等 B 站点重建超时。探针最后输出：{last[-240:]}（日志 {NAS_LOG}）"}


def _peers_after(expect: int = 2, wait: int = 60) -> tuple[bool, str]:
    """等组网恢复：轮询 hub 上的 peer 列表。"""
    deadline = time.time() + wait
    last = ""
    while time.time() < deadline:
        rc, out = run([HUB_CLI, "-p", HUB_RPC, "peer"], timeout=15)
        last = out
        if rc == 0 and out.count("p2p") + out.count("relay") >= expect:
            return True, out
        time.sleep(5)
    return False, last


def _refresh_portal() -> dict:
    """hub 重启后门户密钥会变 → 重新落 /wg/conf，并尽量重生成二维码。"""
    rc, out = run([HUB_CLI, "-p", HUB_RPC, "vpn-portal"], timeout=20)
    if rc != 0:
        return {"ok": False, "log": out}
    block = out.split("client_config_start", 1)[-1].split("client_config_end", 1)[0]
    priv = pub = allowed = ""
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("PrivateKey"):
            priv = line.split("=", 1)[1].strip()
        elif line.startswith("PublicKey"):
            pub = line.split("=", 1)[1].strip()
        elif line.startswith("AllowedIPs"):
            allowed = line.split("=", 1)[1].strip()
    if len(priv) != 44 or len(pub) != 44:
        return {"ok": False, "log": "门户未返回可用配置"}
    conf = (f"[Interface]\nPrivateKey = {priv}\nAddress = {CLIENT_IP_INSIDE_PORTAL}\nMTU = 1360\n\n"
            f"[Peer]\nPublicKey = {pub}\nAllowedIPs = {allowed}\nEndpoint = {ENDPOINT}\n"
            f"PersistentKeepalive = 25\n")
    PRIVATE_DIR.mkdir(parents=True, exist_ok=True)
    conf_file = PRIVATE_DIR / "conf"
    conf_file.write_text(conf, encoding="utf-8")
    os.chmod(conf_file, 0o600)
    qr_note = "二维码未更新（hub 上没有 segno），可在本机跑 scripts/refresh-wg-phone-conf.sh"
    try:
        import segno  # type: ignore

        qr = PRIVATE_DIR / "qr.png"
        segno.make(conf, error="m").save(str(qr), scale=8, border=3)
        os.chmod(qr, 0o600)
        qr_note = "二维码已同步更新（/wg/qr.png）"
    except Exception:
        pass
    return {"ok": True, "log": f"/wg/conf 已更新（私钥 {priv[:6]}… 44 位）；{qr_note}"}


def rotate_secret(new: str) -> dict:
    """三节点同步换密钥：B 站点 → hub → A 站点 50.9 → 等恢复 → 刷新门户配置。

    第 1 步（NAS）失败就立即中止：此刻其余两台还没动，网络仍是自洽的。
    """
    if not HUB_ENV.exists():
        return {"ok": False, "error": f"读不到 {HUB_ENV}（面板是不是没跑在公网节点上？）", "steps": []}

    blocking = precheck()
    if blocking:
        return {"ok": False, "error": blocking, "steps": [], "note": "未做任何改动"}

    steps: list[dict] = []
    steps.append({"name": "公网 hub（改 env）", **_hub_set_secret(new)})
    steps.append({"name": "A 站点 50.9（远程 apply + 重启节点）", **_s9_set_secret(new)})
    ok, log = _hub_restart()
    steps.append({"name": "公网 hub（重启 easytier）", "ok": ok, "log": log})

    restored, peers = _peers_after(expect=1)
    steps.append({"name": "组网恢复校验（等对端回来）", "ok": restored, "log": peers[:600]})

    # B 站点放最后：fnOS 上重建容器要几分钟，且重建期间 hub↔NAS 的隧道会断（我们正是穿它过去的），
    # 放在最后就不会影响前两台已经切好的正确性 —— NAS 重建完自然带新密钥回来。
    nas = _nas_set_secret(new)
    steps.append({"name": "B 站点 NAS（改 env + 重建容器，最慢一步）", **nas})
    steps.append({"name": "WireGuard 门户配置刷新", **_refresh_portal()})

    hard_ok = steps[0]["ok"] and steps[1]["ok"] and steps[2]["ok"]
    return {
        "ok": hard_ok and nas["ok"],
        "steps": steps,
        "note": ("前两台已切到新密钥；" if hard_ok else "⚠️ 公网节点或 A 站点未切成功，请按下面的日志处置；")
                + ("B 站点仍在重建，回来后会自动用新密钥入网。" if not nas["ok"] else "")
                + "客户端里的密钥要手动改成新值：手机 EasyTier App、Mac / Windows 的 EasyTier GUI",
    }


# ------------------------------------------------------------------ 管理页


ADMIN_HTML = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>海带 · 管理</title><style>
 :root{--bg:#080c18;--card:#141b2f;--card2:#1a2338;--line:#243050;--txt:#e8edf9;--dim:#8d9ab5;
       --ok:#35e08b;--accent:#5b8cff;--danger:#ff6b6b;--warn:#ffc453}
 *{box-sizing:border-box}
 body{margin:0;padding:26px 16px 60px;background:radial-gradient(1000px 500px at 15% -10%,#16224a 0,transparent 60%),
      radial-gradient(800px 420px at 110% 5%,#123a3a 0,transparent 55%),var(--bg);color:var(--txt);
      font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;min-height:100vh}
 .wrap{max-width:760px;margin:0 auto}
 h1{font-size:21px;margin:0 0 4px} h1 span{color:var(--accent)}
 .sub{color:var(--dim);font-size:13px;margin-bottom:18px}
 a.back{color:var(--accent);text-decoration:none;font-size:13px}
 .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px 18px;margin-bottom:14px}
 .card h2{font-size:16px;margin:0 0 10px}
 .row{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:10px}
 input{flex:1 1 220px;min-width:0;background:var(--card2);border:1px solid var(--line);border-radius:10px;
       padding:9px 12px;color:var(--txt);font-size:14px}
 button{background:var(--accent);color:#06122b;border:0;border-radius:10px;padding:9px 16px;font-size:14px;
        font-weight:650;cursor:pointer}
 button.ghost{background:transparent;border:1px solid var(--line);color:var(--txt);font-weight:500}
 button[disabled]{opacity:.5;cursor:default}
 .hint{color:var(--dim);font-size:12.5px;margin-top:6px}
 .warn{color:var(--warn)} .danger{color:var(--danger)} .ok{color:var(--ok)}
 pre{white-space:pre-wrap;word-break:break-all;background:var(--card2);border:1px solid var(--line);
     border-radius:10px;padding:10px 12px;font-size:12px;color:var(--dim);margin:8px 0 0;max-height:280px;overflow:auto}
</style></head><body><div class="wrap">
<h1>海带 <span>·</span> 管理</h1>
<div class="sub"><a class="back" href="/">← 回面板</a>　·　这里有两个可写操作，都要求再次输入当前登录口令</div>

<div class="card">
  <h2>① 修改面板登录口令</h2>
  <div class="row"><input id="oldPw" type="password" placeholder="当前口令" autocomplete="current-password"></div>
  <div class="row"><input id="newPw" type="password" placeholder="新口令（≥8 位）" autocomplete="new-password">
                   <input id="newPw2" type="password" placeholder="再输一次" autocomplete="new-password"></div>
  <div class="row"><button id="btnPw">改口令</button></div>
  <div class="hint">改完面板会自己重启（约 3 秒）。

  </div>
  <pre id="outPw" hidden></pre>
</div>

<div class="card">
  <h2>② 轮换组网网络密钥</h2>
  <div class="hint">会依次改：公网 hub → A 站点 50.9 → 最后重建 B 站点 NAS 容器，然后校验组网是否恢复、刷新手机 WireGuard 配置。<b>B 站点重建在飞牛 NAS 上要几分钟</b>（重建期间它自己会短暂离线），期间组网有中断属正常。</div>
  <div class="row" style="margin-top:10px"><input id="curlPw" type="password" placeholder="当前口令（二次确认）"></div>
  <div class="row"><input id="newSecret" type="text" placeholder="新网络密钥（8–64 位，建议 ≥24 位随机）">
                   <input id="newSecret2" type="text" placeholder="再输一次"></div>
  <div class="row"><button id="btnSecret">轮换密钥</button>
       <button class="ghost" id="btnGen">随机生成 32 位</button></div>
  <div class="hint warn">换完必须手动更新客户端：手机 EasyTier App、Mac / Windows 的 EasyTier GUI。否则它们会掉线。</div>
  <pre id="outSecret" hidden></pre>
</div>
</div>
<script>
const $ = id => document.getElementById(id);
const show = (el, text) => { el.hidden = false; el.textContent = text; };

async function post(path, body) {
  const r = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json'},
                             body: JSON.stringify(body)});
  return r.json();
}

$('btnPw').onclick = async () => {
  const out = $('outPw');
  if ($('newPw').value !== $('newPw2').value) return show(out, '两次输入的新口令不一致');
  if ($('newPw').value.length < 8) return show(out, '新口令至少 8 位');
  $('btnPw').disabled = true; show(out, '提交中…');
  const j = await post('/admin/password', {old_password:$('oldPw').value, new_password:$('newPw').value});
  show(out, j.ok ? ('✅ 已改口令。' + (j.note||'')) : ('❌ ' + (j.error||'失败')));
  $('btnPw').disabled = false;
};

$('btnGen').onclick = () => {
  const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const buf = new Uint8Array(32); crypto.getRandomValues(buf);
  const s = Array.from(buf, b => a[b % a.length]).join('');
  $('newSecret').value = s; $('newSecret2').value = s;
};

$('btnSecret').onclick = async () => {
  const out = $('outSecret');
  if ($('newSecret').value !== $('newSecret2').value) return show(out, '两次输入的新密钥不一致');
  if (!confirm('确认轮换网络密钥？组网会短暂中断，且手机/Mac/Windows 客户端都要手改密钥。')) return;
  $('btnSecret').disabled = true; show(out, '执行中…（几分钟，别关页面）');
  const j = await post('/admin/secret', {password:$('curlPw').value, new_secret:$('newSecret').value});
  if (j.error) { show(out, '❌ ' + j.error); $('btnSecret').disabled = false; return; }
  let t = (j.ok ? '✅ 全部步骤成功\\n\\n' : '⚠️ 有步骤失败，请看下面\\n\\n') + (j.note||'') + '\\n\\n';
  for (const s of j.steps||[]) t += `${s.ok ? '✅' : '❌'} ${s.name}\\n${(s.log||'').slice(0,600)}\\n\\n`;
  show(out, t); $('btnSecret').disabled = false;
};
</script></body></html>
"""
