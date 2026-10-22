import SwiftUI
import WebKit

/// App 内嵌的 DeepSeek 网页登录页：登录成功后自动把 access token / cookie 抠出来。
///
/// 三路并行的抓取方式（谁先成功用谁）：
/// 1. **挂钩页面 fetch**：网页自己每次请求都会带 `Authorization: Bearer <token>`，
///    在 documentStart 注入钩子把它截下来 —— 最稳，不依赖存储 key 叫什么。
/// 2. **扫 localStorage / sessionStorage**：找 userToken / access_token 之类的键。
/// 3. **读 Cookie**：从 WKWebView 的 cookie store 里拿 deepseek 域下的 cookie。
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

        // documentStart 注入：拦截页面自己的请求，把 Authorization 头里的 token 留下来
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Coordinator.tokenHookScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        configuration.userContentController = controller

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
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.probe()
            }
            probe()
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

                // 1) 挂钩拿到的 Authorization
                if let hooked = object["hookToken"] as? String,
                   !hooked.isEmpty,
                   CredentialExtractor.looksLikeToken(hooked) {
                    self.didCaptureToken = true
                    self.timer?.invalidate()
                    self.parent.onToken(hooked)
                    self.parent.onStatus("已抓到 access token（网页请求头）")
                    return
                }

                // 2) 扫存储
                var storage: [String: String] = [:]
                if let local = object["ls"] as? [String: String] { storage.merge(local) { _, new in new } }
                if let session = object["ss"] as? [String: String] { storage.merge(session) { _, new in new } }

                if let token = CredentialExtractor.findToken(in: storage) {
                    self.didCaptureToken = true
                    self.timer?.invalidate()
                    self.parent.onToken(token)
                    self.parent.onStatus("已抓到 access token（本地存储）")
                    return
                }

                // 3) 读 Cookie
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let header = CredentialExtractor.cookieHeader(from: cookies)
                    guard !header.isEmpty else { return }
                    self.parent.onCookie(header)
                }
            }
        }

        /// 注入脚本：把页面自己发出的请求里的 Authorization 头留下来
        static let tokenHookScript = """
        (function () {
          if (window.__dsTokenHooked) { return; }
          window.__dsTokenHooked = true;
          function grab(headers) {
            try {
              if (!headers) { return; }
              var value = null;
              if (typeof headers.get === 'function') { value = headers.get('authorization'); }
              if (!value && typeof headers === 'object') {
                value = headers['Authorization'] || headers['authorization'] || headers['X-Authorization'];
              }
              if (value && String(value).indexOf('Bearer ') === 0) {
                window.__dsToken = String(value).slice(7);
              }
            } catch (e) {}
          }
          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function (input, init) {
              try {
                if (init && init.headers) { grab(init.headers); }
                if (input && input.headers && typeof input.headers.get === 'function') { grab(input.headers); }
              } catch (e) {}
              return originalFetch.apply(this, arguments);
            };
          }
          var originalOpen = XMLHttpRequest.prototype.open;
          var originalSetHeader = XMLHttpRequest.prototype.setRequestHeader;
          XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
            try { if (String(name).toLowerCase() === 'authorization') { grab({ 'Authorization': value }); } } catch (e) {}
            return originalSetHeader.apply(this, arguments);
          };
        })();
        """

        /// 取出页面里的存储 + 挂钩到的 token
        static let extractScript = """
        (function () {
          var out = { ls: {}, ss: {}, hookToken: window.__dsToken || '' };
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              out.ls[k] = localStorage.getItem(k);
            }
          } catch (e) {}
          try {
            for (var i = 0; i < sessionStorage.length; i++) {
              var k = sessionStorage.key(i);
              out.ss[k] = sessionStorage.getItem(i);
            }
          } catch (e) {}
          var cookie = '';
          try { cookie = document.cookie; } catch (e) {}
          out.cookie = cookie;
          return JSON.stringify(out);
        })()
        """
    }
}
