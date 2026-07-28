#!/bin/bash
# K3 用量监控 · 双击启动
cd "$(dirname "$0")"
# 若已在运行则直接打开页面
if curl -s --max-time 2 http://127.0.0.1:8899/api/usage >/dev/null 2>&1; then
  open http://127.0.0.1:8899
  exit 0
fi
exec python3 server.py
