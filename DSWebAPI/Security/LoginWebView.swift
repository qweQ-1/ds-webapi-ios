import SwiftUI
import WebKit

/// App 内嵌的 DeepSeek 网页登录页：登录成功后自动把 access token / cookie 抠出来。
struct LoginWebView: UIViewRepresentable {
    var onToken: (String) -> Void
    var onCookie: (String) -> Void
    var onStatus: (String) -> Void

    static let startURL = URL(string: "https://chat.deepseek.com/")!

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        context.coordinator.webView = webView
        webView.load(URLRequest(url: Self.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var parent: LoginWebView
        weak var webView: WKWebView?
        private var timer: Timer?
        private var didCaptureToken = false

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onStatus("网页已加载，登录后会自动抓取凭证")
            startPolling()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onStatus("网页加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onStatus("网页加载失败：\(error.localizedDescription)")
        }

        private func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.probe()
            }
        }

        private func probe() {
            guard !didCaptureToken, let webView = webView else { return }
            webView.evaluateJavaScript(Self.extractScript) { [weak self] result, _ in
                guard let self else { return }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return
                }
                let storage = (object["ls"] as? [String: String]) ?? [:]
                if let token = CredentialExtractor.findToken(in: storage) {
                    self.didCaptureToken = true
                    self.timer?.invalidate()
                    self.parent.onToken(token)
                    self.parent.onStatus("已抓到 access token")
                }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let header = CredentialExtractor.cookieHeader(from: cookies)
                    guard !header.isEmpty else { return }
                    self.parent.onCookie(header)
                }
            }
        }

        static let extractScript = """
        (function () {
          var out = {};
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              out[k] = localStorage.getItem(k);
            }
          } catch (e) {}
          try {
            for (var i = 0; i < sessionStorage.length; i++) {
              var k = sessionStorage.key(i);
              out['__session__' + k] = sessionStorage.getItem(i);
            }
          } catch (e) {}
          var cookie = '';
          try { cookie = document.cookie; } catch (e) {}
          return JSON.stringify({ ls: out, cookie: cookie, href: location.href });
        })()
        """
    }
}
