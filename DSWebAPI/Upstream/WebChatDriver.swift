import Foundation
import WebKit
import UIKit
import Combine

/// 把网页端截获的 SSE 原始文本增量解析成回复增量。纯逻辑，方便单测。
struct WebReplyCollector {
    private var parser = SSEParser()
    private var consumed = 0

    /// 喂入网页端**累计**收到的原始 SSE 文本，只处理新增的部分。
    mutating func ingest(raw: String) -> [UpstreamDelta] {
        guard raw.count > consumed else { return [] }
        let chunk = String(raw.dropFirst(consumed))
        consumed = raw.count
        var out: [UpstreamDelta] = []
        for event in parser.feed(chunk) {
            out.append(contentsOf: UpstreamEventParser.interpret(event))
        }
        return out
    }

    /// 流结束后把残留的半截事件也算出来
    mutating func flush() -> [UpstreamDelta] {
        var out: [UpstreamDelta] = []
        for event in parser.flush() {
            out.append(contentsOf: UpstreamEventParser.interpret(event))
        }
        return out
    }
}

/// 网页驱动模式：让真实的 DeepSeek 网页自己去发消息，我们把它的回复截下来转成 API。
///
/// 为什么这么做：
/// - 网页端的 PoW 工作量证明、HIF 风控令牌、登录态、会话管理，全都是官方页面自己在做，
///   我们不用再逆向内部接口，官方改协议也不会立刻把 App 打断。
/// - 我们只做三件事：在页面里把文字填进输入框 → 触发发送 → 把它自己发出的
///   `/api/v0/chat/completion` 响应（SSE 流）截获下来，用现成的解析器还原成正文。
///
/// 整个过程发生在同一个 WKWebView 里，所以 Cookie、localStorage、指纹全都是官方的。
///
/// 注意：类本身不做并发隔离（方便 SwiftUI 直接观察），但凡是要碰 WKWebView 的方法
/// 都标了 @MainActor —— WebKit 只允许在主线程访问。
final class WebChatDriver: NSObject, ObservableObject {

    enum DriverError: LocalizedError {
        case pageNotReady
        case composerNotFound
        case sendNotTriggered
        case replyTimedOut
        case pageError(String)

        var errorDescription: String? {
            switch self {
            case .pageNotReady: return "网页端还没加载好，请到「网页」页点一下「重新加载网页」"
            case .composerNotFound: return "在网页里找不到输入框，官方可能改版了"
            case .sendNotTriggered: return "网页端没有发出请求，消息没发出去"
            case .replyTimedOut: return "等待网页端回复超时"
            case let .pageError(text): return "网页端返回错误：\(text)"
            }
        }
    }

    /// 从网页里读回来的一帧状态
    struct Snapshot: Equatable {
        var raw: String = ""
        var count: Int = 0
        var active: Bool = false
        var done: Bool = true
        var error: String = ""
        var httpStatus: Int = 0
        var loggedIn: Bool = false
        var composerFound: Bool = false
        var href: String = ""

        static func decode(_ json: String) -> Snapshot {
            guard let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
                return Snapshot()
            }
            var snap = Snapshot()
            snap.raw = (dict["raw"] as? String) ?? ""
            snap.count = (dict["count"] as? Int) ?? 0
            snap.active = (dict["active"] as? Bool) ?? false
            snap.done = (dict["done"] as? Bool) ?? true
            snap.error = (dict["error"] as? String) ?? ""
            snap.httpStatus = (dict["httpStatus"] as? Int) ?? 0
            snap.loggedIn = (dict["loggedIn"] as? Bool) ?? false
            snap.composerFound = (dict["composerFound"] as? Bool) ?? false
            snap.href = (dict["href"] as? String) ?? ""
            return snap
        }
    }

    /// JS 脚本返回的小结果
    struct JSResult {
        var ok: Bool = false
        var error: String = ""
        var detail: String = ""
    }

    @Published private(set) var status: String = "准备中…"
    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var loggedIn: Bool = false
    @Published private(set) var composerFound: Bool = false
    @Published private(set) var lastReply: String = ""
    @Published private(set) var lastError: String = ""
    /// 当前网页端会话对应的 OpenAI 侧会话 ID
    @Published private(set) var currentConversation: String = ""

    static let shared = WebChatDriver()

    private(set) var webView: WKWebView?
    private var didFinishLoad = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var navProxy: NavigationProxy?

    override private init() {
        super.init()
    }

    // MARK: - 生命周期

    /// 确保网页端已经加载好（没加载就加载，等它 load 完）
    @MainActor
    func ensureLoaded() async throws {
        if let webView, didFinishLoad {
            await refreshStatus()
            return
        }
        _ = makeWebViewIfNeeded()
        if didFinishLoad { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadWaiters.append(cont)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
                self?.finishLoadWaiters(with: .failure(DriverError.pageNotReady))
            }
        }
    }

    /// 重新加载网页端（登录状态变了之后用）
    @MainActor
    func reload() async {
        guard let webView else { _ = makeWebViewIfNeeded(); return }
        didFinishLoad = false
        status = "重新加载网页…"
        webView.reload()
        try? await ensureLoaded()
        await refreshStatus()
    }

    /// 切到一个新的网页端会话（重新加载页面 = 官方的新对话）
    @MainActor
    func startNewConversation() async {
        currentConversation = ""
        await reload()
    }

    /// 记录当前网页端会话对应的 OpenAI 侧会话 ID
    func setConversation(_ id: String) {
        currentConversation = id
    }

    /// 刷新登录/输入框状态
    @MainActor
    func refreshStatus() async {
        guard didFinishLoad, let webView else { return }
        guard let result = try? await webView.evaluateJavaScript(Self.snapshotScript),
              let json = result as? String else { return }
        let snap = Snapshot.decode(json)
        loggedIn = snap.loggedIn
        composerFound = snap.composerFound
        if !snap.loggedIn {
            status = "网页端未登录，请在下方网页里登录一次"
        } else if !snap.composerFound {
            status = "已登录，但没找到输入框（页面可能还在加载）"
        } else {
            status = "网页端就绪"
        }
    }

    // MARK: - 发消息

    /// 在网页里发一条消息，把网页端的回复转成增量流。
    @MainActor
    func send(prompt: String) -> AsyncThrowingStream<UpstreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.performSend(prompt: prompt) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    self.lastError = error.localizedDescription
                    self.status = "失败：\(error.localizedDescription)"
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private func performSend(prompt: String, onDelta: @escaping (UpstreamDelta) -> Void) async throws {
        try await ensureLoaded()
        let baseline = (try? await snapshot())?.count ?? 0
        lastError = ""
        status = "正在往网页里输入…"

        // 1) 把文字填进网页的输入框
        let fill = try await callJSON(Self.fillScript(prompt: prompt))
        guard fill.ok else {
            throw DriverError.composerNotFound
        }

        // 2) 触发发送：先试回车（网页最常见的交互），不行再找发送按钮点一下
        status = "正在触发发送…"
        _ = try? await callJSON(Self.enterScript)
        var triggered = await waitForNewRequest(baseline: baseline, timeout: 2.5)

        if !triggered {
            let click = try await callJSON(Self.clickScript)
            if click.ok {
                triggered = await waitForNewRequest(baseline: baseline, timeout: 3.0)
            }
            if !triggered {
                throw DriverError.sendNotTriggered
            }
        }

        status = "网页端已接收，等待回复…"

        // 3) 把网页端自己发出的 SSE 读回来，逐段解析
        var collector = WebReplyCollector()
        var gotFinish = false
        var idleTicks = 0
        var lastLength = -1
        var replyText = ""
        let deadline = Date().addingTimeInterval(240)

        while !Task.isCancelled {
            let snap = try await snapshot()

            if snap.httpStatus >= 400 {
                let snippet = String(snap.raw.prefix(300))
                throw DriverError.pageError(snippet.isEmpty ? "HTTP \(snap.httpStatus)" : snippet)
            }

            for delta in collector.ingest(raw: snap.raw) {
                switch delta {
                case let .content(text):
                    replyText += text
                    onDelta(.content(text))
                case let .thinking(text):
                    onDelta(.thinking(text))
                case let .finish(reason):
                    gotFinish = true
                    onDelta(.finish(reason))
                case let .failure(message):
                    onDelta(.failure(message))
                case .unknown:
                    break
                }
            }

            if snap.raw.count == lastLength {
                idleTicks += 1
            } else {
                idleTicks = 0
                lastLength = snap.raw.count
            }

            if snap.done && (gotFinish || idleTicks >= 2) { break }
            if Date() > deadline { throw DriverError.replyTimedOut }
            try await Task.sleep(nanoseconds: 90_000_000)
        }

        for delta in collector.flush() {
            switch delta {
            case let .content(text):
                replyText += text
                onDelta(.content(text))
            case let .thinking(text):
                onDelta(.thinking(text))
            case let .finish(reason):
                onDelta(.finish(reason))
            case let .failure(message):
                onDelta(.failure(message))
            case .unknown:
                break
            }
        }

        lastReply = replyText
        status = "完成（\(replyText.count) 字）"
    }

    /// 等网页端真的把请求发出去了（count 增加）
    @MainActor
    private func waitForNewRequest(baseline: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let snap = try? await snapshot(), snap.count > baseline { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return false
    }

    // MARK: - WKWebView

    @discardableResult
    @MainActor
    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.hookScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { view.isInspectable = true }

        let proxy = NavigationProxy()
        proxy.owner = self
        view.navigationDelegate = proxy
        navProxy = proxy

        webView = view
        attachToWindow(view)
        status = "正在加载网页端…"
        view.load(URLRequest(url: URL(string: "https://chat.deepseek.com/")!))
        return view
    }

    /// 把网页挂到界面上。网页第一次进入视图树时才会有真实 viewport，
    /// 所以「网页」页一出现就把它挂进去，之后切换标签也不会把它摘下来。
    @discardableResult
    func attachTo(container: UIView) -> WKWebView {
        if Thread.isMainThread {
            return attachOnMain(to: container)
        }
        return DispatchQueue.main.sync { attachOnMain(to: container) }
    }

    @MainActor
    private func attachOnMain(to container: UIView) -> WKWebView {
        let view = makeWebViewIfNeeded()
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        return view
    }

    /// 把网页挂到窗口外面（屏幕外），这样即使当前不在「网页」页，
    /// 它也在后台正常加载、执行 JS，API 才随时能用。
    @MainActor
    private func attachToWindow(_ view: WKWebView) {
        DispatchQueue.main.async {
            guard view.superview == nil else { return }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else { return }
            view.frame = CGRect(x: -20000, y: 0, width: 390, height: 844)
            window.addSubview(view)
        }
    }

    @MainActor
    fileprivate func handleLoadFinished() {
        didFinishLoad = true
        status = "网页已加载"
        finishLoadWaiters(with: .success(()))
        Task { @MainActor [weak self] in
            await self?.refreshStatus()
        }
    }

    @MainActor
    fileprivate func handleLoadFailed(_ error: Error) {
        status = "网页加载失败：\(error.localizedDescription)"
        finishLoadWaiters(with: .failure(DriverError.pageNotReady))
    }

    @MainActor
    private func finishLoadWaiters(with result: Result<Void, Error>) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: - 与网页通信

    @MainActor
    private func snapshot() async throws -> Snapshot {
        guard let webView, didFinishLoad else { throw DriverError.pageNotReady }
        let result = try await webView.evaluateJavaScript(Self.snapshotScript)
        guard let json = result as? String else { return Snapshot() }
        return Snapshot.decode(json)
    }

    @MainActor
    private func callJSON(_ script: String) async throws -> JSResult {
        guard let webView, didFinishLoad else { throw DriverError.pageNotReady }
        let result = try await webView.evaluateJavaScript(script)
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
            return JSResult(ok: false, error: "脚本没有返回结果")
        }
        return JSResult(ok: (dict["ok"] as? Bool) ?? false,
                        error: (dict["error"] as? String) ?? "",
                        detail: (dict["tag"] as? String) ?? "")
    }

    // MARK: - 注入的 JS

    /// 截获网页自己发出的聊天请求与 SSE 响应，并提供一组「操控页面」的函数。
    static let hookScript = """
    (function () {
      if (window.__dsDriverHooked) { return; }
      window.__dsDriverHooked = true;

      var state = window.__dsState = {
        raw: "", count: 0, active: false, done: true, error: "", httpStatus: 0
      };

      function isChatURL(u) {
        return typeof u === "string" && u.indexOf("/api/v0/chat/completion") >= 0;
      }

      function beginCapture(resp) {
        try {
          state.count += 1;
          state.raw = "";
          state.active = true;
          state.done = false;
          state.error = "";
          state.httpStatus = resp.status || 0;
          if (!resp.body || typeof resp.body.getReader !== "function") {
            resp.text().then(function (t) {
              state.raw = t || ""; state.active = false; state.done = true;
            }).catch(function (e) {
              state.error = String(e); state.active = false; state.done = true;
            });
            return;
          }
          var reader = resp.body.getReader();
          var decoder = new TextDecoder("utf-8");
          function pump() {
            return reader.read().then(function (r) {
              if (r.done) { state.active = false; state.done = true; return null; }
              state.raw += decoder.decode(r.value, { stream: true });
              return pump();
            });
          }
          pump().catch(function (e) {
            state.error = String(e); state.active = false; state.done = true;
          });
        } catch (e) {
          state.error = String(e);
        }
      }

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input) {
          var args = arguments;
          var url = "";
          try { url = (typeof input === "string") ? input : ((input && input.url) || ""); } catch (e) {}
          var promise = origFetch.apply(window, args);
          if (isChatURL(url)) {
            try { promise.then(function (resp) { beginCapture(resp); }, function () {}); } catch (e) {}
          }
          return promise;
        };
      }

      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__dsChatURL = isChatURL(String(url || "")); } catch (e) {}
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        if (this.__dsChatURL) {
          var xhr = this;
          try {
            xhr.addEventListener("load", function () {
              try {
                state.count += 1;
                state.raw = xhr.responseText || "";
                state.httpStatus = xhr.status || 0;
                state.active = false;
                state.done = true;
                state.error = "";
              } catch (e) {}
            });
          } catch (e) {}
        }
        return origSend.apply(this, arguments);
      };

      // ---- 操作页面 ----

      function visible(el) {
        if (!el || el.disabled) { return false; }
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      }

      function findComposer() {
        var nodes = document.querySelectorAll('textarea, [contenteditable="true"], [contenteditable="plaintext-only"]');
        var best = null;
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!visible(el)) { continue; }
          if (el.getAttribute("aria-hidden") === "true") { continue; }
          var ph = (el.getAttribute("placeholder") || "").toLowerCase();
          if (ph.indexOf("搜索") >= 0 || ph.indexOf("search") >= 0) { continue; }
          best = el;
        }
        return best;
      }

      function makeKeyEvent(type) {
        var ev;
        try {
          ev = new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true });
        } catch (e) {
          ev = new Event(type, { bubbles: true, cancelable: true });
        }
        try { Object.defineProperty(ev, "keyCode", { get: function () { return 13; } }); } catch (e) {}
        try { Object.defineProperty(ev, "which", { get: function () { return 13; } }); } catch (e) {}
        try { Object.defineProperty(ev, "isComposing", { get: function () { return false; } }); } catch (e) {}
        return ev;
      }

      window.__dsFill = function (text) {
        var el = findComposer();
        if (!el) { return JSON.stringify({ ok: false, error: "找不到输入框" }); }
        try {
          el.focus();
          if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
            var proto = el.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
            var desc = Object.getOwnPropertyDescriptor(proto, "value");
            if (desc && desc.set) { desc.set.call(el, text); } else { el.value = text; }
          } else {
            el.textContent = text;
          }
          try {
            el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
          } catch (e) {
            el.dispatchEvent(new Event("input", { bubbles: true }));
          }
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return JSON.stringify({ ok: true, tag: el.tagName, placeholder: el.getAttribute("placeholder") || "" });
        } catch (e) {
          return JSON.stringify({ ok: false, error: String(e) });
        }
      };

      window.__dsEnter = function () {
        var el = findComposer();
        if (!el) { return JSON.stringify({ ok: false, error: "找不到输入框" }); }
        try {
          el.focus();
          el.dispatchEvent(makeKeyEvent("keydown"));
          el.dispatchEvent(makeKeyEvent("keypress"));
          el.dispatchEvent(makeKeyEvent("keyup"));
          return JSON.stringify({ ok: true });
        } catch (e) {
          return JSON.stringify({ ok: false, error: String(e) });
        }
      };

      function findSendButtonNearComposer() {
        var el = findComposer();
        if (!el) { return null; }
        var r = el.getBoundingClientRect();
        var vw = window.innerWidth || 390;
        var vh = window.innerHeight || 844;
        var points = [
          [Math.min(r.right + 22, vw - 6), Math.max(r.top + r.height / 2, 6)],
          [Math.min(r.right + 34, vw - 6), Math.max(r.top + r.height / 2, 6)],
          [r.left + r.width / 2, Math.min(r.bottom + 14, vh - 6)]
        ];
        for (var i = 0; i < points.length; i++) {
          var hit = document.elementFromPoint(points[i][0], points[i][1]);
          if (!hit || hit === el) { continue; }
          var node = hit;
          while (node && node !== document.body) {
            if (node.tagName === "BUTTON" || node.getAttribute("role") === "button") { return node; }
            if (/send|arrow|submit/i.test(String(node.className || ""))) { return node; }
            node = node.parentElement;
          }
          return hit;
        }
        return null;
      }

      function findSendButton() {
        var cands = document.querySelectorAll('button, [role="button"], [class*="send"], [class*="Send"]');
        var best = null;
        for (var i = 0; i < cands.length; i++) {
          var el = cands[i];
          if (!visible(el)) { continue; }
          var label = ((el.getAttribute("aria-label") || "") + " " + (el.getAttribute("title") || "") + " " +
                       (el.getAttribute("data-testid") || "") + " " + (el.className || "")).toLowerCase();
          if (label.indexOf("发送") >= 0 || label.indexOf("send") >= 0 || label.indexOf("submit") >= 0) { best = el; }
        }
        return best || findSendButtonNearComposer();
      }

      window.__dsClickSend = function () {
        var btn = findSendButton();
        if (!btn) { return JSON.stringify({ ok: false, error: "找不到发送按钮" }); }
        try {
          btn.click();
          return JSON.stringify({ ok: true, tag: btn.tagName });
        } catch (e) {
          return JSON.stringify({ ok: false, error: String(e) });
        }
      };

      window.__dsSnapshot = function () {
        var st = window.__dsState || {};
        var loggedIn = false;
        try {
          var raw = localStorage.getItem("userToken") || "";
          if (raw) {
            try {
              var obj = JSON.parse(raw);
              loggedIn = !!(obj && (obj.value || obj.access_token || obj.token));
            } catch (e) { loggedIn = true; }
          }
        } catch (e) {}
        return JSON.stringify({
          raw: st.raw || "",
          count: st.count || 0,
          active: !!st.active,
          done: st.done !== false,
          error: st.error || "",
          httpStatus: st.httpStatus || 0,
          loggedIn: loggedIn,
          composerFound: !!findComposer(),
          href: location.href
        });
      };
    })();
    """

    static let snapshotScript = "(function(){ try { return window.__dsSnapshot ? window.__dsSnapshot() : '{}'; } catch (e) { return '{}'; } })()"

    static func fillScript(prompt: String) -> String {
        let encoded = jsonString(prompt)
        return "(function(){ try { return window.__dsFill ? window.__dsFill(\(encoded)) : JSON.stringify({ok:false,error:'脚本没装上'}); } catch (e) { return JSON.stringify({ok:false,error:String(e)}); } })()"
    }

    static let enterScript = "(function(){ try { return window.__dsEnter ? window.__dsEnter() : JSON.stringify({ok:false,error:'脚本没装上'}); } catch (e) { return JSON.stringify({ok:false,error:String(e)}); } })()"

    static let clickScript = "(function(){ try { return window.__dsClickSend ? window.__dsClickSend() : JSON.stringify({ok:false,error:'脚本没装上'}); } catch (e) { return JSON.stringify({ok:false,error:String(e)}); } })()"

    /// 把字符串安全地编码成 JSON 字面量（含引号、换行、反斜杠转义）
    static func jsonString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let quoted = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return quoted
    }

    /// 导航代理单独拎出来，避免 @MainActor 与协议方法之间的隔离冲突
    final class NavigationProxy: NSObject, WKNavigationDelegate {
        weak var owner: WebChatDriver?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in self?.owner?.handleLoadFinished() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in self?.owner?.handleLoadFailed(error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in self?.owner?.handleLoadFailed(error) }
        }
    }
}
