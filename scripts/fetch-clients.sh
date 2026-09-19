#!/usr/bin/env bash
# 在公网节点上下载各平台客户端（EasyTier v2.6.4，经 ghfast 镜像），供下载页分发
set -uo pipefail

DIR=/opt/kelp/downloads
BASE=https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/v2.6.4
mkdir -p "$DIR"

FILES=(
  "easytier-gui_2.6.4_x64-setup.exe"
  "easytier-gui_2.6.4_aarch64.dmg"
  "easytier-gui_2.6.4_x64.dmg"
  "app-arm64-release.apk"
  "app-arm-release.apk"
  "easytier-linux-x86_64-v2.6.4.zip"
  "easytier-windows-x86_64-v2.6.4.zip"
)

say() { printf '%s\n' "$*"; }

# 并行下载（最多 3 个同时）
i=0
for f in "${FILES[@]}"; do
    if [[ -s "$DIR/$f" ]]; then say "跳过（已存在）: $f"; continue; fi
    say "下载: $f"
    curl -sL --retry 2 -m 900 -o "$DIR/$f.part" "$BASE/$f" &
    i=$((i + 1))
    if (( i % 3 == 0 )); then wait; fi
done
wait

say ""
say "=== 结果 ==="
for f in "${FILES[@]}"; do
    if [[ -s "$DIR/$f.part" ]]; then mv "$DIR/$f.part" "$DIR/$f"; fi
    if [[ -s "$DIR/$f" ]]; then
        printf "  %-46s %8.1f MB\n" "$f" "$(echo "scale=1; $(stat -c%s "$DIR/$f")/1048576" | bc)"
    else
        printf "  %-46s %s\n" "$f" "❌ 缺失"
    fi
done
rm -f "$DIR"/*.part
say ""
say "=== 生成 SHA256SUMS ==="
( cd "$DIR" && sha256sum "${FILES[@]}" 2>/dev/null | grep -v "❌" > SHA256SUMS && cat SHA256SUMS | sed 's/^/  /' )
say ""
say "目录合计: $(du -sh "$DIR" | cut -f1)"
