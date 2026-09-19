#!/usr/bin/env bash
# 海带 (Kelp) M4 收尾脚本 —— 在 192.168.50.9 上以 root 执行一次即可
#
# 做三件事：
#   ① 给 A 站点节点补 --need-p2p true（跨站点防回落中继，避免 0.8 元/GB 计费）
#   ② 把该节点的 RPC 白名单补上 127.0.0.1（便于本机 easytier-cli 自查）
#   ③ 执行网关模式 apply（开 ip_forward + FORWARD 放行 + 免客户端设备自测）
#
# 幂等：重复执行不会重复改配置；改 unit 前会备份到 /etc/systemd/system/*.bak.<时间戳>
set -uo pipefail

UNIT=/etc/systemd/system/easytier-node.service
GATEWAY=/tmp/kelp-gateway.sh

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "============================================================"; }

[[ $EUID -eq 0 ]] || { echo "必须以 root 执行：sudo bash $0" >&2; exit 1; }
[[ -f $UNIT ]] || { echo "找不到 $UNIT（A 站点节点是否已安装？）" >&2; exit 1; }

hr; say "① 更新 A 站点节点启动参数"; hr
BACKUP="$UNIT.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$UNIT" "$BACKUP" && say "  已备份 -> $BACKUP"

python3 - "$UNIT" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
changed = []
for i, line in enumerate(lines):
    if not line.startswith("ExecStart="):
        continue
    if "--need-p2p" not in line:
        line += " --need-p2p true"
        changed.append("补 --need-p2p true")
    if "--rpc-portal-whitelist" in line:
        m = re.search(r"--rpc-portal-whitelist\s+(\S+)", line)
        if m and "127.0.0.1" not in m.group(1):
            line = line[:m.start(1)] + "127.0.0.1," + m.group(1) + line[m.end(1):]
            changed.append("RPC 白名单补 127.0.0.1")
    lines[i] = line
p.write_text("\n".join(lines) + "\n")
print("  变更:", "；".join(changed) if changed else "无（已是目标状态）")
PY

systemctl daemon-reload
systemctl restart easytier-node
sleep 6
say "  服务状态: $(systemctl is-active easytier-node)"
say "  --- 生效参数 ---"
systemctl show easytier-node -p ExecStart | tr ' ' '\n' | grep -E "need-p2p|rpc-portal-whitelist|proxy-networks" | sed 's/^/    /'
say "  --- 邻居（本机 CLI 现在可自查）---"
/usr/local/bin/easytier-cli peer 2>&1 | head -6 | sed 's/^/    /'

hr; say "② 网关模式（FR3）"; hr
if [[ -f $GATEWAY ]]; then
    bash "$GATEWAY" apply
    rc=$?
    hr
    say "③ 汇总"
    say "  A 站点节点: $(systemctl is-active easytier-node)（--need-p2p 已生效）"
    say "  网关模式   : $([[ $rc == 0 ]] && echo '已开启且自测通过' || echo '未通过，请把上面输出发回')"
    say "  ip_forward : $(cat /proc/sys/net/ipv4/ip_forward)"
else
    say "  找不到 $GATEWAY，跳过网关模式（可单独跑：sudo bash $GATEWAY apply）"
fi
hr
say "回滚：sudo bash $GATEWAY rollback ；恢复 unit：cp $BACKUP $UNIT && systemctl daemon-reload && systemctl restart easytier-node"
