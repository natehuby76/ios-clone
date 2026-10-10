import SwiftUI
import WebKit

@MainActor
final class GalaxyPageDiagnostics: ObservableObject {
    @Published var copied = false
    @Published var stalled = false
    @Published var mounted = false
    @Published var reloadID = UUID()
    private(set) var started = Date()
    private(set) var events: [String] = []
    private var deadline: Task<Void, Never>?

    func record(_ event: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(event.prefix(300))")
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }
    func begin() {
        deadline?.cancel()
        started = Date(); mounted = false; stalled = false
        record("Page loading")
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, !self.mounted else { return }
            self.record("No rendered Galaxy content after 12 seconds")
            self.stalled = true
        }
    }
    func rendered() {
        mounted = true; stalled = false; deadline?.cancel()
        record("Galaxy content rendered")
    }
    func fail(_ event: String) { record(event); stalled = true; deadline?.cancel() }
    func retry() { reloadID = UUID() }
    func report(server: LoopbackServer, connection: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot Galaxy diagnostics
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        iOS: \(UIDevice.current.systemVersion)
        Connection: \(connection)
        Galaxy content rendered: \(mounted)
        Page age: \(Int(Date().timeIntervalSince(started))) seconds
        \(server.diagnosticSummary)
        Recent page events:
        \(events.joined(separator: "\n"))
        Recent local requests (no headers, query values or bodies):
        \(server.recentRequests.joined(separator: "\n"))
        """
    }
}

struct GalaxyWebView: View {
    let url: URL
    let requestKey: String
    @ObservedObject var diagnostics: GalaxyPageDiagnostics
    let report: () -> String
    var body: some View {
        ZStack {
            GalaxyPage(url: url, requestKey: requestKey, diagnostics: diagnostics)
                .id(diagnostics.reloadID)
            if diagnostics.stalled {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.bubble").font(.largeTitle).foregroundStyle(.purple)
                    Text("Galaxy hasn’t loaded").font(.title2.bold())
                    Text("Copy the report so we can find what failed, or try loading the page again.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(diagnostics.copied ? "Report copied" : "Copy error report") {
                        UIPasteboard.general.string = report(); diagnostics.copied = true
                    }.buttonStyle(.borderedProminent).tint(.purple)
                    Button("Retry Galaxy") { diagnostics.copied = false; diagnostics.retry() }.buttonStyle(.bordered)
                }.padding(28).frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(20)
            }
        }
    }
}

private struct GalaxyPage: UIViewRepresentable {
    let url: URL
    let requestKey: String

    let diagnostics: GalaxyPageDiagnostics
    func makeCoordinator() -> Coordinator { Coordinator(origin: url, diagnostics: diagnostics) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        diagnostics.begin()
        config.userContentController.add(context.coordinator, name: "galaxyDiagnostics")
        let script = """
        (() => {
          if (location.origin !== '\(url.scheme!)://\(url.host!):\(url.port!)') return;
          window.__galaxyNative = true;
          const emit = (kind, path = '', code = 0) => {
            try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind, path, code}); } catch (_) {}
          };
          const pathOnly = value => {
            try { return new URL(value, location.href).pathname; } catch (_) { return ''; }
          };
          window.addEventListener('error', event => {
            if (event.target && event.target !== window) {
              emit('resource', pathOnly(event.target.src || event.target.href || ''));
            } else { emit('script', pathOnly(event.filename || ''), event.lineno || 0); }
          }, true);
          window.addEventListener('unhandledrejection', () => emit('promise'));
          let rendered = false;
          const checkContent = () => {
            const root = document.querySelector('#galaxy-app');
            if (root && !root.hasAttribute('v-cloak') && root.children.length && root.innerText.trim().length) {
              if (!rendered) { rendered = true; emit('rendered'); }
            } else if (rendered) { rendered = false; emit('blank'); }
          };
          window.addEventListener('DOMContentLoaded', () => {
            checkContent(); setInterval(checkContent, 1000);
          }, {once: true});
          const key = '\(requestKey)';
          const local = (u) => new URL(u, location.href).origin === location.origin;
          const originalFetch = window.fetch.bind(window);
          window.fetch = (input, init = {}) => {
            const req = new Request(input, init);
            if (!local(req.url)) return originalFetch(req);
            const headers = new Headers(req.headers);
            headers.set('X-Galaxy-Local', key);
            return originalFetch(new Request(req, { headers }));
          };
          const originalOpen = XMLHttpRequest.prototype.open;
          const originalSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__galaxyLocal = local(url);
            return originalOpen.call(this, method, url, ...rest);
          };
          XMLHttpRequest.prototype.send = function(body) {
            if (this.__galaxyLocal) this.setRequestHeader('X-Galaxy-Local', key);
            return originalSend.call(this, body);
          };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.06, green: 0.05, blue: 0.09, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "galaxyDiagnostics")
        uiView.navigationDelegate = nil; uiView.uiDelegate = nil
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let origin: URL
        let diagnostics: GalaxyPageDiagnostics
        init(origin: URL, diagnostics: GalaxyPageDiagnostics) { self.origin = origin; self.diagnostics = diagnostics }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let frame = message.frameInfo.securityOrigin
            guard frame.protocol == origin.scheme, frame.host == origin.host, frame.port == origin.port,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            let path = LoopbackServer.reportPath(body["path"] as? String ?? "")
            switch kind {
            case "rendered": if message.frameInfo.isMainFrame { diagnostics.rendered() }
            case "blank": if message.frameInfo.isMainFrame { diagnostics.begin() }
            case "resource": diagnostics.record("Resource failed: \(path)")
            case "script": diagnostics.record("JavaScript error: \(path), line \(body["code"] as? Int ?? 0)")
            case "promise": diagnostics.record("Unhandled JavaScript promise rejection")
            default: break
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            diagnostics.record("HTML navigation finished; waiting for Galaxy content")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        private func navigationFailed(_ error: Error) {
            let value = error as NSError
            diagnostics.fail("Navigation failed: \(value.domain) \(value.code)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { diagnostics.fail("Galaxy web content process terminated") }


        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port {
                decisionHandler(.allow)
            } else if url.scheme == "about" || url.scheme == "blob" {
                decisionHandler(.allow)
            } else {
                if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url, ["https", "http"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
