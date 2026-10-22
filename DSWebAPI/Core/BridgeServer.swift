import Foundation

/// 把 DeepSeek 网页端接口包装成 OpenAI 兼容的本地 HTTP API。
///
/// 对外暴露：
///   GET  /                      内置网页聊天框（用本 API 驱动）
///   GET  /health                健康检查
///   GET  /v1/models             模型列表
///   POST /v1/chat/completions   聊天补全（支持 stream）
///
/// 网页端一次只接受一条 prompt，历史靠 chat_session_id 串起来，
/// 所以这里维护一个"会话登记表"，把 OpenAI 风格的 messages 数组映射成网页端会话。
final class BridgeServer {

    /// 一个网页端会话的状态
    struct ConversationState {
        var chatSessionID: String
        var lastMessageID: String?
        var fingerprint: String
        var messageCount: Int
    }

    /// 会话登记表（线程安全）
    final class ConversationStore {
        private var states: [String: ConversationState] = [:]
        private let lock = NSLock()

        /// 取（必要时新建）一个会话
        func state(for key: String, fingerprint: String, messageCount: Int) -> ConversationState {
            lock.lock()
            defer { lock.unlock() }
            if var existing = states[key],
               existing.fingerprint == fingerprint,
               existing.messageCount < messageCount {
                existing.messageCount = messageCount
                states[key] = existing
                return existing
            }
            let fresh = ConversationState(chatSessionID: UUID().uuidString.lowercased(),
                                          lastMessageID: nil,
                                          fingerprint: fingerprint,
                                          messageCount: messageCount)
            states[key] = fresh
            return fresh
        }

        /// 记录这一轮返回的 message_id，下一轮用它当 parent_message_id
        func updateMessage(id: String?, key: String) {
            lock.lock()
            defer { lock.unlock() }
            guard var state = states[key], let id = id, !id.isEmpty else { return }
            state.lastMessageID = id
            states[key] = state
        }
    }

    private var server: HttpServer?
    private let conversations = ConversationStore()

    private let settingsProvider: () -> AppSettings
    private let tokenProvider: () -> String
    private let cookieProvider: () -> String
    private let logger: (LogLine.Level, String) -> Void

    private(set) var isRunning = false
    private(set) var boundPort: UInt16 = 0

    init(settingsProvider: @escaping () -> AppSettings,
         tokenProvider: @escaping () -> String,
         cookieProvider: @escaping () -> String,
         logger: @escaping (LogLine.Level, String) -> Void) {
        self.settingsProvider = settingsProvider
        self.tokenProvider = tokenProvider
        self.cookieProvider = cookieProvider
        self.logger = logger
    }

    @discardableResult
    func start() throws -> UInt16 {
        let settings = settingsProvider()
        let http = HttpServer { [weak self] request, writer in
            self?.handle(request, writer)
        }
        try http.start(port: UInt16(settings.port))
        server = http
        boundPort = UInt16(settings.port)
        isRunning = true
        logger(.ok, "本地 API 已启动：http://0.0.0.0:\(settings.port)/v1")
        return UInt16(settings.port)
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        logger(.warn, "本地 API 已停止")
    }

    func restart() throws -> UInt16 {
        stop()
        return try start()
    }

    // MARK: - 路由

    private func handle(_ request: HTTPRequest, _ writer: HTTPResponseWriter) {
        var path = request.path
        if path.count > 1 && path.hasSuffix("/") { path = String(path.dropLast()) }

        if request.method == .options {
            writer.sendHead(status: 204, contentType: "text/plain")
            writer.close()
            return
        }

        switch path {
        case "/", "/index.html", "/chat":
            serveChatPage(writer)
        case "/health":
            serveHealth(writer)
        case "/v1/models":
            guard authorize(request) else {
                sendUnauthorized(writer)
                return
            }
            serveModels(writer)
        case "/v1/chat/completions", "/chat/completions":
            guard request.method == .post else {
                writer.sendHead(status: 405)
                writer.write(OpenAIEnvelope.error("这个接口要用 POST", code: "method_not_allowed"))
                writer.close()
                return
            }
            guard authorize(request) else {
                sendUnauthorized(writer)
                return
            }
            handleChat(request, writer)
        default:
            writer.sendHead(status: 404)
            writer.write(OpenAIEnvelope.error("没有这个接口：\(path)", code: "not_found"))
            writer.close()
        }
    }

    private func authorize(_ request: HTTPRequest) -> Bool {
        let settings = settingsProvider()
        let expected = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if expected.isEmpty { return true }

        var provided = request.header("authorization")
        if provided.lowercased().hasPrefix("bearer ") {
            provided = String(provided.dropFirst(7))
        }
        if provided == expected { return true }
        if let queryKey = request.query["key"], queryKey == expected { return true }
        return false
    }

    private func sendUnauthorized(_ writer: HTTPResponseWriter) {
        writer.sendHead(status: 401)
        writer.write(OpenAIEnvelope.error("缺少或错误的 API Key，请在请求头带 Authorization: Bearer <key>", code: "invalid_api_key"))
        writer.close()
    }

    // MARK: - 具体接口

    private func serveHealth(_ writer: HTTPResponseWriter) {
        let settings = settingsProvider()
        let body: [String: Any] = [
            "status": "ok",
            "service": "DeepSeek Web → OpenAI API",
            "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0",
            "has_token": !tokenProvider().isEmpty,
            "has_cookie": !cookieProvider().isEmpty,
            "model": settings.model,
            "thinking_enabled": settings.thinkingEnabled,
            "search_enabled": settings.searchEnabled,
            "upstream": settings.baseURL
        ]
        writer.sendHead(status: 200)
        writer.write(OpenAIEnvelope.json(body))
        writer.close()
    }

    private func serveModels(_ writer: HTTPResponseWriter) {
        let created = Int(Date().timeIntervalSince1970)
        let models = ["deepseek-chat", "deepseek-reasoner", "deepseek-coder"]
        let data = models.map { model -> [String: Any] in
            [
                "id": model,
                "object": "model",
                "created": created,
                "owned_by": "deepseek-web"
            ]
        }
        writer.sendHead(status: 200)
        writer.write(OpenAIEnvelope.json(["object": "list", "data": data]))
        writer.close()
    }

    private func serveChatPage(_ writer: HTTPResponseWriter) {
        guard let url = Bundle.main.url(forResource: "chat", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            writer.sendHead(status: 404)
            writer.write("chat page not found")
            writer.close()
            return
        }
        writer.sendHead(status: 200, contentType: "text/html; charset=utf-8")
        writer.write(html)
        writer.close()
    }

    // MARK: - 聊天补全

    private func handleChat(_ request: HTTPRequest, _ writer: HTTPResponseWriter) {
        let payload = request.jsonBody
        if payload.isEmpty {
            writer.sendHead(status: 400)
            writer.write(OpenAIEnvelope.error("请求体不是合法的 JSON", code: "invalid_request"))
            writer.close()
            return
        }

        var messages = Self.parseMessages(payload["messages"])
        if messages.isEmpty {
            writer.sendHead(status: 400)
            writer.write(OpenAIEnvelope.error("messages 不能为空", code: "invalid_request"))
            writer.close()
            return
        }

        let settings = settingsProvider()

        // 网页端没有 system 角色，把系统提示词拼到第一条用户消息前面
        let systemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty, messages.first?.role == "user" {
            messages[0].content = systemPrompt + "\n\n" + messages[0].content
        }

        // 网页端一次只发一条：取最后一条用户消息
        guard let prompt = messages.last(where: { $0.role == "user" })?.content ?? messages.last?.content else {
            writer.sendHead(status: 400)
            writer.write(OpenAIEnvelope.error("没有可发送的内容", code: "invalid_request"))
            writer.close()
            return
        }

        let requestedModel = (payload["model"] as? String) ?? settings.model
        var options = DeepSeekWebClient.Options()
        options.modelType = requestedModel.isEmpty ? "deepseek-chat" : requestedModel
        options.thinkingEnabled = settings.thinkingEnabled || requestedModel.contains("reasoner")
        options.searchEnabled = settings.searchEnabled
        options.temperature = (payload["temperature"] as? Double) ?? settings.temperature
        options.maxTokens = (payload["max_tokens"] as? Int) ?? settings.maxTokens

        let wantsStream = (payload["stream"] as? Bool) ?? true
        let fingerprint = messages.first?.content ?? ""
        let conversationKey = (payload["conversation_id"] as? String) ?? ("auto:" + String(fingerprint.hashValue))

        logger(.info, "收到请求 model=\(options.modelType) stream=\(wantsStream) messages=\(messages.count)")

        Task { [weak self] in
            guard let self = self else { return }
            await self.runCompletion(prompt: prompt,
                                     options: options,
                                     wantsStream: wantsStream,
                                     conversationKey: conversationKey,
                                     fingerprint: fingerprint,
                                     messageCount: messages.count,
                                     writer: writer)
        }
    }

    private func runCompletion(prompt: String,
                               options: DeepSeekWebClient.Options,
                               wantsStream: Bool,
                               conversationKey: String,
                               fingerprint: String,
                               messageCount: Int,
                               writer: HTTPResponseWriter) async {
        let client = makeClient()
        let guest = !client.isLoggedIn
        let envelope = OpenAIEnvelope(model: options.modelType)

        do {
            // 1) 取工作量证明题目并解出来
            let challenge = try await client.fetchChallenge(guest: guest)
            let answer = try challenge.solve()
            let powHeader = client.powHeaderValue(challenge: challenge, answer: answer, guest: guest)
            logger(.info, "PoW 已完成（answer=\(answer)，guest=\(guest)）")

            // 2) 拿到（或新建）网页端会话
            let state = conversations.state(for: conversationKey,
                                           fingerprint: fingerprint,
                                           messageCount: messageCount)

            let upstreamRequest = try client.makeCompletionRequest(prompt: prompt,
                                                                    options: options,
                                                                    chatSessionID: state.chatSessionID,
                                                                    parentMessageID: state.lastMessageID,
                                                                    powHeader: powHeader)

            if wantsStream {
                await streamUpstream(request: upstreamRequest,
                                     envelope: envelope,
                                     conversationKey: conversationKey,
                                     writer: writer)
            } else {
                await blockingUpstream(request: upstreamRequest,
                                       envelope: envelope,
                                       conversationKey: conversationKey,
                                       writer: writer)
            }
        } catch {
            logger(.error, "上游失败：\(error.localizedDescription)")
            if wantsStream {
                writer.write("data: \(OpenAIEnvelope.error(error.localizedDescription, code: "upstream_error"))\n\n")
                writer.write("data: [DONE]\n\n")
            } else {
                writer.sendHead(status: 502)
                writer.write(OpenAIEnvelope.error(error.localizedDescription, code: "upstream_error"))
            }
            writer.close()
        }
    }

    private func streamUpstream(request: URLRequest,
                                envelope: OpenAIEnvelope,
                                conversationKey: String,
                                writer: HTTPResponseWriter) async {
        writer.sendHead(status: 200, contentType: "text/event-stream; charset=utf-8")

        var isFirst = true
        var finishReason = "stop"
        var fullText = ""
        var thinkingText = ""

        do {
            let client = makeClient()
            for try await event in client.stream(request: request) {
                if settingsProvider().showRawStream {
                    logger(.info, "上游事件 [\(event.event ?? "-")] \(event.data)")
                }
                if let messageID = Self.messageID(in: event) {
                    conversations.updateMessage(id: messageID, key: conversationKey)
                }
                for delta in UpstreamEventParser.interpret(event) {
                    switch delta {
                    case let .content(text):
                        fullText += text
                        var payload: [String: Any] = ["content": text]
                        if isFirst {
                            payload["role"] = "assistant"
                            isFirst = false
                        }
                        writer.write("data: \(envelope.chunk(delta: payload, finishReason: nil))\n\n")
                    case let .thinking(text):
                        thinkingText += text
                        writer.write("data: \(envelope.chunk(delta: ["reasoning_content": text], finishReason: nil))\n\n")
                    case let .finish(reason):
                        finishReason = reason ?? "stop"
                    case let .failure(message):
                        writer.write("data: \(OpenAIEnvelope.error(message))\n\n")
                    case let .unknown(raw):
                        if settingsProvider().showRawStream {
                            logger(.info, "未识别负载：\(raw)")
                        }
                    }
                }
            }
        } catch {
            writer.write("data: \(OpenAIEnvelope.error(error.localizedDescription, code: "upstream_error"))\n\n")
        }

        writer.write("data: \(envelope.chunk(delta: [:], finishReason: finishReason))\n\n")
        writer.write("data: [DONE]\n\n")
        writer.close()
        logger(.ok, "本次回复完成，正文 \(fullText.count) 字，思考 \(thinkingText.count) 字")
    }

    private func blockingUpstream(request: URLRequest,
                                  envelope: OpenAIEnvelope,
                                  conversationKey: String,
                                  writer: HTTPResponseWriter) async {
        var content = ""
        var thinking = ""
        var finishReason = "stop"
        do {
            let client = makeClient()
            for try await event in client.stream(request: request) {
                if let messageID = Self.messageID(in: event) {
                    conversations.updateMessage(id: messageID, key: conversationKey)
                }
                for delta in UpstreamEventParser.interpret(event) {
                    switch delta {
                    case let .content(text): content += text
                    case let .thinking(text): thinking += text
                    case let .finish(reason): finishReason = reason ?? "stop"
                    default: break
                    }
                }
            }
            writer.sendHead(status: 200)
            writer.write(envelope.completion(content: content, thinking: thinking, finishReason: finishReason))
        } catch {
            writer.sendHead(status: 502)
            writer.write(OpenAIEnvelope.error(error.localizedDescription, code: "upstream_error"))
        }
        writer.close()
        logger(.ok, "非流式请求完成，正文 \(content.count) 字")
    }

    // MARK: - 工具

    private func makeClient() -> DeepSeekWebClient {
        let settings = settingsProvider()
        return DeepSeekWebClient(
            baseURL: URL(string: settings.baseURL) ?? URL(string: "https://chat.deepseek.com")!,
            accessToken: tokenProvider(),
            sessionCookie: cookieProvider(),
            deviceID: AppSettings.deviceID,
            deviceModel: settings.deviceModel,
            clientVersion: settings.clientVersion,
            clientLocale: settings.clientLocale,
            clientPlatform: settings.clientPlatform,
            clientBundleID: settings.clientBundleID,
            timezoneOffsetSeconds: settings.timezoneOffsetSeconds
        )
    }

    /// 从 SSE 事件里抠出 message_id（下一轮当 parent_message_id 用）
    static func messageID(in event: SSEEvent) -> String? {
        guard let data = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return findMessageID(in: json)
    }

    private static func findMessageID(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let value = dict["message_id"] as? String, !value.isEmpty { return value }
            for key in ["biz_data", "data", "message"] {
                if let nested = dict[key] {
                    if let found = findMessageID(in: nested) { return found }
                }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = findMessageID(in: item) { return found }
            }
        }
        return nil
    }

    static func parseMessages(_ raw: Any?) -> [DeepSeekWebClient.UpstreamMessage] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let role = (item["role"] as? String) ?? "user"
            var content = ""
            if let text = item["content"] as? String {
                content = text
            } else if let parts = item["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if let text = item["content"] as? [String: Any] {
                content = (text["text"] as? String) ?? ""
            }
            guard !content.isEmpty else { return nil }
            return DeepSeekWebClient.UpstreamMessage(role: role, content: content)
        }
    }
}
