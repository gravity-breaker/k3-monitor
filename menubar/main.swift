import Cocoa
import WebKit

// K3 余量 · macOS 菜单栏监控
// 数据源: https://api.kimi.com/coding/v1/usages (Bearer = ~/.hermes/config.yaml 里的 kimi-coding key)

let CONFIG_PATH = NSHomeDirectory() + "/.hermes/config.yaml"
let USAGE_URL = "https://api.kimi.com/coding/v1/usages"
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/k3monitorbar.log"

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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var refreshTimer: Timer?
    var lastJSON: String = ""
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
        }
    }

    func fetch() {
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
