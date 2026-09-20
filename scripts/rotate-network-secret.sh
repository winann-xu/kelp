#!/usr/bin/env bash
# 网络密钥轮换：三节点同步（公网 hub / 50.9 站点 / 飞牛 NAS 容器）+ 门户配置刷新 + 端到端验证
#
# 用法（在你自己的终端里跑；会提示输入 50.9 的 sudo 口令）：
#     NEW_SECRET='你想要的密钥' bash scripts/rotate-network-secret.sh
#     NEW_SECRET='...' DRY_RUN=1 bash scripts/rotate-network-secret.sh   # 只打印将要做的步骤
#
# 前置：本机 600 凭据文件 ~/.config/kelp/{kelp.env,creds.env}；NAS 上 /vol1/kelp/run-b-node.sh 存在
# 特性：逐机备份（原文件 .bak.<时间戳>）、改完自动验证、输出回滚路径
#
# ⚠️ 轮换后客户端里的密钥都要手动改：手机 EasyTier App、Mac / Windows 的 EasyTier GUI。
#    hub 重启还会让 WireGuard 门户密钥重生成 —— 本脚本会自动重跑 refresh-wg-phone-conf.sh。
set -uo pipefail

NEW="${NEW_SECRET:?用法: NEW_SECRET='你的密钥' bash rotate-network-secret.sh（建议 ≥24 位随机串）}"
DRY="${DRY_RUN:-0}"
STAMP=$(date +%Y%m%d%H%M%S)
BK="$HOME/.config/kelp/secret-backup-$STAMP"
say() { printf '%s\n' "$*"; }
banner() { say ""; say "=== $* ==="; }

[[ ${#NEW} -ge 12 ]] || say "⚠️ 提示：新密钥只有 ${#NEW} 位，建议 ≥24 位随机串更抗暴力猜测"

### 凭据只从 600 文件读，脚本内零明文 #####################################
for f in "$HOME/.config/kelp/creds.env" "$HOME/.config/kelp/kelp.env"; do
  [[ -f $f ]] || { say "缺少 $f"; exit 1; }
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
done
VPS="$KELP_VPS_USER@$KELP_VPS_HOST"
NAS="$KELP_NAS_USER@$KELP_NAS_HOST"
S9="$KELP_S9_USER@$KELP_S9_HOST"
LOCAL_ENV="$HOME/.config/kelp/kelp.env"
LOCAL_BENV="$HOME/.config/kelp/kelp-b.env"
SSH_OPTS=(-o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=12)

banner "0) 备份本机身份副本 → $BK"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] mkdir -p ${BK}（700）并拷贝 kelp.env / kelp-b.env"
else
  mkdir -p "$BK" && chmod 700 "$BK"
  cp -a "$LOCAL_ENV" "$BK/kelp.env.mac" && cp -a "$LOCAL_BENV" "$BK/kelp-b.env.mac" && say "  已备份 2 个文件"
fi

banner "1) B 站点（飞牛 NAS）：改 env + 【重建容器】（docker restart 不重读 env-file）"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] NAS: 备份 b.env → sed 换密钥 → ENVF=/vol1/kelp/b.env bash /vol1/kelp/run-b-node.sh"
else
  SSHPASS="$KELP_NAS_PASS" sshpass -e ssh "${SSH_OPTS[@]}" -p "$KELP_NAS_PORT" "$NAS" \
    "cp -a /vol1/kelp/b.env /vol1/kelp/b.env.bak.$STAMP && \
     sed -i 's|^ET_NETWORK_SECRET=.*|ET_NETWORK_SECRET=$NEW|' /vol1/kelp/b.env && \
     ENVF=/vol1/kelp/b.env bash /vol1/kelp/run-b-node.sh 2>&1 | tail -10" | sed 's/^/  /'
fi

banner "2) 公网 hub：改 env + 重启 easytier"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] hub: 备份 kelp.env → sed 换密钥 → systemctl restart easytier"
else
  SSHPASS="$KELP_VPS_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$VPS" \
    "cp -a /etc/easytier/kelp.env /etc/easytier/kelp.env.bak.$STAMP && \
     sed -i 's|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|' /etc/easytier/kelp.env && \
     systemctl restart easytier && sleep 4 && echo \"  easytier: \$(systemctl is-active easytier)\"" | sed 's/^/  /'
fi

banner "3) A 站点（50.9）：改 env + 重启节点（交互式 sudo，需输入口令）"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] ssh -t $S9 → sudo 备份+sed+systemctl restart easytier-node"
else
  ssh -t "${SSH_OPTS[@]}" "$S9" \
    "sudo bash -c \"cp -a /etc/easytier/kelp.env /etc/easytier/kelp.env.bak.$STAMP && \
      sed -i 's|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|' /etc/easytier/kelp.env && \
      systemctl restart easytier-node\" && systemctl is-active easytier-node" | sed 's/^/  /'
fi

banner "4) 等 25 秒重新组网 → 验证邻居与面板"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] 等 25s → hub 上 easytier-cli peer → 本机 curl 面板 /api/status 汇总在线与中继"
else
  sleep 25
  SSHPASS="$KELP_VPS_PASS" sshpass -e ssh "${SSH_OPTS[@]}" "$VPS" \
    "easytier-cli -p 127.0.0.1:15888 peer 2>&1" | sed 's/^/  /'
  curl -sk -u "$KELP_PANEL_USER:$KELP_PANEL_PASS" \
    "https://$KELP_VPS_HOST:18080/api/status" | python3 -c '
import json, sys
d = json.load(sys.stdin); s = d["summary"]
print("  在线 %s/%s | P2P %s | 中继 %s" % (s["online"], s["total"], s["p2p"], s["relay"]))
for x in d["devices"]:
    print("   -", x["ipv4"], x["label"] or x["hostname"], "在线=%s" % x["online"], "路径=%s" % x["cost"])
'
fi

banner "5) hub 重启后门户密钥会变 → 刷新手机 WireGuard 配置与二维码"
REFRESH="$(cd "$(dirname "$0")" && pwd)/refresh-wg-phone-conf.sh"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] bash ${REFRESH}（取新配置 → 写 600 → 重生成二维码 → 推到鉴权区 → 自测）"
elif [[ -f $REFRESH ]]; then
  bash "$REFRESH" 2>&1 | tail -16 | sed 's/^/  /'
else
  say "  未找到 ${REFRESH}（跳过；不用 WireGuard 门户可忽略）"
fi

banner "6) 更新本机身份副本"
if [[ $DRY == 1 ]]; then
  say "  [dry-run] 更新 $LOCAL_ENV 与 $LOCAL_BENV 中的密钥"
else
  sed -i '' "s|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|" "$LOCAL_ENV"
  sed -i '' "s|^ET_NETWORK_SECRET=.*|ET_NETWORK_SECRET=$NEW|" "$LOCAL_BENV"
  say "  已更新（长度 ${#NEW}）"
fi

say ""
say "=== 完成。请手动更新客户端密钥（本机改不了它们）==="
say "  · 手机 EasyTier App：网络密钥填新值"
say "  · Mac / Windows 的 EasyTier GUI：网络密钥填新值，改完重连"
say "  · 若用 WireGuard 门户：重新扫 ~/kelp-run/wg-phone-qr.png"
say "回滚材料：各机 /etc/easytier/kelp.env.bak.${STAMP}、/vol1/kelp/b.env.bak.${STAMP}；本机 $BK"
