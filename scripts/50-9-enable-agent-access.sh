#!/usr/bin/env bash
# 在 A 站点（50.9）一次性开通「公网面板可远程执行的两件事」，需 sudo 运行。
#
# 用途：面板的「管理」页要能轮换网络密钥（改 50.9 的 easytier env + 重启节点），
#       以及做一次网关模式自检并拉起 kelp-gateway 单元。
# 原则：**只放开这两条命令**（sudoers 白名单），其余一切照旧需要口令。
#
# 用法（在你自己的 Mac 上，一条命令）：
#   cd ~/01-project/07-kelp
#   scp scripts/kelp-apply-secret.sh scripts/50-9-enable-agent-access.sh winann@192.168.50.9:/tmp/
#   ssh -t winann@192.168.50.9 'sudo bash /tmp/50-9-enable-agent-access.sh'
#
# 卸载（撤销全部授权与文件）：
#   sudo rm -f /etc/sudoers.d/kelp-agent /usr/local/bin/kelp-apply-secret.sh
set -euo pipefail

SUDOERS=/etc/sudoers.d/kelp-agent
HELPER=/usr/local/bin/kelp-apply-secret.sh
SRC=/tmp/kelp-apply-secret.sh

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行：ssh -t winann@192.168.50.9 'sudo bash /tmp/50-9-enable-agent-access.sh'"; exit 1; }

echo "=== 1) 安装辅助脚本 $HELPER ==="
[[ -f $SRC ]] || { echo "缺少 $SRC（先把 kelp-apply-secret.sh scp 到 /tmp/）"; exit 1; }
install -m 755 -o root -g root "$SRC" "$HELPER"
rm -f "$SRC"

echo "=== 2) 写入限定范围的免密 sudo（先校验语法，再落地）==="
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
# 海带 (Kelp) 项目：公网面板远程执行用的最小授权
#   - kelp-apply-secret.sh        ：轮换组网密钥（根所有、内容固定、只改 env 一个字段并重启节点）
#   - systemctl start/is-active kelp-gateway、kelp-gateway.sh：网关模式自检与拉起
winann ALL=(root) NOPASSWD: /usr/local/bin/kelp-apply-secret.sh, /usr/bin/systemctl start kelp-gateway, /usr/bin/systemctl is-active kelp-gateway, /usr/local/sbin/kelp-gateway.sh
EOF
visudo -c -f "$TMP"
install -m 440 -o root -g root "$TMP" "$SUDOERS"
rm -f "$TMP"
echo "  已写入 $SUDOERS"
grep -v '^#' "$SUDOERS" | sed 's/^/    /'

echo "=== 3) 自检：以 winann 身份执行（不应提示口令）==="
sudo -u winann sudo -n "$HELPER" --check

echo "=== 4) 网关模式：拉起单元并跑一次免客户端设备自测 ==="
sudo systemctl start kelp-gateway
echo "  kelp-gateway: $(systemctl is-active kelp-gateway)（oneshot + RemainAfterExit，正常应为 active）"
sudo /usr/local/sbin/kelp-gateway.sh selftest || true

echo
echo "=== 完成。回滚：sudo rm -f $SUDOERS $HELPER ==="
