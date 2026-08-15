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

// ── Hermes 状态灯（红黄绿环，合并自 hermes-light 2026-08-15）──
// 圆环颜色编码 Hermes 后端状态：绿=全部空闲 黄呼吸=工作中 红闪=待确认 灰=后端未运行
// 信号源：hermes_cli.main serve 的 WS JSON-RPC session.active_list（2s 轮询）
enum LightState: String {
    case off = "未运行"
    case idle = "空闲"
    case working = "工作中"
    case waiting = "待确认"
}

struct SessionRow {
    let key: String
    let title: String
    let preview: String
    let status: String

    var displayName: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let p = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        return key
    }
    var statusCN: String {
        switch status {
        case "waiting": return "待确认"
        case "working": return "工作中"
        case "starting": return "启动中"
        default: return "空闲"
        }
    }
}

func ellipsize(_ s: String, maxWidth: Int) -> String {
    var w = 0, out = ""
    for ch in s {
        let cw = ch.isASCII ? 1 : 2
        if w + cw > maxWidth { return out + "…" }
        w += cw; out.append(ch)
    }
    return out
}

func shellOut(_ launch: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 发现 Hermes 桌面端后端：pid ← ps；token ← 进程 env；port ← lsof 监听口
func discoverBackend() -> (port: String, token: String)? {
    let ps = shellOut("/bin/ps", ["aux"])
    var pid: String?
    for line in ps.split(separator: "\n") {
        if line.contains("hermes_cli.main serve") && !line.contains("grep") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if cols.count > 1 { pid = String(cols[1]); break }
        }
    }
    guard let pid else { return nil }
    let env = shellOut("/bin/ps", ["eww", pid])
    var token: String?
    for field in env.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
        if field.hasPrefix("HERMES_DASHBOARD_SESSION_TOKEN=") {
            token = String(field.dropFirst("HERMES_DASHBOARD_SESSION_TOKEN=".count))
            break
        }
    }
    guard let token, !token.isEmpty else { return nil }
    let lsof = shellOut("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid])
    for line in lsof.split(separator: "\n") {
        guard line.contains("127.0.0.1:") else { continue }
        if let r = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
            return (String(line[r]).replacingOccurrences(of: "127.0.0.1:", with: ""), token)
        }
    }
    return nil
}

/// 一次 WS 轮询 session.active_list；失败回 nil
func pollOnce(port: String, token: String, completion: @escaping ([SessionRow]?) -> Void) {
    var comps = URLComponents(string: "ws://127.0.0.1:\(port)/api/ws")!
    comps.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let url = comps.url else { completion(nil); return }
    let conf = URLSessionConfiguration.ephemeral
    conf.connectionProxyDictionary = [:]
    let ws = URLSession(configuration: conf).webSocketTask(with: url)
    ws.resume()
    var done = false
    func finish(_ rows: [SessionRow]?) {
        if done { return }
        done = true
        ws.cancel()
        completion(rows)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
    let req = #"{"jsonrpc":"2.0","id":1,"method":"session.active_list","params":{}}"# + "\n"
    ws.send(.string(req)) { err in if err != nil { finish(nil) } }
    func receive() {
        ws.receive { result in
            switch result {
            case .failure:
                finish(nil)
            case .success(let msg):
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                for line in text.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let idv = obj["id"] as? Int, idv == 1,
                          let res = obj["result"] as? [String: Any],
                          let sessions = res["sessions"] as? [[String: Any]]
                    else { continue }
                    finish(sessions.map { s in
                        SessionRow(
                            key: String(s["session_key"] as? String ?? s["id"] as? String ?? ""),
                            title: String(s["title"] as? String ?? ""),
                            preview: String(s["preview"] as? String ?? ""),
                            status: String(s["status"] as? String ?? "idle"))
                    })
                    return
                }
                if !done { receive() }
            }
        }
    }
    receive()
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var refreshTimer: Timer?
    var animTimer: Timer?
    var lastJSON: String = ""
    var lastMonthlyJSON: String = ""
    var lastMonthlyFetch = Date.distantPast
    var pageReady = false
    // ── 状态灯 ──
    var lightState: LightState = .off { didSet { if oldValue != lightState {
        log("light -> \(lightState.rawValue)"); lastAlpha = -1; renderRing() } } }
    var hermesRows: [SessionRow] = []
    var backend: (port: String, token: String)?
    var lastHermesPoll = Date.distantPast
    var lastDiscover = Date.distantPast
    var hermesPollInFlight = false
    var phase: Double = 0
    var lastAlpha: CGFloat = -1
    var lastPct: Int = 0

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
        // 状态灯动画 + 2s 轮询节拍器
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickLight()
        }

        // 录制遥控：分布式通知 k3.rc.popover / k3.rc.close / k3.rc.menu
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(rcPopoverOpen),  name: NSNotification.Name("k3.rc.popover"), object: nil)
        dnc.addObserver(self, selector: #selector(rcPopoverClose), name: NSNotification.Name("k3.rc.close"),   object: nil)
        dnc.addObserver(self, selector: #selector(rcMenuOpen),     name: NSNotification.Name("k3.rc.menu"),    object: nil)
        dnc.addObserver(self, selector: #selector(rcRedFlash),     name: NSNotification.Name("k3.rc.redflash"), object: nil)

        // DEMO 模式（K3_DEMO=1 手动运行）：自动演示 弹窗 8s → 菜单 6s，供真实录屏用
        if ProcessInfo.processInfo.environment["K3_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.togglePopover()                           // 弹窗开
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                    self.popover.performClose(nil)             // 弹窗关
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.showContextMenu()                 // 菜单开
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                            NSApp.terminate(nil)               // 演示结束退出
                        }
                    }
                }
            }
        }

        // 睡眠唤醒后立即刷新
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        log("app started")
    }

    @objc func onWake() { fetch(); lastHermesPoll = .distantPast }

    // ── 状态灯节拍：动画 + 节流轮询 ──
    func tickLight() {
        phase += 0.1
        switch lightState {
        case .working:
            renderRing(alpha: 0.35 + 0.65 * CGFloat(0.5 - 0.5 * cos(2 * Double.pi * phase / 1.6)))
        case .waiting:
            renderRing(alpha: Int(phase * 2) % 2 == 0 ? 1.0 : 0.15)
        default:
            renderRing(alpha: 1.0)
        }
        if !hermesPollInFlight && Date().timeIntervalSince(lastHermesPoll) > 2 {
            hermesPollInFlight = true
            lastHermesPoll = Date()
            pollHermes()
        }
    }

    func pollHermes() {
        if backend == nil && Date().timeIntervalSince(lastDiscover) > 5 {
            lastDiscover = Date()
            backend = discoverBackend()
            if backend != nil { log("hermes backend port=\(backend!.port)") }
        }
        guard let b = backend else {
            DispatchQueue.main.async {
                self.lightState = .off; self.hermesRows = []; self.hermesPollInFlight = false
            }
            return
        }
        pollOnce(port: b.port, token: b.token) { [weak self] rows in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hermesPollInFlight = false
                guard let rows = rows else {
                    self.backend = nil   // 连接失败：下轮重新发现（后端重启换端口/token）
                    self.lightState = .off
                    self.hermesRows = []
                    return
                }
                self.hermesRows = rows
                if Date() < self.demoHoldUntil { return }   // 演示红闪期间不被轮询覆盖
                if rows.contains(where: { $0.status == "waiting" }) {
                    self.lightState = .waiting
                } else if rows.contains(where: { $0.status == "working" || $0.status == "starting" }) {
                    self.lightState = .working
                } else {
                    self.lightState = .idle
                }
            }
        }
    }

    // ── 圆环重绘：K3 剩余%弧线 + Hermes 状态颜色/呼吸/闪烁 ──
    func renderRing(alpha: CGFloat = 1.0) {
        if abs(alpha - lastAlpha) < 0.02 { return }
        lastAlpha = alpha
        guard let b = statusItem.button else { return }
        b.image = ringImage(pct: lastPct, alpha: alpha)
        b.imagePosition = .imageLeft
        b.title = " \(lastPct)%"
    }

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
        if event.type == .rightMouseUp { showContextMenu() } else { togglePopover() }
    }

    // ── 录制遥控：分布式通知驱动弹窗/菜单（供录屏脚本调用）──
    @objc func rcPopoverOpen()  { if !popover.isShown { togglePopover() } }
    @objc func rcPopoverClose() { if popover.isShown { popover.performClose(nil) } }
    @objc func rcMenuOpen()     { showContextMenu() }
    var demoHoldUntil = Date.distantPast
    @objc func rcRedFlash() {   // 演示红闪：强制 waiting 态 12 秒（真实渲染路径）
        demoHoldUntil = Date().addingTimeInterval(12)
        lightState = .waiting
    }

    func showContextMenu() {
        let menu = NSMenu()
        let head = NSMenuItem(title: "Hermes：\(lightState.rawValue)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
            if hermesRows.isEmpty {
                let it = NSMenuItem(title: lightState == .off ? "  后端未运行" : "  无活动会话",
                                    action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            } else {
                for r in hermesRows {
                    let mark = r.status == "waiting" ? "🔴" : (r.status == "working" || r.status == "starting") ? "🟡" : "🟢"
                    let it = NSMenuItem(
                        title: "\(mark) \(ellipsize(r.displayName, maxWidth: 30)) — \(r.statusCN)",
                        action: nil, keyEquivalent: "")
                    it.isEnabled = false
                    menu.addItem(it)
                }
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(manualRefresh), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "退出 K3 余量", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // 恢复左键弹窗
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

    // ── 菜单栏图标：剩余%圆环，颜色=Hermes 状态 ──
    func setMenuBar(remainingPct pct: Int) {
        lastPct = pct
        lastAlpha = -1
        renderRing()
    }

    func ringImage(pct: Int, alpha: CGFloat = 1.0) -> NSImage {
        let stateColor: NSColor
        switch lightState {
        case .idle:    stateColor = NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        case .working: stateColor = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        case .waiting: stateColor = NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        case .off:     stateColor = NSColor(calibratedRed: 0.61, green: 0.64, blue: 0.69, alpha: 1)
        }
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let c = NSPoint(x: 8, y: 8)
            let r: CGFloat = 5.5
            NSColor(white: 0.5, alpha: 0.3).setStroke()
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            track.stroke()
            stateColor.withAlphaComponent(alpha).setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(pct) / 100, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            arc.stroke()
            return true
        }
        img.isTemplate = false   // 彩色状态环
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
