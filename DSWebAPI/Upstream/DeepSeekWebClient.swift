import Foundation

enum UpstreamError: LocalizedError {
    case missingCredential
    case http(status: Int, body: String)
    case badResponse(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "还没有 DeepSeek 网页端登录凭证，请先在设置里登录或粘贴 access token"
        case let .http(status, body):
            let preview = String(body.prefix(400))
            return "DeepSeek 返回 HTTP \(status)：\(preview.isEmpty ? "空响应" : preview)"
        case let .badResponse(text):
            return "无法解析 DeepSeek 响应：\(String(text.prefix(300)))"
        case let .upstream(text):
            return text
        }
    }
}

/// DeepSeek 网页端（chat.deepseek.com）内部接口的客户端。
///
/// 网页端接口没有公开文档，所以：
/// - 请求头按抓包结果补齐（x-client-* / x-device-*）；
/// - 响应解析放在 UpstreamEventParser 里做容错。
struct DeepSeekWebClient {
    struct UpstreamMessage {
        var role: String
        var content: String
    }

    struct Options {
        var model: String = "deepseek-chat"
        var thinkingEnabled: Bool = false
        var searchEnabled: Bool = false
        var temperature: Double = 0.7
        var maxTokens: Int = 4096
    }

    var baseURL: URL
    var accessToken: String
    var sessionCookie: String
    var deviceID: String
    var clientVersion: String

    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 上游对话接口路径
    static let chatPath = "/api/v0/chat/completions"

    var hasCredential: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeRequest(messages: [UpstreamMessage], options: Options, stream: Bool) throws -> URLRequest {
        guard hasCredential else { throw UpstreamError.missingCredential }
        guard let url = URL(string: baseURL.absoluteString + Self.chatPath) else {
            throw UpstreamError.badResponse("上游地址无效：\(baseURL.absoluteString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        request.setValue(clientVersion, forHTTPHeaderField: "x-client-version")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-client-timezone")
        request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
        request.setValue("iOS", forHTTPHeaderField: "x-device-os")
        request.setValue("iPhone", forHTTPHeaderField: "x-device-platform")
        request.setValue("iPhone", forHTTPHeaderField: "x-device-type")
        request.setValue("0", forHTTPHeaderField: "x-parent-app-id")

        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let cookie = sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        var payload: [String: Any] = [
            "model": options.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
            "thinking_enabled": options.thinkingEnabled,
            "search_enabled": options.searchEnabled,
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "id": UUID().uuidString.lowercased(),
            "conversation_id": UUID().uuidString.lowercased()
        ]
        if options.thinkingEnabled {
            payload["thinking_type"] = "enabled"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        return request
    }

    /// 流式请求：把上游 SSE 事件逐个吐出来
    func stream(messages: [UpstreamMessage], options: Options) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: messages, options: options, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var payload = Data()
                        for try await byte in bytes { payload.append(byte) }
                        throw UpstreamError.http(status: http.statusCode, body: String(decoding: payload, as: UTF8.self))
                    }

                    var parser = SSEParser()
                    for try await rawLine in bytes.lines {
                        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                        for event in parser.feed(line + "\n") {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.flush() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 非流式请求
    func complete(messages: [UpstreamMessage], options: Options) async throws -> String {
        let request = try makeRequest(messages: messages, options: options, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw UpstreamError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        let text = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw UpstreamError.badResponse(text)
        }
        let deltas = UpstreamEventParser.interpret(json: object)
        let content = deltas.compactMap { delta -> String? in
            if case let .content(text) = delta { return text }
            return nil
        }.joined()
        if content.isEmpty {
            throw UpstreamError.badResponse(text)
        }
        return content
    }
}
