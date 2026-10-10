import AppKit
import WebKit

/// Owns the transparent WKWebView and the bundled markdown pipeline
/// (notes.html + markdown-it + highlight.js, fully offline). Content is
/// pushed via callAsyncJavaScript behind a pageReady gate; external links
/// open in the default browser.
@MainActor
final class MarkdownRenderer: NSObject, WKNavigationDelegate {
    let webView: NotesWebView

    private var pageReady = false
    private var pendingMarkdown: String?
    private var lastRendered: String?
    private var theme = "white"

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // Code-block copy buttons post here; NSPasteboard is dependable where
        // navigator.clipboard on file:// is not.
        config.userContentController.add(CopyMessageHandler(), name: "copy")
        webView = NotesWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        // Transparency needs BOTH switches on macOS: the documented
        // underPageBackgroundColor and the long-stable private KVC.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // Hidden until didFinish → a WebKit regression degrades to an opaque
        // overlay instead of a white flash.
        webView.alphaValue = 0

        loadPage()
    }

    private func loadPage() {
        // Custom web resources are embedded in the executable by the build tool.
        webView.loadHTMLString(WebAssets.html, baseURL: nil)
    }

    /// Reset to the not-yet-loaded state, parking current content in the
    /// pending slots so didFinish replays it after the reload.
    private func resetForReload() {
        pageReady = false
        pendingMarkdown = lastRendered ?? pendingMarkdown
        pendingWarning = lastWarning ?? pendingWarning
        lastRendered = nil
        lastWarning = nil
        webView.alphaValue = 0
    }

    func render(markdown: String) {
        guard pageReady else {
            pendingMarkdown = markdown
            return
        }
        guard markdown != lastRendered else { return }
        lastRendered = markdown
        webView.callAsyncJavaScript("return renderMarkdown(md);",
                                    arguments: ["md": markdown],
                                    in: nil, in: .page) { [weak self] result in
            // A failed call (e.g. mid-reload) must not suppress the retry of
            // identical content via the dedup check.
            if case .failure = result { self?.lastRendered = nil }
        }
    }

    func setTheme(_ theme: String) {
        self.theme = theme
        guard pageReady else { return }
        webView.callAsyncJavaScript("document.body.className = theme;",
                                    arguments: ["theme": theme],
                                    in: nil, in: .page) { _ in }
    }

    private var lastWarning: Bool?
    private var pendingWarning: Bool?

    /// Red "your notes are on the beamer" banner while OS mirroring is active.
    func setMirrorWarning(_ visible: Bool) {
        guard pageReady else {
            pendingWarning = visible
            return
        }
        guard visible != lastWarning else { return }
        lastWarning = visible
        webView.callAsyncJavaScript("return setMirrorWarning(on);",
                                    arguments: ["on": visible],
                                    in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.lastWarning = nil }
        }
    }

    // MARK: - WKNavigationDelegate

    private final class CopyMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "copy", let text = message.body as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        setTheme(theme)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            webView.animator().alphaValue = 1
        }
        if let pending = pendingMarkdown {
            pendingMarkdown = nil
            render(markdown: pending)
        }
        if let warning = pendingWarning {
            pendingWarning = nil
            setMirrorWarning(warning)
        }
    }

    /// WebContent process crashed: reload and replay — without this the
    /// overlay would stay blank for the rest of the talk.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetForReload()
        loadPage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryLoad()
    }

    private func retryLoad() {
        resetForReload()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.loadPage()
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
