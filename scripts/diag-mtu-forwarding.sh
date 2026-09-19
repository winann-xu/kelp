#!/usr/bin/env bash
# 验证：网关转发必须做 SNAT（MASQUERADE），否则对端无回程路由
set -u
TARGET=192.168.1.99

probe() {
    local tag="$1" tcp code
    ip netns exec kelptest timeout 8 bash -c "echo > /dev/tcp/$TARGET/5667" 2>/dev/null && tcp=握手通 || tcp=握手不通
    code=$(ip netns exec kelptest timeout 15 curl -sk -o /dev/null -w '%{http_code}' "https://$TARGET:5667/" 2>/dev/null)
    printf '  %-34s TCP=%-10s HTTPS=%s\n' "$tag" "$tcp" "${code:-失败}"
}

ORIG_FWD=$(cat /proc/sys/net/ipv4/ip_forward)
ip netns del kelptest 2>/dev/null; ip link del kelp-t 2>/dev/null
ip netns add kelptest
ip link add kelp-t type veth peer name kelp-t-b
ip link set kelp-t-b netns kelptest
ip addr add 10.199.199.1/24 dev kelp-t; ip link set kelp-t up
ip netns exec kelptest ip addr add 10.199.199.2/24 dev kelp-t-b
ip netns exec kelptest ip link set kelp-t-b up
ip netns exec kelptest ip link set lo up
ip netns exec kelptest ip route replace default via 10.199.199.1
sysctl -qw net.ipv4.ip_forward=1
iptables -I FORWARD 1 -i kelp-t -o tun0 -j ACCEPT
iptables -I FORWARD 1 -i tun0 -o kelp-t -j ACCEPT

echo "=== 候选修法：SNAT(MASQUERADE) ==="
probe "0. 基线（仅转发）"

iptables -t nat -I POSTROUTING 1 -o tun0 -j MASQUERADE
probe "1. + MASQUERADE 出 tun0"

iptables -t nat -I POSTROUTING 1 -s 10.199.199.0/24 -o tun0 -j MASQUERADE
probe "2. 限定源网段的 MASQUERADE"

echo ""
echo "=== 通过后的内容核对 ==="
echo -n "  页面标题: "; ip netns exec kelptest timeout 15 curl -sk https://192.168.1.99:5667/ 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1
echo -n "  A 站点服务 https://192.168.50.9/ : HTTP "; ip netns exec kelptest timeout 15 curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.50.9/ 2>/dev/null
echo -n "  TCP 22 (NAS SSH 端口已改,应为不通): "; ip netns exec kelptest timeout 6 bash -c "echo > /dev/tcp/$TARGET/22" 2>/dev/null && echo 通 || echo 不通
echo -n "  下载速率（NAS 静态页 1MB x3 往返）: "; ip netns exec kelptest timeout 30 curl -sk -o /dev/null -w '%{speed_download} B/s\n' https://192.168.1.99:5667/ 2>/dev/null

echo ""
echo "=== 清理 ==="
iptables -t nat -D POSTROUTING -s 10.199.199.0/24 -o tun0 -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i kelp-t -o tun0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i tun0 -o kelp-t -j ACCEPT 2>/dev/null
ip netns del kelptest 2>/dev/null; ip link del kelp-t 2>/dev/null
sysctl -qw net.ipv4.ip_forward="$ORIG_FWD"
echo "  ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)  kelp-t 残留=$(iptables -S | grep -c kelp-t)  netns=$(ip netns list | grep -c kelptest)"
