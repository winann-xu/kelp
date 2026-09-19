#!/usr/bin/env bash
# 海带 (Kelp) 节点安装脚本 —— 在目标机上以 root 执行
#
# 用法（示例，50.9 作 A 站点节点）：
#   sudo bash setup-node.sh \
#     --net-name kelp-xxxx --net-secret <40位随机串> \
#     --hostname kelp-50-9 --ipv4 10.144.144.9 \
#     --proxy-nets 192.168.50.0/24 \
#     --peer tcp://47.116.73.216:11010 \
#     --rpc-whitelist 10.144.144.1 \
#     --zip /tmp/kelp-et.zip
#
# 说明：
# - 幂等：可重复执行，会重写环境文件与 unit 并重启服务
# - 凭据只落在 /etc/easytier/kelp.env（600），不进命令行历史里的日志
# - 不修改 ip_forward / iptables（网关模式属 M4，单独执行）
set -euo pipefail

NET_NAME=""; NET_SECRET=""; HOSTNAME_="kelp-node"; IPV4=""; PROXY_NETS=""
PEER=""; RPC_WHITELIST=""; ZIP=""; BIN_DIR=/usr/local/bin
UNIT=/etc/systemd/system/easytier-node.service
ENV_FILE=/etc/easytier/kelp.env

while [[ $# -gt 0 ]]; do
  case "$1" in
    --net-name) NET_NAME="$2"; shift 2;;
    --net-secret) NET_SECRET="$2"; shift 2;;
    --hostname) HOSTNAME_="$2"; shift 2;;
    --ipv4) IPV4="$2"; shift 2;;
    --proxy-nets) PROXY_NETS="$2"; shift 2;;
    --peer) PEER="$2"; shift 2;;
    --rpc-whitelist) RPC_WHITELIST="$2"; shift 2;;
    --zip) ZIP="$2"; shift 2;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "必须以 root 执行" >&2; exit 1; }
[[ -n "$NET_NAME" && -n "$NET_SECRET" && -n "$IPV4" && -n "$ZIP" && -n "$PEER" ]] || {
  echo "缺少必需参数（--net-name/--net-secret/--ipv4/--peer/--zip）" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "找不到安装包: $ZIP" >&2; exit 1; }

echo "== 1/5 安装二进制 =="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 -m zipfile -e "$ZIP" "$TMP/" || { echo "解包失败（需要 python3）" >&2; exit 1; }
SRC=$(find "$TMP" -name easytier-core -type f | head -1); SRC_DIR=$(dirname "$SRC")
install -m755 "$SRC_DIR/easytier-core" "$BIN_DIR/easytier-core"
install -m755 "$SRC_DIR/easytier-cli"  "$BIN_DIR/easytier-cli"
"$BIN_DIR/easytier-core" --version

echo "== 2/5 写环境文件（600）=="
mkdir -p /etc/easytier && chmod 700 /etc/easytier
umask 077
cat > "$ENV_FILE" <<EOF
# Kelp node identity - do not publish
KELP_NET_NAME=$NET_NAME
KELP_NET_SECRET=$NET_SECRET
EOF
chmod 600 "$ENV_FILE"

echo "== 3/5 写 systemd unit =="
PROXY_ARG=""
[[ -n "$PROXY_NETS" ]] && PROXY_ARG="--proxy-networks $PROXY_NETS"
RPC_ARG=""
[[ -n "$RPC_WHITELIST" ]] && RPC_ARG="--rpc-portal-whitelist $RPC_WHITELIST"

cat > "$UNIT" <<EOF
[Unit]
Description=Kelp EasyTier Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_DIR/easytier-core --network-name=\${KELP_NET_NAME} --network-secret=\${KELP_NET_SECRET} --hostname $HOSTNAME_ --ipv4 $IPV4 $PROXY_ARG --peer $PEER --rpc-portal 0.0.0.0:15888 $RPC_ARG
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "== 4/5 启动 =="
systemctl daemon-reload
systemctl enable --now easytier-node
sleep 5

echo "== 5/5 自检 =="
systemctl is-active easytier-node
ss -lntup 2>/dev/null | grep -E "11010|15888" || true
"$BIN_DIR/easytier-cli" node 2>/dev/null | head -12 || true
"$BIN_DIR/easytier-cli" peer -o json 2>/dev/null | head -c 400 || true
echo
echo "完成。更换身份/参数：重跑本脚本即可（幂等）。"
