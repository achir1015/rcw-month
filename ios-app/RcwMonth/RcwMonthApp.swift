import AVFoundation
import SwiftUI
import UIKit
import WebKit

/// 月班表管理系統 — iPhone／iPad 版
///
/// 把這個 App 想成一個「相框」：相框本身幾乎不用換，裡面的照片（網頁）放的是
/// GitHub Pages 上最新的月班表系統（https://achir1015.github.io/rcw-month/）。
/// 所以網頁更新後，App 下次開啟就自動是新版，不用重新安裝；
/// 只有相框本身（這個 Swift 程式）改了，才需要到安裝頁重新安裝。
///
/// 相框幫網頁補上 iPhone／iPad 的功能：
///   - 網頁的 alert／confirm 視窗（例如「確定要覆蓋？」）改用 iOS 原生對話框
///   - 匯出 XML 備份 → iOS 分享選單（儲存到檔案、AirDrop、LINE…）
///   - 語音說明在靜音開關打開時也能播放
///   - 外部連結（安裝頁、GitHub）用 Safari 開
@main
struct RcwMonthApp: App {
    init() {
        // 語音說明：靜音開關打開時也要有聲音，並且和其他 App 的聲音並存
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            WebContainer()
                .background(Color(red: 0.957, green: 0.969, blue: 0.965)) // #F4F7F6，和網頁底色相同
        }
    }
}

struct WebContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { Web.shared.view }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

enum AppConfig {
    /// 系統網址（GitHub Pages）
    static let homeURL = URL(string: "https://achir1015.github.io/rcw-month/")!
    /// 允許在 App 內開啟的網域；其他網址一律交給 Safari
    static let inAppHosts: Set<String> = [
        "achir1015.github.io",
        // Firebase 登入與雲端資料庫
        "monthlyschedule-a5dea.firebaseapp.com", "identitytoolkit.googleapis.com",
        "securetoken.googleapis.com", "firestore.googleapis.com", "www.googleapis.com"
    ]
}

/// 網頁與 App 之間的橋：網頁呼叫 window.webkit.messageHandlers.rcw.postMessage({cmd, args})，回傳 Promise
final class Web: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    static let shared = Web()
    let view: WKWebView
    private var lastLoadedAt = Date()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default() // 登入狀態、上次選的單位等資料，每次開啟都還在

        // 讓網頁知道自己在 iPhone／iPad App 裡（index.html 會隱藏「安裝 App」、改用 App 的分享功能）
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let shim = WKUserScript(source: """
            window.RcwIOS = { version: '\(ver)', platform: '\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")' };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        cfg.userContentController.addUserScript(shim)

        view = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "rcw")
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.957, green: 0.969, blue: 0.965, alpha: 1)
        view.scrollView.backgroundColor = view.backgroundColor
        if #available(iOS 16.4, *) { view.isInspectable = true }

        // 往下拉可以重新整理
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh

        loadHome()

        // App 放在背景超過 6 小時再回來，就重新載入一次，確保拿到最新版網頁
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastLoadedAt) > 6 * 3600 { self.loadHome() }
        }
    }

    private func loadHome() {
        lastLoadedAt = Date()
        view.load(URLRequest(url: AppConfig.homeURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        lastLoadedAt = Date()
        view.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sender.endRefreshing() }
    }

    // MARK: 連結：系統網域在 App 內開，其他（例如安裝頁以外的網站）用 Safari
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, let scheme = u.scheme else { decisionHandler(.allow); return }
        if scheme == "itms-services" || ((scheme == "http" || scheme == "https") && a.targetFrame?.isMainFrame != false
            && (!AppConfig.inAppHosts.contains(u.host ?? "") || u.path.hasPrefix("/rcw-month/ios"))) {
            // 安裝頁（重新安裝新版 App）與外部網站，都交給 Safari
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { UIApplication.shared.open(u) }
        return nil
    }

    // 沒有網路或載入失敗：顯示說明與「重新載入」
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { showOffline(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { showOffline(e) }
    }
    private func showOffline(_ e: Error) {
        guard (e as NSError).code != NSURLErrorCancelled else { return }
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:18px -apple-system,'PingFang TC',sans-serif;background:#F4F7F6;color:#1E2A28;display:flex;align-items:center;justify-content:center;min-height:90vh;text-align:center;padding:20px}
        button{font:inherit;font-weight:700;padding:12px 28px;border:0;border-radius:8px;background:#1F6F63;color:#fff;margin-top:16px}</style></head>
        <body><div><h2>無法連線到月班表系統</h2><p>月班表的資料存在雲端，需要網路才能使用。<br>請確認 Wi-Fi 或行動網路後再試一次。</p>
        <button onclick="location.href='\(AppConfig.homeURL.absoluteString)'">重新載入</button></div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    // 網頁被系統回收時（記憶體不足）自動重新載入
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // MARK: 網頁的 alert／confirm／prompt → iOS 原生對話框（WKWebView 預設不會顯示）
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "確定", style: .default) { _ in completionHandler() })
        present(ac) { completionHandler() }
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        ac.addAction(UIAlertAction(title: "確定", style: .default) { _ in completionHandler(true) })
        present(ac) { completionHandler(false) }
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let ac = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        ac.addTextField { $0.text = defaultText }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        ac.addAction(UIAlertAction(title: "確定", style: .default) { _ in completionHandler(ac.textFields?.first?.text) })
        present(ac) { completionHandler(nil) }
    }

    // MARK: 網頁呼叫的功能
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = m.body as? [String: Any], let cmd = body["cmd"] as? String else { replyHandler(nil, "bad message"); return }
        let args = body["args"] as? [String: Any] ?? [:]
        switch cmd {
        case "app_info":
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            replyHandler(["status": "ok", "name": "月班表", "version": ver, "platform": "ios", "model": UIDevice.current.model], nil)
        case "save_file":
            // 匯出 XML 備份：寫到暫存檔，再打開分享選單（儲存到檔案、AirDrop、LINE、郵件…）
            let raw = (args["name"] as? String) ?? "月班表備份.xml"
            let name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let text = (args["text"] as? String) ?? ""
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            do {
                try text.data(using: .utf8)?.write(to: url, options: .atomic)
            } catch {
                replyHandler(["status": "error", "message": "無法建立檔案"], nil); return
            }
            share(url) { done in replyHandler(["status": done ? "ok" : "declined", "name": name], nil) }
        case "open_url":
            if let s = args["url"] as? String, let url = URL(string: s), url.scheme == "https" || url.scheme == "itms-services" {
                UIApplication.shared.open(url)
            }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown command \(cmd)")
        }
    }

    private func share(_ url: URL, done: @escaping (Bool) -> Void) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        if let p = vc.popoverPresentationController {   // iPad：從畫面中央彈出
            p.sourceView = view
            p.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            p.permittedArrowDirections = []
        }
        present(vc) { done(false) }
    }

    private func present(_ vc: UIViewController, fail: () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = top?.presentedViewController { top = p }
        if let top { top.present(vc, animated: true) } else { fail() }
    }
}
