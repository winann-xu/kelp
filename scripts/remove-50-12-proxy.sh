#!/usr/bin/env bash
# 删除 192.168.50.12 在 50.9 上的全部代理配置（用户 2026-09-20 明确指令）
# 特性：先备份到 /root/proxy-backup-<时间戳>/ ，可整目录还原；幂等；末尾给出前后对照证据。
set -uo pipefail

STAMP=$(date +%Y%m%d%H%M%S)
BK=/root/proxy-backup-$STAMP
TARGET=192.168.50.12
say() { printf '%s\n' "$*"; }

say "=== 0) 备份目录 $BK ==="
mkdir -p "$BK"
for f in /etc/environment /etc/apt/apt.conf.d/99proxy /etc/profile.d/proxy.sh /home/winann/.bashrc; do
    if [[ -f $f ]]; then
        mkdir -p "$BK/$(dirname "$f")"
        cp -a "$f" "$BK$f" && say "  已备份 $f"
    fi
done
cat > "$BK/RESTORE.md" <<'EOF'
还原方式（在该机上执行）：
  sudo cp -a <备份目录>/etc/environment /etc/environment
  sudo cp -a <备份目录>/etc/apt/apt.conf.d/99proxy /etc/apt/apt.conf.d/99proxy
  sudo cp -a <备份目录>/etc/profile.d/proxy.sh /etc/profile.d/proxy.sh
  sudo cp -a <备份目录>/home/winann/.bashrc /home/winann/.bashrc
（然后重新登录或 source 相应文件）
EOF
say "  已写还原说明 $BK/RESTORE.md"

say ""
say "=== 1) /etc/environment：删掉 6 行代理变量 ==="
say "  改前："
grep -n -iE 'proxy' /etc/environment | sed 's/^/    /' || true
grep -v -iE '^[[:space:]]*(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' /etc/environment > /tmp/env.new
if [[ -s /tmp/env.new ]]; then cp /tmp/env.new /etc/environment; else : > /etc/environment; fi
rm -f /tmp/env.new
say "  改后（应为空）："; grep -n -iE 'proxy' /etc/environment | sed 's/^/    /' || say "    （无代理行）✅"
say "  文件其余内容："; sed 's/^/    /' /etc/environment

say ""
say "=== 2) /etc/apt/apt.conf.d/99proxy：整文件移除 ==="
rm -f /etc/apt/apt.conf.d/99proxy && say "  已删除 ✅"

say ""
say "=== 3) /etc/profile.d/proxy.sh：整文件移除 ==="
rm -f /etc/profile.d/proxy.sh && say "  已删除 ✅"

say ""
say "=== 4) /home/winann/.bashrc：移除 50.12 的 SOCKS alias 两行 ==="
if grep -q '192.168.50.12' /home/winann/.bashrc; then
    grep -v -E '(192\.168\.50\.12|Proxy via 50\.12)' /home/winann/.bashrc > /tmp/brc.new && cp /tmp/brc.new /home/winann/.bashrc && rm -f /tmp/brc.new
    chown winann:winann /home/winann/.bashrc
    say "  已清理 ✅"
else
    say "  （无匹配，已幂等）"
fi
say "  残留检查：$(grep -c '192.168.50.12' /home/winann/.bashrc || true) 处（应为 0）"

say ""
say "=== 5) 全盘再扫一遍还有没有别的代理口子 ==="
say "  -- 配置类文件里剩余的 50.12 / 10809 引用（排除日志与备份）--"
sudo grep -rl -E "192\.168\.50\.12|:10809" /etc /home/winann /root 2>/dev/null \
  | grep -vE "^/root/proxy-backup-|proxy_test\.log|/\.hermes/|/\.cache/" | sed 's/^/    /' || say "    无"
say "  -- 其他常见代理位置 --"
for f in /etc/wgetrc /home/winann/.wgetrc /home/winann/.curlrc /home/winann/.gitconfig /home/winann/.npmrc /home/winann/.docker/config.json /etc/systemd/system/docker.service.d/*.conf; do
    [[ -e $f ]] && { if grep -qiE 'proxy' "$f" 2>/dev/null; then say "    ⚠️ $f 仍含 proxy："; grep -n -i proxy "$f" | sed 's/^/       /'; else say "    ✓ $f（存在但无 proxy）"; fi; }
done
say "  -- systemd 单元里的 Environment=*proxy* --"
sudo grep -rl -iE 'Environment=.*proxy' /etc/systemd/system 2>/dev/null | sed 's/^/    /' || say "    无"

say ""
say "=== 6) 生效验证（新登录 shell，不带 --noproxy）==="
sudo -u winann bash -lc 'echo "  http_proxy=${http_proxy:-<空>}  https_proxy=${https_proxy:-<空>}"
  for u in https://www.baidu.com https://ghfast.top https://api.github.com; do
      printf "  %-28s %s\n" "$u" "$(curl -s -o /dev/null -m 12 -w "HTTP %{http_code} %{time_total}s" "$u" 2>&1)"
  done'
say ""
say "=== 7) apt 是否恢复（只更新索引，不装东西）==="
DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -3 | sed 's/^/  /' && say "  apt update 退出码 0 ✅"

say ""
say "=== 8) 备份目录清单（回滚用）==="
find "$BK" -type f | sed 's/^/  /'
