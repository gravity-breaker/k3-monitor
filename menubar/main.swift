import Cocoa
import WebKit

// K3 余量 · macOS 菜单栏监控
// 数据源: https://api.kimi.com/coding/v1/usages (Bearer = ~/.hermes/config.yaml 里的 kimi-coding key)

let CONFIG_PATH = NSHomeDirectory() + "/.hermes/config.yaml"
let USAGE_URL = "https://api.kimi.com/coding/v1/usages"
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/k3monitorbar.log"

// ── 月度额度池（kimi.com 订阅页 GetSubscriptionStats）──
// 登录态与网页版监控共用 ~/Applications/k3-monitor/.kimi-web-token.json；
// 读不到/过期时回读 Kimi 桌面端 Local Storage(leveldb)，末位才自助刷新。
let STATS_URL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
let REFRESH_URL = "https://www.kimi.com/api/auth/token/refresh"
let WEB_TOKEN_PATH = NSHomeDirectory() + "/Applications/k3-monitor/.kimi-web-token.json"
let LEVELDB_DIR = NSHomeDirectory() + "/Library/Application Support/kimi-desktop/Local Storage/leveldb"

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: LOG_PATH) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
    }
}

func readAPIKey() -> String? {
    // 优先环境变量，其次 Hermes 的 config.yaml
    if let env = ProcessInfo.processInfo.environment["KIMI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !env.isEmpty { return env }
    guard let txt = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else { return nil }
    let pat = #"name:\s*kimi-coding[\s\S]*?api_key:\s*(\S+)"#
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: txt, range: NSRange(txt.startIndex..., in: txt)),
          let r = Range(m.range(at: 1), in: txt) else { return nil }
    return String(txt[r])
}

// ── 网页端 token：文件优先，leveldb 回读，自助刷新兜底 ──
func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload += "=" }
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func jwtExp(_ token: String) -> Double {
    (jwtClaims(token)?["exp"] as? Double) ?? 0
}

/// 从 Kimi 桌面端 leveldb 扫 JWT：access≈30 天、refresh≈90 天，各取 iat 最新
func extractTokensFromLeveldb() -> [String: String]? {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: LEVELDB_DIR) else { return nil }
    let paths = files.filter { $0.hasSuffix(".log") || $0.hasSuffix(".ldb") }
        .map { LEVELDB_DIR + "/" + $0 }
        .sorted { (a, b) in
            let ma = (try? FileManager.default.attributesOfItem(atPath: a))?[.modificationDate] as? Date ?? .distantPast
            let mb = (try? FileManager.default.attributesOfItem(atPath: b))?[.modificationDate] as? Date ?? .distantPast
            return ma > mb
        }
    guard let re = try? NSRegularExpression(pattern: #"eyJhbGciOiJI[A-Za-z0-9_.\-]+"#) else { return nil }
    var bestAccess: (Double, String)?; var bestRefresh: (Double, String)?
    let now = Date().timeIntervalSince1970
    for p in paths {
        guard let blob = try? String(contentsOfFile: p, encoding: .isoLatin1) else { continue }
        let ns = blob as NSString
        for m in re.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            guard let c = jwtClaims(tok),
                  let iat = c["iat"] as? Double, let exp = c["exp"] as? Double,
                  exp > now else { continue }
            if exp - iat <= 40 * 86400 {
                if bestAccess == nil || iat > bestAccess!.0 { bestAccess = (iat, tok) }
            } else {
                if bestRefresh == nil || iat > bestRefresh!.0 { bestRefresh = (iat, tok) }
            }
        }
    }
    guard let a = bestAccess, let r = bestRefresh else { return nil }
    return ["access_token": a.1, "refresh_token": r.1]
}

func saveWebTokens(_ tok: [String: String]) {
    if let data = try? JSONSerialization.data(withJSONObject: tok) {
        try? data.write(to: URL(fileURLWithPath: WEB_TOKEN_PATH))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: WEB_TOKEN_PATH)
    }
}

func loadWebTokens() -> [String: String]? {
    var tok: [String: String]? = nil
    if let data = try? Data(contentsOf: URL(fileURLWithPath: WEB_TOKEN_PATH)),
       let j = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        tok = j
    }
    if let t = tok, let acc = t["access_token"], jwtExp(acc) > Date().timeIntervalSince1970 + 3600 {
        return t
    }
    if let fresh = extractTokensFromLeveldb() {
        saveWebTokens(fresh)
        return fresh
    }
    return tok
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var refreshTimer: Timer?
    var lastJSON: String = ""
    var lastMonthlyJSON: String = ""
    var lastMonthlyFetch = Date.distantPast
    var pageReady = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.title = " K3"
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)   // 浅色弹窗配蓝天白云主题
        popover.contentSize = NSSize(width: 384, height: 480)
        let vc = NSViewController()
        // 磨砂玻璃：NSVisualEffectView 垫底，WebView 透明，让系统级背景模糊透出来
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 384, height: 480))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        webView = WKWebView(frame: fx.bounds)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        fx.addSubview(webView)
        vc.view = fx
        popover.contentViewController = vc
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        fetch()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        // 睡眠唤醒后立即刷新
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        log("app started")
    }

    @objc func onWake() { fetch() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        if !lastJSON.isEmpty { push(lastJSON) }
        if !lastMonthlyJSON.isEmpty { pushMonthly(lastMonthlyJSON) }
        fitHeight()
    }

    /// 弹窗高度贴合内容，不留底部黑边
    func fitHeight() {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] r, _ in
            guard let self = self, let n = r as? NSNumber else { return }
            let h = CGFloat(truncating: n)
            if h > 100, abs(self.popover.contentSize.height - h) > 2 {
                self.popover.contentSize = NSSize(width: 384, height: h)
            }
        }
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(manualRefresh), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "退出 K3 余量", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // 恢复左键弹窗
        } else {
            togglePopover()
        }
    }

    @objc func manualRefresh() { fetch() }
    @objc func quitApp() { NSApp.terminate(nil) }

    func togglePopover() {
        guard let b = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if pageReady, !lastJSON.isEmpty { push(lastJSON) }
            if pageReady, !lastMonthlyJSON.isEmpty { pushMonthly(lastMonthlyJSON) }
        }
    }

    func fetch() {
        if Date().timeIntervalSince(lastMonthlyFetch) > 300 { fetchMonthly() }
        guard let key = readAPIKey() else {
            log("ERROR: 读不到 kimi-coding api_key")
            pushError("读不到 ~/.hermes/config.yaml 里的 kimi-coding key")
            return
        }
        var req = URLRequest(url: URL(string: USAGE_URL)!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let conf = URLSessionConfiguration.ephemeral
        conf.connectionProxyDictionary = [:]   // api.kimi.com 国内直连
        URLSession(configuration: conf).dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let err = err {
                    log("ERROR: \(err.localizedDescription)")
                    self.pushError(err.localizedDescription)
                    return
                }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    log("ERROR: 响应解析失败")
                    self.pushError("响应解析失败")
                    return
                }
                if let usage = obj["usage"] as? [String: Any],
                   let limit = Double(usage["limit"] as? String ?? ""),
                   let rem = Double(usage["remaining"] as? String ?? ""), limit > 0 {
                    let pct = Int((rem / limit * 100).rounded())
                    self.setMenuBar(remainingPct: pct)
                    log("OK remaining=\(Int(rem))/\(Int(limit)) (\(pct)%)")
                }
                if let json = String(data: data, encoding: .utf8) {
                    self.lastJSON = json
                    self.push(json)
                }
            }
        }.resume()
    }

    func push(_ json: String) {
        guard pageReady else { return }
        webView.evaluateJavaScript("window.updateData && window.updateData(\(json))") { [weak self] _, e in
            if let e = e { log("JS error: \(e.localizedDescription)") }
            self?.fitHeight()
        }
    }

    func pushError(_ msg: String) {
        guard pageReady,
              let data = try? JSONEncoder().encode([msg]),
              let arr = String(data: data, encoding: .utf8) else { return }
        let inner = String(arr.dropFirst().dropLast())
        webView.evaluateJavaScript("window.showError && window.showError(\(inner))", completionHandler: nil)
    }

    // ── 月度额度池 ──
    func fetchMonthly() {
        lastMonthlyFetch = Date()
        guard let tok = loadWebTokens(), let acc = tok["access_token"] else {
            log("monthly ERROR: 找不到网页端登录态")
            return
        }
        callStats(access: acc) { [weak self] status, obj in
            guard let self = self else { return }
            if status == 200, let obj = obj {
                self.handleMonthly(obj)
                return
            }
            // 401/失败：先回读 App leveldb（App 是主刷新者），不行再自助刷新
            let fresh = self.extractAndCompare(current: acc)
            if let fresh = fresh {
                self.callStats(access: fresh["access_token"]!) { st2, obj2 in
                    if st2 == 200, let obj2 = obj2 { self.handleMonthly(obj2) }
                    else { self.refreshAndRetry(tok: fresh) }
                }
            } else {
                self.refreshAndRetry(tok: tok)
            }
        }
    }

    func extractAndCompare(current acc: String) -> [String: String]? {
        guard let fresh = extractTokensFromLeveldb(),
              fresh["access_token"] != acc else { return nil }
        saveWebTokens(fresh)
        return fresh
    }

    func refreshAndRetry(tok: [String: String]) {
        guard let rt = tok["refresh_token"] else {
            log("monthly ERROR: 无 refresh_token")
            return
        }
        var req = URLRequest(url: URL(string: REFRESH_URL)!)
        req.setValue("Bearer \(rt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let conf = URLSessionConfiguration.ephemeral
        conf.connectionProxyDictionary = [:]
        URLSession(configuration: conf).dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let acc = j["access_token"], j["refresh_token"] != nil else {
                log("monthly ERROR: token 刷新失败 \(err?.localizedDescription ?? "")")
                return
            }
            saveWebTokens(j)
            log("monthly: token 自助刷新成功")
            self.callStats(access: acc) { st, obj in
                if st == 200, let obj = obj { self.handleMonthly(obj) }
                else { log("monthly ERROR: 刷新后仍 \(st)") }
            }
        }.resume()
    }

    func callStats(access: String, completion: @escaping (Int, [String: Any]?) -> Void) {
        var req = URLRequest(url: URL(string: STATS_URL)!)
        req.httpMethod = "POST"
        req.httpBody = "{}".data(using: .utf8)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let conf = URLSessionConfiguration.ephemeral
        conf.connectionProxyDictionary = [:]   // kimi.com 国内直连
        URLSession(configuration: conf).dataTask(with: req) { data, resp, err in
            let st = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let data = data, err == nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(st == 0 ? -1 : st, nil) }
                return
            }
            DispatchQueue.main.async { completion(st, obj) }
        }.resume()
    }

    func handleMonthly(_ raw: [String: Any]) {
        let bal = raw["subscriptionBalance"] as? [String: Any] ?? [:]
        var out: [String: Any] = [
            "used_ratio": bal["amountUsedRatio"] ?? 0,
            "code_ratio": bal["kimiCodeUsedRatio"] ?? 0,
            "reset_at": bal["expireTime"] ?? "",
        ]
        if let gifts = raw["giftBalances"] as? [[String: Any]], let g = gifts.first {
            out["gift"] = [
                "used_ratio": g["amountUsedRatio"] ?? 0,
                "expire": g["expireTime"] ?? "",
            ]
        }
        if let notice = (raw["notice"] as? [String: Any])?["content"] as? String {
            out["notice"] = notice
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let json = String(data: data, encoding: .utf8) else { return }
        let used = ((bal["amountUsedRatio"] as? Double) ?? 0) * 100
        log(String(format: "monthly OK used=%.1f%%", used))
        DispatchQueue.main.async {
            self.lastMonthlyJSON = json
            self.pushMonthly(json)
        }
    }

    func pushMonthly(_ json: String) {
        guard pageReady else { return }
        webView.evaluateJavaScript("window.updateMonthly && window.updateMonthly(\(json))") { [weak self] _, e in
            if let e = e { log("monthly JS error: \(e.localizedDescription)") }
            self?.fitHeight()
        }
    }

    // ── 菜单栏图标：剩余%圆环 + 数字 ──
    func setMenuBar(remainingPct pct: Int) {
        guard let b = statusItem.button else { return }
        b.image = ringImage(pct: pct)
        b.imagePosition = .imageLeft
        b.title = " \(pct)%"
    }

    func ringImage(pct: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let c = NSPoint(x: 8, y: 8)
            let r: CGFloat = 5.5
            NSColor(white: 0.0, alpha: 0.25).setStroke()
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            track.stroke()
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(pct) / 100, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            arc.stroke()
            return true
        }
        img.isTemplate = true   // 自动适配深/浅色菜单栏
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
