#!/usr/bin/env bash
# 网络密钥轮换：三节点同时改（公网 hub / 50.9 站点 / 飞牛 NAS 容器）
# 用法: NEW_SECRET=新密钥 bash rotate-secret.sh
# 特性：改前逐机备份原文件、原密钥单独留档（600）、改完自动验证邻居与面板
set -uo pipefail

NEW="${NEW_SECRET:?用法: NEW_SECRET=xxx bash rotate-secret.sh}"
STAMP=$(date +%Y%m%d%H%M%S)
BK="$HOME/kelp-run/secret-backup-$STAMP"
mkdir -p "$BK" && chmod 700 "$BK"
say() { printf '%s\n' "$*"; }

### 凭据只从 600 文件读（~/.config/kelp/{creds,kelp}.env），绝不写进本脚本 ###
for f in "$HOME/.config/kelp/creds.env" "$HOME/.config/kelp/kelp.env"; do
  [[ -f $f ]] || { echo "缺少 $f"; exit 1; }
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
done
VPS="$KELP_VPS_USER@$KELP_VPS_HOST"
NAS="$KELP_NAS_USER@$KELP_NAS_HOST"
NASPORT="$KELP_NAS_PORT"
S9="$KELP_S9_USER@$KELP_S9_HOST"

say "=== 0) 备份目录 $BK ==="
cp -a "$HOME/.config/kelp/kelp.env" "$BK/kelp.env.mac" 2>/dev/null && say "  已备份本机 kelp.env"
cp -a "$HOME/kelp-run/kelp-b.env" "$BK/kelp-b.env.mac" 2>/dev/null && say "  已备份本机 kelp-b.env"

say ""
say "=== 1) B 站点（飞牛 NAS 容器）==="
export SSHPASS="$KELP_NAS_PASS"
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 -p $NASPORT "$NAS" \
  "cp -a /vol1/kelp/b.env /vol1/kelp/b.env.bak.$STAMP && \
   sed -i 's|^ET_NETWORK_SECRET=.*|ET_NETWORK_SECRET=$NEW|' /vol1/kelp/b.env && \
   echo '  改后（打码）：' && sed 's/\(SECRET=\).*/\1***/' /vol1/kelp/b.env | sed 's/^/    /' && \
   docker restart kelp-b-node >/dev/null && echo '  容器已重启'" 2>&1 | sed 's/^/  /'

say ""
say "=== 2) 公网节点 hub ==="
export SSHPASS="$KELP_VPS_PASS"
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$VPS" \
  "cp -a /etc/easytier/kelp.env /etc/easytier/kelp.env.bak.$STAMP && \
   grep -oP 'KELP_NET_SECRET=\K.*' /etc/easytier/kelp.env.bak.$STAMP > /root/kelp-secret-old.$STAMP.txt && chmod 600 /root/kelp-secret-old.$STAMP.txt && \
   sed -i 's|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|' /etc/easytier/kelp.env && \
   systemctl restart easytier && sleep 4 && echo \"  服务: \$(systemctl is-active easytier)\"" 2>&1 | sed 's/^/  /'

say ""
say "=== 3) A 站点（50.9）==="
export SSHPASS="$KELP_S9_PASS"
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$S9" \
  "sudo -n cp -a /etc/easytier/kelp.env /etc/easytier/kelp.env.bak.$STAMP && \
   sudo -n bash -c \"grep -oP 'KELP_NET_SECRET=\\\\K.*' /etc/easytier/kelp.env.bak.$STAMP > /root/kelp-secret-old.$STAMP.txt\" && \
   sudo -n chmod 600 /root/kelp-secret-old.$STAMP.txt && \
   sudo -n sed -i 's|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|' /etc/easytier/kelp.env && \
   sudo -n systemctl restart easytier-node && sleep 4 && echo \"  服务: \$(systemctl is-active easytier-node)\"" 2>&1 | sed 's/^/  /'

say ""
say "=== 4) 等 25 秒让三节点重新组网，然后验证 ==="
sleep 25
export SSHPASS="$KELP_VPS_PASS"
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$VPS" \
  "echo '  --- hub 视角邻居 ---'; easytier-cli -p 127.0.0.1:15888 peer 2>&1 | sed 's/^/  /'
   echo '  --- 面板统计 ---'
   curl -sk -u "$KELP_PANEL_USER:$KELP_PANEL_PASS" https://127.0.0.1:18080/api/status | python3 -c \"
import json,sys
d=json.load(sys.stdin); s=d['summary']
print('  在线', s['online'], '/ 登记', s['total'], '| P2P', s['p2p'], '| 中继', s['relay'])
for x in d['devices']: print('   -', x['ipv4'], x['label'] or x['hostname'], '在线=%s' % x['online'], '路径=%s' % x['cost'])
\"" 2>&1 | sed 's/^/  /'

say ""
say "=== 5) 更新本机保存的身份副本 ==="
sed -i '' "s|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|" "$HOME/.config/kelp/kelp.env"
sed -i '' "s|^ET_NETWORK_SECRET=.*|ET_NETWORK_SECRET=$NEW|" "$HOME/kelp-run/kelp-b.env"
say "  kelp.env  : $(grep -oE 'KELP_NET_SECRET=.{0,4}' "$HOME/.config/kelp/kelp.env")…"
say "  kelp-b.env: $(grep -oE 'ET_NETWORK_SECRET=.{0,4}' "$HOME/kelp-run/kelp-b.env")…"
say ""
say "=== 完成。旧密钥留档 ==="
say "  各机 /root/kelp-secret-old.$STAMP.txt（600）；原 env 文件 .bak.$STAMP"
say "  本机备份目录: $BK"
