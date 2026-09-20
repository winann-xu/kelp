#!/usr/bin/env bash
# 重新生成手机 WireGuard 配置与二维码（门户密钥会随 hub 重启变化，故每次重启后都要跑）
set -uo pipefail
VPS="root@47.116.73.216"
ENVF="$HOME/.config/kelp/kelp.env"          # 凭据只从这里读，绝不写进脚本
OUT_CONF="$HOME/.config/kelp/wg-phone.conf"
OUT_QR="$HOME/kelp-run/wg-phone-qr.png"
say() { printf '%s\n' "$*"; }
[[ -f $ENVF ]] || { say "缺少 $ENVF（面板凭据）"; exit 1; }
PANEL_USER=$(sed -n 's/^KELP_PANEL_USER=//p' "$ENVF" | head -1)
PANEL_PASS=$(sed -n 's/^KELP_PANEL_PASS=//p' "$ENVF" | head -1)
[[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]] || { say "$ENVF 里缺 KELP_PANEL_USER/PASS"; exit 1; }

### 凭据：只从 600 文件读，绝不写进脚本 ####################################
CREDF="$HOME/.config/kelp/creds.env"
[[ -f $CREDF ]] || { say "缺少 $CREDF（各机登录凭据）"; exit 1; }
# shellcheck disable=SC1090
. "$CREDF"
: "${KELP_VPS_PASS:?creds.env 里缺 KELP_VPS_PASS}"
export SSHPASS="$KELP_VPS_PASS"
say "=== 1) 从门户取最新客户端配置 ==="
RAW=$(sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$VPS" \
  'easytier-cli -p 127.0.0.1:15888 vpn-portal 2>/dev/null' | sed -n '/client_config_start/,/client_config_end/p')

# 注意1：macOS 的 grep 不支持 -P；注意2：base64 私钥结尾的 '=' 不能被当分隔符吃掉（长度必须 44）
PRIV=$(printf '%s\n' "$RAW" | sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' | head -1 | tr -d ' ')
PUB=$(printf '%s\n' "$RAW" | sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' | head -1 | tr -d ' ')
ALLOWED=$(printf '%s\n' "$RAW" | sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' | head -1 | tr -d ' ')
[[ -n "$PRIV" && -n "$PUB" ]] || { say "  ❌ 解析失败：门户没有返回可用配置，中止（避免写入坏配置）"; exit 1; }
say "  新私钥: ${PRIV:0:8}… 长度 ${#PRIV}（应为 44）；门户公钥: ${PUB:0:8}… 长度 ${#PUB}（应为 44）"
[[ ${#PRIV} -eq 44 && ${#PUB} -eq 44 ]] || { say "  ❌ 密钥长度不对，中止（避免写入坏配置）"; exit 1; }
say "  AllowedIPs: $ALLOWED"

say ""
say "=== 2) 生成本机标准配置（含 MTU 与 Endpoint）==="
cat > "$OUT_CONF" <<EOF
[Interface]
PrivateKey = $PRIV
Address = 10.144.150.2/24
MTU = 1360

[Peer]
PublicKey = $PUB
AllowedIPs = $ALLOWED
Endpoint = 47.116.73.216:11013
PersistentKeepalive = 25
EOF
chmod 600 "$OUT_CONF"
grep -v PrivateKey "$OUT_CONF" | sed 's/^/  /'

say ""
say "=== 3) 重新生成二维码 ==="
/usr/bin/python3 - "$OUT_CONF" "$OUT_QR" <<'PY'
import sys, pathlib, segno
conf = pathlib.Path(sys.argv[1]).read_text()
segno.make(conf, error="m").save(sys.argv[2], scale=8, border=3)
print("  二维码:", sys.argv[2], pathlib.Path(sys.argv[2]).stat().st_size, "bytes")
PY

say ""
say "=== 4) 推到公网节点的鉴权区（覆盖旧配置与旧二维码）==="
sshpass -e scp -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$OUT_CONF" "$VPS":/opt/kelp/private/conf >/dev/null 2>&1 && say "  已更新 /wg/conf"
sshpass -e scp -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$OUT_QR"   "$VPS":/opt/kelp/private/qr.png >/dev/null 2>&1 && say "  已更新 /wg/qr.png"
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$VPS" 'chmod 600 /opt/kelp/private/*; ls -l /opt/kelp/private/ | tail -2'
say "  外部（本机）核对 /wg/conf 的私钥长度："
curl -sk -u "$PANEL_USER:$PANEL_PASS" https://47.116.73.216:18080/wg/conf | awk -F'=' '/^PrivateKey/{gsub(/ /,"",$2); printf "    %s… 共 %d 字符（应为 44）\n", substr($2,1,8), length($2)}'

say ""
say "=== 5) 自测：用新配置在本机（公网节点）连门户 ==="
sshpass -e ssh -o StrictHostKeyChecking=no -o NumberOfPasswordPrompts=1 "$VPS" \
  "cp /opt/kelp/private/conf /tmp/wgselftest.conf && \
   sed -i 's|^Endpoint = .*|Endpoint = 127.0.0.1:11013|' /tmp/wgselftest.conf && \
   sed -i 's|^AllowedIPs = .*|AllowedIPs = 192.168.1.99/32,192.168.50.9/32|' /tmp/wgselftest.conf && \
   wg-quick up /tmp/wgselftest.conf >/dev/null 2>&1 && sleep 4 && \
   echo '  wg 握手: '\$(wg show wgselftest latest-handshakes | awk '{print \$2}') && \
   curl -sk --noproxy '*' -o /dev/null -w '  经隧道访问 NAS: HTTP %{http_code}\n' https://192.168.1.99:5667/ && \
   wg-quick down /tmp/wgselftest.conf >/dev/null 2>&1 && rm -f /tmp/wgselftest.conf && echo '  已清理'"
