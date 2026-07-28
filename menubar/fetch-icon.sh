#!/bin/bash
# 从 App Store 官方接口下载 Kimi App 图标（图标版权属月之暗面/Moonshot AI，仅供本工具界面展示使用）
set -e
cd "$(dirname "$0")"
URL=$(curl -s --max-time 20 "https://itunes.apple.com/search?term=Kimi&country=cn&entity=software&limit=1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['results'][0]['artworkUrl512'].replace('512x512bb.jpg','1024x1024bb.jpg'))")
curl -s --max-time 30 "$URL" -o kimi-icon.jpg
echo "✅ Kimi 图标已下载: kimi-icon.jpg"
