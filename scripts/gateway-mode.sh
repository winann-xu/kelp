#!/usr/bin/env bash
# 海带 (Kelp) M4 —— 网关模式（FR3）
#
# 作用：让 192.168.50.0/24 内【不装 EasyTier 客户端】的设备，只把网关/路由指向本机，
#       就能访问 B 站点 192.168.1.0/24 的资源（含飞牛 NAS）。
#
# 用法（必须以 root 执行）：
#   bash kelp-gateway.sh apply      # 开启转发（记录原值 + 前后自测 + 持久化）
#   bash kelp-gateway.sh rollback   # 回滚（转发开关恢复原值、删除规则与持久化）
#   bash kelp-gateway.sh status     # 只读查看状态与原始值
#   bash kelp-gateway.sh selftest   # 只跑"免客户端设备"自测（不改任何配置）
#
# 设计约束：
#   - 幂等：用 iptables -C 判重，重复 apply 不产生重复规则
#   - 零污染：所有规则带 KELP-GATEWAY 注释；rollback 精确删除自己加的规则并恢复 ip_forward 原值
#   - 可验证：用网络命名空间模拟一台"没有客户端、网关指向本机"的设备，apply 前后各测一次
set -uo pipefail

STATE_DIR=/etc/kelp
ORIG_FILE="$STATE_DIR/gateway-originals.json"
SYSCTL_FILE=/etc/sysctl.d/99-kelp-gateway.conf
UNIT=/etc/systemd/system/kelp-gateway.service
SELF_PATH=/usr/local/sbin/kelp-gateway.sh
LAN_IF=ens160                 # 站点内网接口（可用参数覆盖）
TUN_IF=tun0                   # EasyTier 虚拟接口
NS=kelptest                   # 自测网络命名空间
VETH_HOST=kelp-t              # 自测 veth（网关机侧）
VETH_NS=kelp-t-b              # 自测 veth（"设备"侧）
FAKE_CIDR=192.168.50.241/24   # 模拟设备地址（不占用任何真实设备 IP）
FAKE_IP=${FAKE_CIDR%/*}
GW_IP=192.168.50.240          # 模拟设备眼中的"网关"（即本机）
B_TARGET=192.168.1.99         # B 站点资源：飞牛 NAS
B_URL=https://192.168.1.99:5667/

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------- 自测
cleanup_ns() {
    ip netns del "$NS" >/dev/null 2>&1
    ip link del "$VETH_HOST" >/dev/null 2>&1
    ip route del "${FAKE_IP}/32" dev "$VETH_HOST" >/dev/null 2>&1
    return 0
}

setup_ns() {
    cleanup_ns
    ip netns add "$NS" || return 1
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS" || return 1
    ip link set "$VETH_NS" netns "$NS" || return 1
    ip addr add "$GW_IP/24" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up
    ip route replace "${FAKE_IP}/32" dev "$VETH_HOST"   # 回程确定性
    ip netns exec "$NS" ip addr add "$FAKE_CIDR" dev "$VETH_NS"
    ip netns exec "$NS" ip link set "$VETH_NS" up
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" ip route replace default via "$GW_IP"
    return 0
}

run_test() {   # 输出 "ping结果|HTTP码"
    local ping code
    if ip netns exec "$NS" timeout 6 ping -c2 -W2 "$B_TARGET" >/dev/null 2>&1; then ping=ping通; else ping=ping不通; fi
    code=$(ip netns exec "$NS" timeout 12 curl -sk -o /dev/null -w '%{http_code}' "$B_URL" 2>/dev/null)
    printf '%s|%s' "$ping" "${code:-000}"
}

selftest() {
    hr
    say "[自测] 模拟一台【未装 EasyTier 客户端】的设备：IP $FAKE_CIDR  网关 $GW_IP（本机）"
    say "       目标：$B_URL（B 站点飞牛 NAS）"
    if ! setup_ns; then say "  自测环境创建失败（缺 iproute2 / netns 支持）"; cleanup_ns; return 2; fi
    local r; r=$(run_test)
    say "  ping $B_TARGET : ${r%%|*}"
    say "  curl $B_URL : HTTP ${r##*|}"
    cleanup_ns
    if [[ "${r##*|}" == "200" ]]; then
        say "  => 自测通过：免客户端设备已能访问 B 站点资源"
        return 0
    fi
    say "  => 自测未通过（若发生在 apply 之前，属预期：转发尚未开启）"
    return 3
}

# ---------------------------------------------------------------- 规则
have_rule() { iptables -C FORWARD "$@" >/dev/null 2>&1; }
our_rules() { iptables -S FORWARD 2>/dev/null | grep -c 'KELP-GATEWAY'; }

add_one() {
    have_rule "$@" && return 0
    iptables -I FORWARD 1 "$@" && say "  + ${*}"
}

del_one() {
    while have_rule "$@"; do iptables -D FORWARD "$@"; done
}

add_rules() {
    local ifc
    for ifc in "$LAN_IF" "$VETH_HOST"; do
        add_one -i "$ifc" -o "$TUN_IF" -m comment --comment "KELP-GATEWAY out" -j ACCEPT
        add_one -i "$TUN_IF" -o "$ifc" -m comment --comment "KELP-GATEWAY in" -j ACCEPT
    done
    add_one -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "KELP-GATEWAY est" -j ACCEPT
}

del_rules() {
    local ifc
    for ifc in "$LAN_IF" "$VETH_HOST"; do
        del_one -i "$ifc" -o "$TUN_IF" -m comment --comment "KELP-GATEWAY out" -j ACCEPT
        del_one -i "$TUN_IF" -o "$ifc" -m comment --comment "KELP-GATEWAY in" -j ACCEPT
    done
    del_one -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "KELP-GATEWAY est" -j ACCEPT
    say "  剩余海带规则条数 = $(our_rules)"
}

restore_unit() {
    cat > "$UNIT" <<EOF
[Unit]
Description=Kelp gateway mode (iptables rules for FR3)
After=network-online.target easytier-node.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_PATH rules-only

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable kelp-gateway.service >/dev/null 2>&1
}

# ---------------------------------------------------------------- 状态
show_state() {
    say "ip_forward            = $(cat /proc/sys/net/ipv4/ip_forward)"
    say "FORWARD 链默认策略    = $(iptables -S FORWARD 2>/dev/null | head -1 | awk '{print $NF}')"
    say "海带网关规则条数      = $(our_rules)"
    say "目标接口存在性        = $(ip link show "$TUN_IF" >/dev/null 2>&1 && echo "$TUN_IF 存在" || echo "$TUN_IF 缺失")"
    say "sysctl 持久化文件     = $( [[ -f $SYSCTL_FILE ]] && echo 存在 || echo 不存在 )"
    say "开机自恢复单元        = $( [[ -f $UNIT ]] && echo 存在 || echo 不存在 )"
    say "原始值记录            = $( [[ -f $ORIG_FILE ]] && cat "$ORIG_FILE" || echo '(尚未记录)' )"
}

# ---------------------------------------------------------------- 主流程
apply() {
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    if [[ ! -f $ORIG_FILE ]]; then
        printf '{"ip_forward":"%s","forward_policy":"%s","recorded_at":"%s"}\n' \
            "$(cat /proc/sys/net/ipv4/ip_forward)" \
            "$(iptables -S FORWARD 2>/dev/null | head -1 | awk '{print $NF}')" \
            "$(date '+%Y-%m-%d %H:%M:%S')" > "$ORIG_FILE"
        say "已记录原始值 -> $ORIG_FILE"
    else
        say "原始值已存在（保留首次记录，供回滚使用）：$(cat "$ORIG_FILE")"
    fi

    say ""; say "### 1) 开启转发【之前】的自测（预期：不通）"
    selftest || true

    say ""; say "### 2) 开启 ip_forward + FORWARD 放行（仅针对 $LAN_IF ↔ $TUN_IF）"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null && say "  net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"
    printf 'net.ipv4.ip_forward=1\n' > "$SYSCTL_FILE" && say "  写入 $SYSCTL_FILE（重启后仍生效）"
    add_rules
    install -m 755 "$0" "$SELF_PATH" && restore_unit && say "  已安装开机自恢复单元 kelp-gateway.service"

    say ""; say "### 3) 开启转发【之后】的自测（预期：HTTP 200）"
    selftest; local rc=$?

    say ""; hr; say "当前状态："; show_state; hr
    if [[ $rc == 0 ]]; then
        say "✅ 网关模式就绪：站内免客户端设备把网关（或一条静态路由）指向 192.168.50.9 即可访问 B 站点"
    else
        say "❌ 自测未通过，请把以上输出发回给助手排查（配置已写入，可随时 rollback）"
    fi
    return $rc
}

rollback() {
    say "### 回滚：删除海带网关规则并恢复 ip_forward 原值"
    del_rules
    systemctl disable --now kelp-gateway.service >/dev/null 2>&1
    rm -f "$UNIT" "$SYSCTL_FILE" "$SELF_PATH"
    systemctl daemon-reload >/dev/null 2>&1
    local orig=0
    [[ -f $ORIG_FILE ]] && orig=$(sed -n 's/.*"ip_forward":"\([01]\)".*/\1/p' "$ORIG_FILE")
    sysctl -w net.ipv4.ip_forward="${orig:-0}" >/dev/null && say "  ip_forward 已恢复为 $(cat /proc/sys/net/ipv4/ip_forward)"
    say "  （原始值记录保留在 $ORIG_FILE 供复核）"
    cleanup_ns
    say ""; hr; show_state; hr
    say "✅ 已回滚：站内设备把网关改回原网关后，网络即回到配置前状态"
}

case "${1:-apply}" in
    apply)      apply ;;
    rollback)   rollback ;;
    status)     hr; show_state; hr; ip -br addr show | sed 's/^/  /'; hr ;;
    selftest)   selftest; rc=$?; cleanup_ns; exit $rc ;;
    rules-only) add_rules ;;
    *) say "用法: $0 {apply|rollback|status|selftest}"; exit 2 ;;
esac
