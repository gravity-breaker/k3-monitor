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
WEB_BASE = "https://www.kimi.com"  # 订阅页（会员月度额度池）数据源
CONFIG = Path.home() / ".hermes" / "config.yaml"
HTML_FILE = Path(__file__).parent / "index.html"
CACHE_TTL = 60  # 秒，避免频繁打 API
MONTHLY_CACHE_TTL = 300  # 月度额度变化慢，5 分钟缓存

# 网页端登录态：access_token 30 天有效。App 日常使用时自行刷新并写回
# 它自己的 Local Storage(leveldb)，本服务只做读者；实在取不到新 token
# 才用 refresh_token 自助刷新（会轮转，App 侧靠 leveldb 回读自愈）。
TOKEN_FILE = Path(__file__).parent / ".kimi-web-token.json"
LEVELDB_DIR = Path.home() / "Library" / "Application Support" / "kimi-desktop" / "Local Storage" / "leveldb"

_cache = {"t": 0.0, "data": None, "error": None}
_monthly_cache = {"t": 0.0, "data": None, "error": None}


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


# ── 月度额度池（kimi.com 订阅页）────────────────────────────────────

def _jwt_exp(token: str) -> float:
    """解 JWT payload 拿 exp，失败返回 0。"""
    try:
        import base64
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return float(json.loads(base64.urlsafe_b64decode(payload)).get("exp", 0))
    except Exception:
        return 0.0


def _extract_tokens_from_leveldb():
    """从 Kimi 桌面端 Local Storage(leveldb) 里捞最新 access/refresh token。
    leveldb 的 .log/.ldb 里 JWT 是明文字符串；按有效期长短区分：
    access≈30 天，refresh≈90 天，各取 iat 最新的一枚。"""
    import base64
    import glob
    access, refresh = None, None  # (iat, token)
    pat = re.compile(rb"eyJhbGciOiJI[A-Za-z0-9_.\-]+")
    files = sorted(
        glob.glob(str(LEVELDB_DIR / "*.log")) + glob.glob(str(LEVELDB_DIR / "*.ldb")),
        key=os.path.getmtime, reverse=True,
    )
    for f in files:
        try:
            blob = open(f, "rb").read()
        except OSError:
            continue
        for m in pat.finditer(blob):
            tok = m.group(0).decode("ascii", "ignore")
            try:
                payload = tok.split(".")[1]
                payload += "=" * (-len(payload) % 4)
                claims = json.loads(base64.urlsafe_b64decode(payload))
                iat, exp = float(claims.get("iat", 0)), float(claims.get("exp", 0))
            except Exception:
                continue
            if exp < time.time():
                continue
            lifetime = exp - iat
            if lifetime <= 40 * 86400:  # access token
                if not access or iat > access[0]:
                    access = (iat, tok)
            else:  # refresh token
                if not refresh or iat > refresh[0]:
                    refresh = (iat, tok)
    if access and refresh:
        return {"access_token": access[1], "refresh_token": refresh[1]}
    return None


def _load_web_tokens():
    """优先 token 文件；没有/过期则从 App 的 leveldb 回读并落盘。"""
    tok = None
    if TOKEN_FILE.exists():
        try:
            tok = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        except Exception:
            tok = None
    if tok and _jwt_exp(tok.get("access_token", "")) > time.time() + 3600:
        return tok
    fresh = _extract_tokens_from_leveldb()
    if fresh:
        _save_web_tokens(fresh)
        return fresh
    return tok  # 可能已过期，让调用方走刷新/报错


def _save_web_tokens(tok: dict):
    try:
        TOKEN_FILE.write_text(json.dumps(tok), encoding="utf-8")
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass


def _refresh_web_tokens(tok: dict):
    """GET /api/auth/token/refresh（Bearer=refresh_token），成功则落盘新对。"""
    req = Request(
        WEB_BASE + "/api/auth/token/refresh",
        headers={"Authorization": "Bearer " + tok["refresh_token"]},
    )
    with _opener.open(req, timeout=15) as r:
        new = json.loads(r.read().decode("utf-8"))
    if not new.get("access_token") or not new.get("refresh_token"):
        raise RuntimeError("刷新响应缺字段")
    _save_web_tokens(new)
    return new


def _call_subscription_stats(tok: dict):
    req = Request(
        WEB_BASE + "/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats",
        data=b"{}",
        headers={
            "Authorization": "Bearer " + tok["access_token"],
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with _opener.open(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_monthly():
    """会员月度共享额度池。返回 (data, fetched_at, error)，结构已裁剪。"""
    now = time.time()
    if _monthly_cache["data"] is not None and now - _monthly_cache["t"] < MONTHLY_CACHE_TTL:
        return _monthly_cache["data"], _monthly_cache["t"], None
    try:
        tok = _load_web_tokens()
        if not tok:
            raise RuntimeError("找不到网页端登录态：请打开一次 Kimi 桌面端")
        try:
            raw = _call_subscription_stats(tok)
        except Exception as e1:
            # access 过期：先回读 App 的 leveldb（App 是主要刷新者），不行再自助刷新
            fresh = _extract_tokens_from_leveldb()
            if fresh and fresh.get("access_token") != tok.get("access_token"):
                _save_web_tokens(fresh)
                try:
                    raw = _call_subscription_stats(fresh)
                except Exception:
                    raw = _call_subscription_stats(_refresh_web_tokens(fresh))
            else:
                raw = _call_subscription_stats(_refresh_web_tokens(tok))
        bal = raw.get("subscriptionBalance") or {}
        gifts = raw.get("giftBalances") or []
        gift = gifts[0] if gifts else None
        data = {
            "used_ratio": bal.get("amountUsedRatio"),      # 月度池已用比例 0~1
            "code_ratio": bal.get("kimiCodeUsedRatio"),    # 其中 Kimi Code 占的比例
            "reset_at": bal.get("expireTime"),             # 月度池重置时间
            "gift": ({
                "used_ratio": gift.get("amountUsedRatio"),
                "expire": gift.get("expireTime"),
                "name": gift.get("displayName") or "赠送额度",
            } if gift else None),
            "notice": (raw.get("notice") or {}).get("content"),
        }
        _monthly_cache.update(t=now, data=data, error=None)
        return data, now, None
    except Exception as e:
        _monthly_cache["error"] = str(e)
        return _monthly_cache["data"], _monthly_cache["t"], str(e)


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
        elif self.path.startswith("/api/monthly"):
            data, fetched_at, error = fetch_monthly()
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
