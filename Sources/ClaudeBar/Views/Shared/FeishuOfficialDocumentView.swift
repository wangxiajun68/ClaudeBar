import SwiftUI
import WebKit

/// Official cloud document reader; local Markdown drafts keep their native editor.
struct FeishuOfficialDocumentView: View {
    let document: FeishuDocument
    var onUnavailable: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var failure: String?
    @State private var mounted = false
    @State private var retry = UUID()

    var body: some View {
        ZStack {
            if !BuildChannel.allowsSystemIntegration {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.image").font(.system(size: 28)).foregroundStyle(Theme.Ink.claude)
                    Text("飞书官方文档视图").font(Theme.Font.section)
                    Text("开发版保持离线预览；正式版通过飞书授权加载原版排版、图片和表格。")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
            } else if let url = document.webURL {
                FeishuComponentWebView(documentURL: url, dark: colorScheme == .dark,
                                       onMounted: { mounted = true; self.failure = nil },
                                       onFailure: { self.failure = $0; onUnavailable($0) })
                    .id(document.id + retry.uuidString + (colorScheme == .dark ? "dark" : "light"))
                if let failure {
                    VStack(spacing: 12) {
                        Text("飞书文档暂时无法加载").font(Theme.Font.section)
                        Text(failure)
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            ActionButton("重试", symbol: "arrow.clockwise") {
                                self.failure = nil; mounted = false; retry = UUID()
                            }
                            Link("在飞书中打开", destination: url)
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bgPrimary)
                } else if !mounted {
                    ProgressView("正在加载飞书文档…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bgPrimary)
                }
            } else {
                Text("文档缺少有效的飞书链接，请刷新文档列表。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: document.id) { _, _ in mounted = false; self.failure = nil }
        .onChange(of: colorScheme) { _, _ in mounted = false; self.failure = nil }
    }
}

private struct FeishuComponentWebView: NSViewRepresentable {
    let documentURL: URL
    let dark: Bool
    let onMounted: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "feishuComponent")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.begin(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "feishuComponent")
        nsView.navigationDelegate = nil; nsView.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let parent: FeishuComponentWebView
        private let host = FeishuComponentHost()
        private weak var webView: WKWebView?
        private var pageURL: URL?
        private var startup: Task<Void, Never>?
        private var authentication: Task<Void, Never>?
        private var deadline: Task<Void, Never>?
        private var authAttempts = 0
        private var authFailure = "飞书组件鉴权失败，请检查自建应用的云文档组件权限。"
        private var stopped = false
        init(_ parent: FeishuComponentWebView) { self.parent = parent }

        func begin(_ webView: WKWebView) {
            self.webView = webView
            startup = Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await host.start()
                    try Task.checkCancellation()
                    pageURL = url
                    webView.load(URLRequest(url: url))
                } catch is CancellationError {} catch { fail(error.localizedDescription) }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)); self?.fail("飞书文档加载超过 120 秒，请重试。") } catch {}
            }
        }

        func stop() {
            stopped = true
            startup?.cancel(); authentication?.cancel(); deadline?.cancel()
            host.stop()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the exact local top frame can request a signature. The
            // remote document iframe, arbitrary links and stale hosts cannot.
            guard !stopped, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == pageURL,
                  message.webView === webView, let payload = message.body as? [String: String],
                  let event = payload["event"] else { return }
            let code = payload["code"] ?? ""
            let suffix = code.range(of: #"^-?\d{1,10}$"#, options: .regularExpression) != nil ? "（错误码 \(code)）" : ""
            switch event {
            case "ready": authenticate()
            case "authError":
                authFailure = "飞书组件鉴权失败" + suffix + "，请检查自建应用的云文档组件权限。"
                authenticate()
            case "mounted": authAttempts = 0; deadline?.cancel(); parent.onMounted()
            case "error": fail("飞书文档组件加载失败" + suffix + "。")
            case "timeout": fail("飞书文档组件加载超时。")
            default: break
            }
        }

        private func authenticate() {
            guard !stopped, let pageURL, authentication == nil else { return }
            guard authAttempts < 2 else { fail(authFailure); return }
            authAttempts += 1
            authentication = Task { [weak self] in
                guard let self else { return }
                defer { authentication = nil }
                do {
                    let auth = try await FeishuComponentAuthentication.signature(for: pageURL)
                    try Task.checkCancellation()
                    guard !stopped, webView?.url == pageURL else { return }
                    _ = try await webView?.callAsyncJavaScript("await window.mountDocument(auth, src, theme)",
                        arguments: ["auth": auth.arguments, "src": parent.documentURL.absoluteString,
                                    "theme": parent.dark ? "dark" : "light"], in: nil, contentWorld: .page)
                } catch is CancellationError {} catch {
                    fail((error as? FeishuCLIError)?.localizedDescription ?? "飞书组件初始化失败，请重试。")
                }
            }
        }

        private func fail(_ reason: String) { if !stopped { deadline?.cancel(); parent.onFailure(reason) } }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("飞书文档网页加载失败（错误码 \((error as NSError).code)），请检查网络后重试。") }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("飞书文档网页加载失败（错误码 \((error as NSError).code)），请检查网络后重试。") }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("飞书文档网页进程已退出，请重试。") }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame == true {
                if url == pageURL { decisionHandler(.allow); return }
                if navigationAction.navigationType == .linkActivated { open(url) }
                decisionHandler(.cancel)
            } else {
                if navigationAction.navigationType == .linkActivated { open(url); decisionHandler(.cancel) }
                else { decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel) }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { open(url) }
            return nil
        }

        private func open(_ url: URL) {
            guard BuildChannel.allowsSystemIntegration, url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
