#!/usr/bin/env python3
"""K3 用量监控 · 本地服务
读取 ~/.hermes/config.yaml 里的 kimi-coding key，代理查询
https://api.kimi.com/coding/v1/usages，并托管监控页面。
只用标准库，无需 pip 安装任何东西。
"""
import json
import os
import re
import time
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.request import Request, build_opener, ProxyHandler

# python.org Python 自带的 CA 目录是空的；launchd 下没有 SSL_CERT_FILE
# 环境变量时会验签失败。回退到 macOS 系统证书库（始终存在）。
if not os.environ.get("SSL_CERT_FILE") and os.path.exists("/private/etc/ssl/cert.pem"):
    os.environ["SSL_CERT_FILE"] = "/private/etc/ssl/cert.pem"

# api.kimi.com 国内直连；强制不走任何代理（launchd 下 urllib 会读取
# macOS 系统代理，经转发中继时 TLS 校验会失败）
_opener = build_opener(ProxyHandler({}))

PORT = 8899
BASE = "https://api.kimi.com/coding/v1"
CONFIG = Path.home() / ".hermes" / "config.yaml"
HTML_FILE = Path(__file__).parent / "index.html"
CACHE_TTL = 60  # 秒，避免频繁打 API

_cache = {"t": 0.0, "data": None, "error": None}


def read_key() -> str:
    # 优先环境变量，其次 Hermes 的 config.yaml
    env = os.environ.get("KIMI_API_KEY", "").strip()
    if env:
        return env
    txt = CONFIG.read_text(encoding="utf-8")
    m = re.search(r"name:\s*kimi-coding.*?api_key:\s*(\S+)", txt, re.S)
    if not m:
        raise RuntimeError("找不到 API key：请设 KIMI_API_KEY 环境变量，或在 config.yaml 里配置 kimi-coding provider")
    return m.group(1)


def fetch_usage():
    """返回 (data, fetched_at, error)。出错时若有旧数据则回退旧数据。"""
    now = time.time()
    if _cache["data"] is not None and now - _cache["t"] < CACHE_TTL:
        return _cache["data"], _cache["t"], None
    try:
        req = Request(
            BASE + "/usages",
            headers={"Authorization": "Bearer " + read_key()},
        )
        with _opener.open(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
        _cache.update(t=now, data=data, error=None)
        return data, now, None
    except Exception as e:
        _cache["error"] = str(e)
        return _cache["data"], _cache["t"], str(e)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/usage"):
            data, fetched_at, error = fetch_usage()
            payload = {
                "ok": data is not None,
                "data": data,
                "fetched_at": fetched_at,
                "error": error,
                "stale": error is not None and data is not None,
            }
            self._send(200, json.dumps(payload).encode(), "application/json; charset=utf-8")
        elif self.path in ("/", "/index.html"):
            self._send(200, HTML_FILE.read_bytes(), "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, *args):  # 静音访问日志
        pass


def main():
    import sys
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    url = f"http://127.0.0.1:{PORT}"
    print(f"K3 用量监控已启动: {url}")
    print("关闭此窗口即停止监控。")
    if "--no-open" not in sys.argv:  # launchd 开机自启时不弹浏览器
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
