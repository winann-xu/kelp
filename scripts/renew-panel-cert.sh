#!/usr/bin/env bash
# 重签公网节点面板证书：补上 subjectAltName（Chrome/Safari 必需），旧证书就地备份
set -euo pipefail
cd /etc/kelp
STAMP=$(date +%Y%m%d%H%M%S)

echo "=== 0) 备份旧证书（确认无 SAN）==="
openssl x509 -in panel.crt -noout -ext subjectAltName 2>&1 | sed 's/^/  /' || echo "  （旧证书无 SAN —— 这就是浏览器拒绝的原因）"
cp -a panel.crt "panel.crt.bak.$STAMP" && cp -a panel.key "panel.key.bak.$STAMP" && echo "  已备份 -> panel.{crt,key}.bak.$STAMP"

echo ""
echo "=== 1) 生成带 SAN 的新证书（10 年）==="
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout panel.key -out panel.crt \
  -subj "/C=CN/O=Kelp/CN=47.116.73.216" \
  -addext "subjectAltName=IP:47.116.73.216,IP:127.0.0.1,DNS:localhost" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>&1 | sed 's/^/  /'
chmod 600 panel.key && chmod 644 panel.crt

echo ""
echo "=== 2) 新证书自检 ==="
openssl x509 -in panel.crt -noout -subject -issuer -dates | sed 's/^/  /'
openssl x509 -in panel.crt -noout -ext subjectAltName | sed 's/^/  /'
openssl x509 -in panel.crt -noout -ext extendedKeyUsage | sed 's/^/  /'
echo "  SHA-256: $(openssl x509 -in panel.crt -noout -fingerprint -sha256 | cut -d= -f2)"

echo ""
echo "=== 3) 重启面板并自检 ==="
systemctl restart kelp-panel
sleep 6
echo "  服务: $(systemctl is-active kelp-panel)"
echo "  监听: $(ss -lntp | grep -c 18080) 条"
curl -sk -o /dev/null -w "  本机握手后请求: HTTP %{http_code}（401=正常要求登录）\n" https://127.0.0.1:18080/
echo "  实际下发的证书 SAN:"
echo | openssl s_client -connect 127.0.0.1:18080 -servername 47.116.73.216 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /'
