#!/usr/bin/env bash
# 在 A 站点（50.9）上以 root 应用新的组网密钥。
# 这是给公网面板远程调用的【唯一可写动作】，root 所有、内容固定、只改这一个字段：
#   校验长度与字符集 → 备份 → 改 /etc/easytier/kelp.env → 重启 easytier-node → 回一行结果
#
# 部署（在 50.9 上，一次）：
#   sudo install -m 755 -o root -g root kelp-apply-secret.sh /usr/local/bin/kelp-apply-secret.sh
# 授权（sudoers，限定只能跑这一条）：
#   winann ALL=(root) NOPASSWD: /usr/local/bin/kelp-apply-secret.sh
#
# 用法：sudo /usr/local/bin/kelp-apply-secret.sh <新密钥>   |   sudo /usr/local/bin/kelp-apply-secret.sh --check
set -euo pipefail

ENVF=/etc/easytier/kelp.env
UNIT=easytier-node

case "${1:-}" in
  --check)
    [[ -f $ENVF ]] || { echo "err: 缺少 $ENVF"; exit 1; }
    echo "ok: $UNIT=$(systemctl is-active "$UNIT"), 密钥字段 $(grep -c '^KELP_NET_SECRET=' "$ENVF") 处"
    exit 0
    ;;
  ''|-*)
    echo "err: 用法 kelp-apply-secret.sh <新密钥> [--check]" >&2
    exit 2
    ;;
esac

NEW="$1"
# 与面板侧同一套约束：8–64 位，字符集排除 & | \ " ' 空格 等在 sed/shell 里会出事的字符
if [[ ${#NEW} -lt 8 || ${#NEW} -gt 64 ]]; then
  echo "err: 密钥长度必须 8–64（当前 ${#NEW}）" >&2
  exit 2
fi
if [[ ! $NEW =~ ^[A-Za-z0-9._~!@#%^*+=?-]+$ ]]; then
  echo "err: 密钥含不允许的字符（只允许 字母数字 . _ ~ ! @ # % ^ * + = ? -）" >&2
  exit 2
fi

STAMP=$(date +%Y%m%d%H%M%S)
cp -a "$ENVF" "$ENVF.bak.$STAMP"
sed -i "s|^KELP_NET_SECRET=.*|KELP_NET_SECRET=$NEW|" "$ENVF"
systemctl restart "$UNIT"
sleep 3
echo "ok: 已更新 $ENVF（备份 .bak.$STAMP），$UNIT=$(systemctl is-active "$UNIT")"
