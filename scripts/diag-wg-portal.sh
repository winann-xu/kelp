#!/usr/bin/env bash
# 在公网节点上自测 WireGuard 门户：用真 wg 客户端连本机门户，验证能否穿透到两站点
# 用完即清理；AllowedIPs 只用 /32，避免扰动主机既有 EasyTier 路由
set -u

WGC=/etc/wireguard/wg-kelptest.conf
# 凭据来源：默认读取 /etc/kelp/wg-client.conf（600，不入库）；
# 也可用环境变量 WG_PRIVATE_KEY / WG_PUBLIC_KEY / WG_ENDPOINT 覆盖。
CLIENT_CONF=${WG_CLIENT_CONF:-/etc/kelp/wg-client.conf}
say() { printf '%s\n' "$*"; }

read_client_conf() {
    if [[ -n "${WG_PRIVATE_KEY:-}" && -n "${WG_PUBLIC_KEY:-}" ]]; then
        PRIV=$WG_PRIVATE_KEY; PUB=$WG_PUBLIC_KEY; EP=${WG_ENDPOINT:-127.0.0.1:11013}
        return 0
    fi
    [[ -f $CLIENT_CONF ]] || return 1
    PRIV=$(sed -n 's/^PrivateKey *= *//p' "$CLIENT_CONF" | head -1)
    PUB=$(sed -n 's/^PublicKey *= *//p' "$CLIENT_CONF" | head -1)
    EP=${WG_ENDPOINT:-$(sed -n 's/^Endpoint *= *//p' "$CLIENT_CONF" | head -1)}
    [[ -n $PRIV && -n $PUB ]]
}

if ! read_client_conf; then
    say "缺少 WireGuard 客户端凭据：请把手机配置放到 $CLIENT_CONF（600），"
    say "或设置 WG_PRIVATE_KEY / WG_PUBLIC_KEY / WG_ENDPOINT 环境变量后重跑。"
    exit 2
fi

say "=== 1) 安装 wireguard-tools ==="
if ! command -v wg >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools >/dev/null 2>&1
fi
command -v wg >/dev/null 2>&1 && say "  wg: $(wg --version)" || { say "  安装失败"; exit 1; }

say "=== 2) 写测试客户端配置 ==="
mkdir -p /etc/wireguard
cat > "$WGC" <<EOF
[Interface]
PrivateKey = $PRIV
Address = 10.144.150.2/24
MTU = 1360

[Peer]
PublicKey = $PUB
AllowedIPs = 192.168.1.99/32, 192.168.50.9/32
Endpoint = $EP
PersistentKeepalive = 25
EOF
chmod 600 "$WGC"
grep -vE "PrivateKey" "$WGC" | sed 's/^/  /'

say "=== 3) 拉起隧道 ==="
wg-quick up wg-kelptest 2>&1 | sed 's/^/  /'
sleep 3
say "  --- wg show ---"
wg show wg-kelptest 2>&1 | sed 's/^/  /' | head -12

say "=== 4) 穿透测试 ==="
say -n ""
printf "  公网节点自己 -> https://192.168.1.99:5667/ : "
curl -sk --noproxy '*' -m 10 -o /dev/null -w "HTTP %{http_code}\n" https://192.168.1.99:5667/ 2>/dev/null
printf "  公网节点自己 -> https://192.168.50.9/      : "
curl -sk --noproxy '*' -m 10 -o /dev/null -w "HTTP %{http_code}\n" https://192.168.50.9/ 2>/dev/null
printf "  NAS 页面标题: "
curl -sk --noproxy '*' -m 10 https://192.168.1.99:5667/ 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1
say "  --- 隧道流量计数 ---"
wg show wg-kelptest transfer 2>&1 | sed 's/^/  /'

say "=== 5) 清理 ==="
wg-quick down wg-kelptest 2>&1 | sed 's/^/  /'
rm -f "$WGC"
say "  残留: $(ip link show wg-kelptest >/dev/null 2>&1 && echo 有 || echo 无)  配置: $(test -f $WGC && echo 有 || echo 已删)"
say "  --- 主机到 NAS 的原路由是否完好（应仍走 tun0）---"
ip route get 192.168.1.99 2>&1 | head -1 | sed 's/^/  /'
