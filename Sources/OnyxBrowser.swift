import AppKit
import WebKit

// MARK: - Onyx's own browser for academy sign-up: a web view that stays signed in to TeachMore on its own, in the
// background, so Chrome doesn't need to be open. It keeps its own cookies, apart from your browsers. When TeachMore
// signs you out, it signs back in with Google, typing your saved email and password only on Google's own sign-in page.

@MainActor final class OnyxBrowser: NSObject, SchoolPage, WKNavigationDelegate, WKUIDelegate {
    static let shared = OnyxBrowser(test: false)
    let web: WKWebView
    /// Google's sign-in page, the only place Onyx types your email and password (the self-test points it at its stand-in).
    var googleOrigin = "https://accounts.google.com", googlePath = "/"
    /// Your saved password, only while a sign-in is under way (cleared once typed, so a wrong one is never typed twice).
    var password = ""
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var window: NSWindow?

    init(test: Bool) {
        let c = WKWebViewConfiguration()
        // Its own cookies, kept on disk so it stays signed in (the self-test's are thrown away).
        c.websiteDataStore = test ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F6E7978-5343-484F-4F4C-000000000001")!)
        // It's Safari's engine, and it says so, so Google's sign-in accepts it.
        c.applicationNameForUserAgent = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: c)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    /// Loads a page and waits until it has finished (20 seconds at most).
    func load(_ url: URL) async {
        web.load(URLRequest(url: url))
        await withCheckedContinuation { c in
            waiting.append(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finished() }
        }
    }
    private func finished() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { finished() }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished() }
    /// A page that opens a new window opens it here instead.
    func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { w.load(URLRequest(url: u)) }
        return nil
    }

    func isGoogle(_ u: URL) -> Bool {
        guard let g = URL(string: googleOrigin) else { return false }
        return u.scheme == g.scheme && u.host == g.host && u.port == g.port && u.path.hasPrefix(googlePath)
    }

    // MARK: SchoolPage

    func run(_ start: String, poll: String, openURL: String) async -> SchoolPageResult {
        // Not on TeachMore (just started, or left on Google's sign-in): go there first.
        if let want = URL(string: openURL), !openURL.isEmpty, web.url.map({ $0.host != want.host || $0.port != want.port || isGoogle($0) }) ?? true {
            await load(want)
        }
        guard web.url != nil else { return .noTab }
        guard (try? await web.evaluateJavaScript(start)) is String else { return .failed("The page didn't run the script.") }
        for _ in 0..<80 {
            if let r = try? await web.evaluateJavaScript(poll) as? String, !r.isEmpty { return .value(r) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .failed("TeachMore didn't answer in time.")
    }

    func navigate(_ url: String) async -> SchoolPageResult {
        guard let u = URL(string: url) else { return .failed("Bad link") }
        await load(u)
        return .value("ONYX_DONE")
    }

    func signInStep(_ email: String) async -> SignInStep {
        guard let u = web.url else { return .gone }
        if isGoogle(u) {
            if web.isLoading { return .google("loading") }
            let js = SchoolJS.signIn(email, password: password, origin: googleOrigin, path: googlePath)
            return .google((try? await web.evaluateJavaScript(js)) as? String ?? "none")
        }
        return .teachmore(url: u.absoluteString, loading: web.isLoading)
    }

    /// Shows the browser in a window: to sign in yourself (when Google wants a code from your phone, say), or just to look.
    func show(_ url: String?) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "TeachMore (Onyx's browser)"; w.isReleasedWhenClosed = false; w.contentView = web; w.center()
            window = w
        }
        if let url, let u = URL(string: url) { web.load(URLRequest(url: u)) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
