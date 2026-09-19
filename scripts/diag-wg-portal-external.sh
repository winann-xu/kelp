#!/usr/bin/env bash
# 从外部网络（50.9）用真 WireGuard 客户端验证公网节点上的门户确实可从公网接入。
# 全程在【网络命名空间】里做：不碰宿主路由、不碰海带组网路由、测完整体撤销。
# 用法: sudo WG_PRIV=<私钥> WG_PUB=<门户公钥> [ENDPOINT=47.116.73.216:11013] bash diag-wg-portal-external.sh
# 要求: 已装 wireguard-tools（脚本不自动安装，避免污染目标机）
set -uo pipefail

NS=kelpwg
VH=veth-kelph
VN=veth-keln
HOSTIP=10.200.77.1
NSIP=10.200.77.2
UPIF=$(ip route show default | awk '/default/{print $5; exit}')
ENDPOINT=${ENDPOINT:-47.116.73.216:11013}
# 接口名取自文件名（Linux ifname ≤15 字符），故用短名
CFG=/tmp/wgkelp.conf
WG_PRIV=${WG_PRIV:?需要 WG_PRIV（门户 client_config 里的 PrivateKey）}
WG_PUB=${WG_PUB:?需要 WG_PUB（门户 client_config 里的 Peer PublicKey）}

say() { printf '%s\n' "$*"; }
cleanup() {
    say ""
    say "=== 清理 ==="
    ip netns exec "$NS" wg-quick down "$CFG" >/dev/null 2>&1 || true
    if [[ -n "${NAT_RULE:-}" ]]; then
        iptables -t nat -D POSTROUTING -s "$NSIP/32" -o "$UPIF" -j MASQUERADE 2>/dev/null && say "  已删 SNAT 规则" || true
    fi
    for r in "$FW1" "$FW2"; do [[ -n "${r:-}" ]] && iptables -D FORWARD $r 2>/dev/null && say "  已删 FORWARD 规则: $r" || true; done
    ip netns del "$NS" 2>/dev/null && say "  已删命名空间 $NS"
    ip link del "$VH" 2>/dev/null && say "  已删 veth $VH" || true
    shred -u "$CFG" 2>/dev/null || rm -f "$CFG"
    say "  残留检查: netns=$(ip netns list | grep -c "^$NS" || true)  veth=$(ip -br link | grep -c veth-kelp || true)  WG路由=$(ip route | grep -c wg || true)"
}
trap cleanup EXIT

say "=== 0) 前置 ==="
say "  宿主出口接口: $UPIF   命名空间: $NS"
command -v wg-quick >/dev/null || { say "  ❌ 未安装 wireguard-tools（本脚本不自动安装）"; exit 1; }
ip netns list | grep -q "^$NS" && { say "  清理上次残留"; ip netns del "$NS"; }
say "  宿主默认路由（测完必须不变）: $(ip route show default | head -1)"

say ""
say "=== 1) 建命名空间 + veth + 出网 SNAT ==="
ip netns add "$NS"
ip link add "$VH" type veth peer name "$VN"
ip link set "$VN" netns "$NS"
ip addr add "$HOSTIP/24" dev "$VH" && ip link set "$VH" up
ip netns exec "$NS" ip addr add "$NSIP/24" dev "$VN"
ip netns exec "$NS" ip link set "$VN" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route add default via "$HOSTIP"
ip netns exec "$NS" ping -c1 -W2 "$HOSTIP" >/dev/null 2>&1 && say "  netns → 宿主 veth: 通"
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s "$NSIP/32" -o "$UPIF" -j MASQUERADE && NAT_RULE=1
FW1="-s $NSIP/32 -j ACCEPT"; FW2="-d $NSIP/32 -j ACCEPT"
iptables -I FORWARD 1 $FW1; iptables -I FORWARD 1 $FW2
say "  出网探测: $(ip netns exec "$NS" curl -s --noproxy '*' -m 6 -o /dev/null -w 'HTTP %{http_code}' http://mirrors.aliyun.com/ 2>&1)  （证明 netns 能上外网）"

say ""
say "=== 2) 在命名空间内拉起 WireGuard 客户端（真走公网到 $ENDPOINT）==="
umask 077
cat > "$CFG" <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.144.150.2/32
MTU = 1360

[Peer]
PublicKey = $WG_PUB
AllowedIPs = 192.168.1.0/24, 192.168.50.0/24, 10.144.144.0/24, 10.144.150.0/24
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF
ip netns exec "$NS" wg-quick up "$CFG" 2>&1 | sed 's/^/  /'
for i in $(seq 1 12); do
    hs=$(ip netns exec "$NS" wg show "$(basename "$CFG" .conf)" latest-handshakes 2>/dev/null | awk '{print $2}')
    [[ -n "$hs" && "$hs" != "0" ]] && break
    sleep 1
done
say "  --- wg show ---"
ip netns exec "$NS" wg show | sed 's/^/  /'

say ""
say "=== 3) 经隧道访问两个站点（--noproxy 绕开宿主代理）==="
for t in "https://192.168.1.99:5667/|B 站点·飞牛 NAS" "https://192.168.50.9/|A 站点·50.9"; do
    url=${t%%|*}; name=${t##*|}
    out=$(ip netns exec "$NS" curl -sk --noproxy '*' -m 12 -o /tmp/wgtest-body -w '%{http_code} %{time_total}s %{size_download}B' "$url" 2>&1)
    title=$(grep -o "<title>[^<]*" /tmp/wgtest-body 2>/dev/null | head -1 | cut -c8-40)
    printf "  %-22s %s  标题: %s\n" "$name" "$out" "${title:-—}"
    rm -f /tmp/wgtest-body
done
say ""
say "  --- 隧道计数 ---"
ip netns exec "$NS" wg show "$(basename "$CFG" .conf)" transfer | sed 's/^/  /'

say ""
say "=== 4) 宿主路由未被扰动（应与第 0 步一致）==="
say "  宿主默认路由: $(ip route show default | head -1)"
say "  ${VH} 是否出现在宿主默认路由: $(ip route | grep -c "default.*$VH" || true) （应为 0）"
