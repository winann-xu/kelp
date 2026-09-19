#!/usr/bin/env bash
# 海带 (Kelp) 网关模式诊断 —— 在 192.168.50.9 上以 root 执行一次
#   sudo bash /tmp/kelp-diag.sh
#
# 目的：查清"免客户端设备 TCP 握手通、但 HTTPS 拿不到"的确切断点。
# 假设：50.9 与 NAS 之间当前走【中继】，中继多一层封装 → 路径实际 MTU 更小，
#       TLS 证书那几包（约 1.3KB/包）被丢；公网节点与 NAS 是 P2P 直连，所以同样的脚本能通。
# 做法：扫几个 MSS 值，看哪个能让 HTTPS 通；同时留规则/路由/抓包证据。
set -u

NAS_IP=192.168.1.99
NAS_URL="https://${NAS_IP}:5667/"
NS=kelptest
FAKE_IP=192.168.50.241
GW_IP=192.168.50.240
MSS_RULE=(-p tcp --tcp-flags SYN,RST SYN -m comment --comment "KELP-DIAG mss" -j TCPMSS)
OUT=/tmp/kelp-diag-result.txt

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
hr()  { printf '%s\n' "------------------------------------------------------------" | tee -a "$OUT"; }

: > "$OUT"
say "海带网关模式诊断  $(date '+%F %T')  主机=$(hostname)"

hr; say "【1】当前网络与规则状态"; hr
say "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"
say "tun0 MTU   = $(cat /sys/class/net/tun0/mtu 2>/dev/null)   内网 MTU = $(cat /sys/class/net/ens160/mtu 2>/dev/null)"
say "--- easytier 邻居（关键：与 NAS 是 p2p 还是 relay）---"
/usr/local/bin/easytier-cli peer 2>&1 | tail -4 | tee -a "$OUT"
say "--- 到 B 站点的路由 ---"
ip route get "$NAS_IP" 2>&1 | head -2 | tee -a "$OUT"
say "--- filter FORWARD（海带）---"
iptables -S FORWARD 2>/dev/null | grep -E "KELP|Policy|-P" | head -8 | tee -a "$OUT"
say "--- nat POSTROUTING（海带）---"
iptables -t nat -S POSTROUTING 2>/dev/null | grep -E "KELP|-P" | head -6 | tee -a "$OUT"
say "--- mangle FORWARD（海带）---"
iptables -t mangle -S FORWARD 2>/dev/null | grep -E "KELP|-P" | head -6 | tee -a "$OUT"
say "--- conntrack 上限/用量 ---"
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max 2>/dev/null | tee -a "$OUT"

# ---------------------------------------------------------------- 假设备
cleanup_ns() {
    ip netns del "$NS" >/dev/null 2>&1
    ip link del kelp-t >/dev/null 2>&1
    ip route del "${FAKE_IP}/32" dev kelp-t >/dev/null 2>&1
    return 0
}
setup_ns() {
    cleanup_ns
    ip netns add "$NS" || return 1
    ip link add kelp-t type veth peer name kelp-t-b || return 1
    ip link set kelp-t-b netns "$NS"
    ip addr add "$GW_IP/24" dev kelp-t; ip link set kelp-t up
    ip route replace "${FAKE_IP}/32" dev kelp-t
    ip netns exec "$NS" ip addr add "$FAKE_IP/24" dev kelp-t-b
    ip netns exec "$NS" ip link set kelp-t-b up
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" ip route replace default via "$GW_IP"
    return 0
}

ns_test() {   # 输出 "握手|HTTPS码"
    local tcp code
    ip netns exec "$NS" timeout 6 bash -c "echo > /dev/tcp/$NAS_IP/5667" 2>/dev/null && tcp=通 || tcp=不通
    code=$(ip netns exec "$NS" timeout 15 curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' "$NAS_URL" 2>/dev/null)
    printf '%s|%s' "$tcp" "${code:-000}"
}

set_mss() {   # $1 = clamp | <数字> | off
    while iptables -t mangle -C FORWARD "${MSS_RULE[@]}" --clamp-mss-to-pmtu >/dev/null 2>&1; do
        iptables -t mangle -D FORWARD "${MSS_RULE[@]}" --clamp-mss-to-pmtu; done
    while iptables -t mangle -C FORWARD "${MSS_RULE[@]}" --set-mss 1200 >/dev/null 2>&1; do
        iptables -t mangle -D FORWARD "${MSS_RULE[@]}" --set-mss 1200; done
    for m in 1400 1300 1200 1100 1000; do
        while iptables -t mangle -C FORWARD "${MSS_RULE[@]}" --set-mss "$m" >/dev/null 2>&1; do
            iptables -t mangle -D FORWARD "${MSS_RULE[@]}" --set-mss "$m"; done
    done
    case "$1" in
        off) return 0 ;;
        clamp) iptables -t mangle -I FORWARD 1 "${MSS_RULE[@]}" --clamp-mss-to-pmtu ;;
        *) iptables -t mangle -I FORWARD 1 "${MSS_RULE[@]}" --set-mss "$1" ;;
    esac
}

hr; say "【2】建立模拟设备"; hr
setup_ns || { say "netns 创建失败"; exit 1; }
say "假设备 $(ip netns exec "$NS" ip -br addr show | head -1)"

hr; say "【3】真实 MTU 探测（DF 置位，看路径到底能过多大包）"; hr
for size in 1200 1300 1372 1400 1472; do
    if ip netns exec "$NS" timeout 6 ping -c1 -W2 -M do -s "$size" "$NAS_IP" >/dev/null 2>&1; then
        say "  载荷 ${size}B（IP 包 $((size+28))B）: 通"
    else
        say "  载荷 ${size}B（IP 包 $((size+28))B）: 不通"
    fi
done

hr; say "【4】MSS 扫描：换不同 MSS 值后再试 HTTPS"; hr
for mss in off clamp 1400 1300 1200 1100; do
    set_mss "$mss"
    r=$(ns_test)
    say "  MSS=${mss}  →  TCP 握手 ${r%%|*}  HTTPS ${r##*|}"
done
set_mss clamp

hr; say "【5】失败时的细节（curl -v，看 TLS 卡在哪一步）"; hr
set_mss clamp
ip netns exec "$NS" timeout 20 curl -vsk --noproxy '*' -o /dev/null "$NAS_URL" 2>&1 | grep -E "Connected|TLS|SSL|handshake|HTTP|error|timed|bytes" | head -12 | tee -a "$OUT"
say "--- 对照：同一时刻从 50.9 本机访问同 URL ---"
timeout 15 curl -sk --noproxy '*' -o /dev/null -w "  本机 -> HTTPS %{http_code}\n" "$NAS_URL" 2>&1 | tee -a "$OUT"
say "--- 对照：假设备访问 A 站点本机服务 ---"
ip netns exec "$NS" timeout 15 curl -sk --noproxy '*' -o /dev/null -w "  假设备 -> https://192.168.50.9/ HTTP %{http_code}\n" https://192.168.50.9/ 2>&1 | tee -a "$OUT"

hr; say "【6】抓包（有 tcpdump 才抓）"; hr
if command -v tcpdump >/dev/null 2>&1; then
    ip netns exec "$NS" timeout 12 tcpdump -ni kelp-t-b -c 40 "tcp port 5667" >/tmp/kelp-diag-tcp.txt 2>&1 &
    sleep 1
    ip netns exec "$NS" timeout 8 curl -sk --noproxy '*' -o /dev/null "$NAS_URL" 2>/dev/null
    sleep 12
    say "抓到的包（前 20 行）："
    head -20 /tmp/kelp-diag-tcp.txt | tee -a "$OUT"
else
    say "  无 tcpdump，跳过（可 apt install tcpdump 后再跑）"
fi

hr; say "【7】清理"; hr
set_mss off
cleanup_ns
say "  已清理：netns=$(ip netns list | wc -l)  kelp-t 残留=$(ip link show kelp-t >/dev/null 2>&1 && echo 有 || echo 无)"
say "  （网关本体规则与 ip_forward 未被本脚本改动；如需还原整网：sudo bash /usr/local/sbin/kelp-gateway.sh rollback）"
hr
say "结果已存 $OUT —— 请把这个文件内容贴回给助手"
