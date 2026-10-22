import Foundation

/// 把 DeepSeek 网页端接口包装成 OpenAI 兼容的本地 HTTP API。
///
/// 对外暴露：
///   GET  /                      内置网页聊天框（用本 API 驱动）
///   GET  /health                健康检查
///   GET  /v1/models             模型列表
///   POST /v1/chat/completions   聊天补全（支持 stream）
final class BridgeServer {
    private var server: HttpServer?
    private let queue = DispatchQueue(label: "com.qweq-1.dswebapi.bridge")

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
        boundPort = settings.port
        isRunning = true
        logger(.ok, "本地 API 已启动：http://0.0.0.0:\(settings.port)/v1")
        return settings.port
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
        let path = request.path.hasSuffix("/") && request.path.count > 1
            ? String(request.path.dropLast())
            : request.path

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
        // 浏览器端也支持 ?key=xxx
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
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "has_token": !tokenProvider().isEmpty,
            "has_cookie": !cookieProvider().isEmpty,
            "model": settings.model,
            "thinking_enabled": settings.thinkingEnabled,
            "search_enabled": settings.searchEnabled
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

    private func handleChat(_ request: HTTPRequest, _ writer: HTTPResponseWriter) {
        let payload = request.jsonBody
        if payload.isEmpty {
            writer.sendHead(status: 400)
            writer.write(OpenAIEnvelope.error("请求体不是合法的 JSON", code: "invalid_request"))
            writer.close()
            return
        }

        let settings = settingsProvider()
        var messages = Self.parseMessages(payload["messages"])
        if messages.isEmpty {
            writer.sendHead(status: 400)
            writer.write(OpenAIEnvelope.error("messages 不能为空", code: "invalid_request"))
            writer.close()
            return
        }
        let systemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty && !messages.contains(where: { $0.role == "system" }) {
            messages.insert(.init(role: "system", content: systemPrompt), at: 0)
        }

        let requestedModel = (payload["model"] as? String) ?? settings.model
        var options = DeepSeekWebClient.Options()
        options.model = requestedModel.isEmpty ? "deepseek-chat" : requestedModel
        options.thinkingEnabled = settings.thinkingEnabled || requestedModel.contains("reasoner")
        options.searchEnabled = settings.searchEnabled
        options.temperature = (payload["temperature"] as? Double) ?? settings.temperature
        options.maxTokens = (payload["max_tokens"] as? Int) ?? settings.maxTokens

        let wantsStream = (payload["stream"] as? Bool) ?? true
        logger(.info, "收到请求 model=\(options.model) stream=\(wantsStream) messages=\(messages.count)")

        let client = makeClient()
        let envelope = OpenAIEnvelope(model: options.model)

        if wantsStream {
            streamResponse(client: client,
                           messages: messages,
                           options: options,
                           envelope: envelope,
                           writer: writer)
        } else {
            blockingResponse(client: client,
                             messages: messages,
                             options: options,
                             envelope: envelope,
                             writer: writer)
        }
    }

    private func streamResponse(client: DeepSeekWebClient,
                                messages: [DeepSeekWebClient.UpstreamMessage],
                                options: DeepSeekWebClient.Options,
                                envelope: OpenAIEnvelope,
                                writer: HTTPResponseWriter) {
        writer.sendHead(status: 200, contentType: "text/event-stream; charset=utf-8")

        Task { [weak self] in
            var isFirst = true
            var finishReason = "stop"
            var fullText = ""

            do {
                let upstream = client.stream(messages: messages, options: options)
                for try await event in upstream {
                    if let self = self, self.settingsProvider().showRawStream {
                        self.logger(.info, "上游事件：\(event.event ?? "-") \(event.data)")
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
                            writer.write("data: \(envelope.chunk(delta: ["reasoning_content": text], finishReason: nil))\n\n")
                        case let .finish(reason):
                            finishReason = reason ?? "stop"
                        case let .failure(message):
                            writer.write("data: \(OpenAIEnvelope.error(message))\n\n")
                        case let .unknown(raw):
                            if let self = self, self.settingsProvider().showRawStream {
                                self.logger(.info, "未识别负载：\(raw)")
                            }
                        }
                    }
                }
            } catch {
                writer.write("data: \(OpenAIEnvelope.error(error.localizedDescription))\n\n")
            }

            writer.write("data: \(envelope.chunk(delta: [:], finishReason: finishReason))\n\n")
            writer.write("data: [DONE]\n\n")
            writer.close()
            logger(.ok, "本次回复完成，共 \(fullText.count) 字")
        }
    }

    private func blockingResponse(client: DeepSeekWebClient,
                                  messages: [DeepSeekWebClient.UpstreamMessage],
                                  options: DeepSeekWebClient.Options,
                                  envelope: OpenAIEnvelope,
                                  writer: HTTPResponseWriter) {
        Task { [weak self] in
            do {
                var text = ""
                var thinking = ""
                do {
                    text = try await client.complete(messages: messages, options: options)
                } catch {
                    // 上游可能只支持流式，退回流式聚合
                    let upstream = client.stream(messages: messages, options: options)
                    for try await event in upstream {
                        for delta in UpstreamEventParser.interpret(event) {
                            switch delta {
                            case let .content(chunk): text += chunk
                            case let .thinking(chunk): thinking += chunk
                            default: break
                            }
                        }
                    }
                }
                writer.sendHead(status: 200)
                writer.write(envelope.completion(content: text, thinking: thinking, finishReason: "stop"))
                writer.close()
            } catch {
                writer.sendHead(status: 502)
                writer.write(OpenAIEnvelope.error(error.localizedDescription, code: "upstream_error"))
                writer.close()
            }
            if let self = self {
                self.logger(.ok, "非流式请求完成")
            }
        }
    }

    // MARK: - 工具

    private func makeClient() -> DeepSeekWebClient {
        let settings = settingsProvider()
        return DeepSeekWebClient(
            baseURL: URL(string: settings.baseURL) ?? URL(string: "https://chat.deepseek.com")!,
            accessToken: tokenProvider(),
            sessionCookie: cookieProvider(),
            deviceID: AppSettings.deviceID,
            clientVersion: settings.clientVersion
        )
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
