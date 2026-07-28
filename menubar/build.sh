#!/bin/bash
# 一键构建 K3Monitor.app（需要 Xcode 命令行工具：xcode-select --install）
set -e
cd "$(dirname "$0")"

# 图标不在仓库里（版权属月之暗面），首次构建自动从 App Store 拉取
[ -f kimi-icon.jpg ] || ./fetch-icon.sh

mkdir -p K3Monitor.app/Contents/MacOS K3Monitor.app/Contents/Resources
cp Info.plist K3Monitor.app/Contents/
cp index.html kimi-icon.jpg K3Monitor.app/Contents/Resources/

# App 图标（可选，失败不影响主程序）
if [ ! -f K3Monitor.app/Contents/Resources/AppIcon.icns ]; then
  rm -rf AppIcon.iconset
  mkdir -p AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s kimi-icon.jpg --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null 2>&1 || true
    sips -z $((s*2)) $((s*2)) kimi-icon.jpg --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null 2>&1 || true
  done
  iconutil -c icns AppIcon.iconset -o K3Monitor.app/Contents/Resources/AppIcon.icns 2>/dev/null || true
fi

swiftc -O -o K3Monitor.app/Contents/MacOS/K3Monitor main.swift -framework Cocoa -framework WebKit
echo "✅ 构建完成: menubar/K3Monitor.app"
