import Foundation

/// DeepSeek 网页端（chat.deepseek.com）内部接口的客户端。
///
/// 协议要点（2026-10 从官方前端 bundle 里逆向确认）：
/// - 聊天接口：`POST /api/v0/chat/completion`（**单数** completion），SSE 流式返回
/// - 每次请求都要带 **工作量证明头**：`X-DS-PoW-Response: base64(JSON)`
/// - PoW 题目来自 `POST /api/v0/chat/create_pow_challenge`（未登录用
///   `POST /api/v0/users/create_guest_challenge`）
/// - PoW 算法 `DeepSeekHashV1`：找最小 n，使得
///   `SHA3-256("<salt>_<expireAt>_" + String(n))` 的 hex 等于 challenge
///   （difficulty 是搜索次数上限）
/// - 登录态 token 放在网页 localStorage 的 `userToken` 里，请求带 `Authorization: Bearer <token>`
/// - 一次只发一条 prompt，历史由 `chat_session_id` + `parent_message_id` 在服务端串起来
struct DeepSeekWebClient {

    struct UpstreamMessage {
        var role: String
        var content: String
    }

    struct Options {
        var modelType: String = "default"
        var thinkingEnabled: Bool = false
        var searchEnabled: Bool = false
        var temperature: Double = 0.7
        var maxTokens: Int = 4096
        /// 是否调用官方 /chat_session/create 建立真实网页端会话。
        var createServerSession: Bool = false
    }

    /// 网页端真实的 model_type：default / expert / vision。
    static func upstreamModelType(_ requested: String) -> String {
        switch requested {
        case "deepseek-reasoner": return "expert"
        case "deepseek-coder": return "default"
        default: return "default"
        }
    }

    /// 工作量证明题目
    ///
    /// 网页端的算法（DeepSeekHashV1）：
    ///   prefix = "<salt>_<expireAt>_"
    ///   找最小 n，使得 SHA3-256(prefix + String(n)) 的 hex == challenge
    ///   n 的搜索上限就是 difficulty
    struct Challenge {
        var algorithm: String = "DeepSeekHashV1"
        /// 目标哈希（hex）
        var challenge: String = ""
        /// 前缀里用的 salt（按网页端给的样子存字符串）
        var salt: String = ""
        /// 前缀里用的过期时间戳
        var expireAt: String = ""
        /// 迭代次数上限
        var difficulty: Int = 0
        var signature: String = ""

        /// 前缀
        var prefix: String { "\(salt)_\(expireAt)_" }

        /// 放回 PoW 头里的 salt（数字形态）
        var saltNumber: Any {
            if let value = Int(salt) { return value }
            if let value = Double(salt) { return value }
            return salt
        }

        /// 解题：找最小 n，使 SHA3-256(prefix + n) == challenge
        func solve(maxIterations: Int = 50_000_000) throws -> Int {
            guard algorithm == "DeepSeekHashV1" else {
                throw UpstreamError.powFailed("不支持的算法：\(algorithm)")
            }
            guard !challenge.isEmpty else {
                throw UpstreamError.powFailed("挑战内容为空")
            }
            guard let target = SHA3Digest.hexBytes(challenge) else {
                throw UpstreamError.powFailed("挑战不是合法的 hex")
            }
            let prefixBytes = Array(prefix.utf8)
            let limit = min(max(difficulty, 1), maxIterations)
            var digest = SHA3Digest()
            for index in 0..<limit {
                digest.reset()
                digest.update(prefixBytes)
                for byte in String(index).utf8 { digest.update(byte: byte) }
                if digest.finalizeEquals(target) { return index }
            }
            throw UpstreamError.powFailed("工作量证明没算出来（尝试 \(limit) 次）")
        }
    }

    var baseURL: URL
    var accessToken: String
    var sessionCookie: String
    var deviceID: String
    var deviceModel: String
    var clientVersion: String
    var clientLocale: String = "zh-CN"
    var clientPlatform: String = "web"
    var clientBundleID: String = "com.deepseek.chat"
    var timezoneOffsetSeconds: Int = 8 * 3600

    static let chatPath = "/api/v0/chat/completion"
    static let challengePath = "/api/v0/chat/create_pow_challenge"
    static let guestChallengePath = "/api/v0/users/create_guest_challenge"

    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    var isLoggedIn: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 请求头

    /// 不含 Cookie / Authorization 的通用客户端身份头。
    /// 业务请求与 HIF 风控令牌请求共用这一组设备身份信息。
    var clientHeaderFields: [String: String] {
        [
            "User-Agent": Self.defaultUserAgent,
            "x-client-locale": clientLocale,
            "x-client-version": clientVersion,
            "x-client-timezone-offset": String(timezoneOffsetSeconds),
            "x-client-platform": clientPlatform,
            "x-client-bundle-id": clientBundleID,
            "x-device-id": deviceID,
            "x-device-model": deviceModel
        ]
    }

    private func applyClientHeaders(_ request: inout URLRequest) {
        for (name, value) in clientHeaderFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let cookie = sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private func makeURL(_ path: String) throws -> URL {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + path) else {
            throw UpstreamError.badResponse("上游地址无效：\(baseURL.absoluteString)")
        }
        return url
    }

    /// 创建一次网页端会话（官方前端在首次聊天前调用）。
    /// 真实会话必须来自这个端点，而不是客户端随机 UUID。
    func createSession() async throws -> String {
        var request = URLRequest(url: try makeURL("/api/v0/chat_session/create"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyClientHeaders(&request)
        if isLoggedIn {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw UpstreamError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw UpstreamError.badResponse("创建会话响应不是合法 JSON")
        }
        if let message = Self.errorMessage(in: json) {
            throw UpstreamError.upstream(message)
        }
        guard let id = Self.chatSessionID(in: json) else {
            throw UpstreamError.badResponse("创建会话响应里没有 chat_session.id")
        }
        return id
    }

    /// 从响应里递归找 `chat_session.id`。
    static func chatSessionID(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let session = dict["chat_session"] as? [String: Any],
               let id = session["id"] as? String, !id.isEmpty {
                return id
            }
            for (_, value) in dict {
                if let found = chatSessionID(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = chatSessionID(in: value) { return found }
            }
        }
        return nil
    }

    // MARK: - 工作量证明

    /// 取一道 PoW 题目
    func fetchChallenge(guest: Bool) async throws -> Challenge {
        let path = guest ? Self.guestChallengePath : Self.challengePath
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyClientHeaders(&request)
        if !guest, isLoggedIn {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["target_path": Self.chatPath], options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw UpstreamError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let message = Self.errorMessage(in: json) {
            throw UpstreamError.challengeFailed(message)
        }
        guard let dict = Self.findChallenge(in: json) else {
            throw UpstreamError.challengeFailed("没拿到 PoW 题目：" + String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        return Self.parseChallenge(dict)
    }

    /// 组装 `X-DS-PoW-Response`（已登录）/ `X-DS-Guest-PoW-Response`（访客）
    func powHeaderValue(challenge: Challenge, answer: Int, guest: Bool) -> String {
        var payload: [String: Any]
        if guest {
            payload = ["salt": challenge.saltNumber, "answer": answer]
        } else {
            payload = [
                "algorithm": challenge.algorithm,
                "challenge": challenge.challenge,
                "salt": challenge.saltNumber,
                "answer": answer,
                "signature": challenge.signature,
                "target_path": Self.chatPath
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return ""
        }
        return data.base64EncodedString()
    }

    // MARK: - 聊天

    /// 构造一次聊天请求
    func makeCompletionRequest(prompt: String,
                                options: Options,
                                chatSessionID: String,
                                parentMessageID: String?,
                                powHeader: String,
                                hifHeaders: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(Self.chatPath))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyClientHeaders(&request)
        if isLoggedIn {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !powHeader.isEmpty {
            request.setValue(powHeader, forHTTPHeaderField: "X-DS-PoW-Response")
        }
        for (name, value) in hifHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }

        var body: [String: Any] = [
            "chat_session_id": chatSessionID,
            "model_type": options.modelType,
            "prompt": prompt,
            "ref_file_ids": [Any](),
            "thinking_enabled": options.thinkingEnabled,
            "search_enabled": options.searchEnabled,
            "action": NSNull(),
            "preempt": NSNull()
        ]
        if let parent = parentMessageID {
            body["parent_message_id"] = parent
        } else {
            body["parent_message_id"] = NSNull()
        }
        body["source"] = NSNull()
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        return request
    }

    /// 流式请求：把上游 SSE 事件逐个吐出来
    func stream(request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var payload = Data()
                        for try await byte in bytes { payload.append(byte) }
                        let text = String(decoding: payload, as: UTF8.self)
                        if let message = Self.errorMessage(in: Data(text.utf8)) {
                            throw UpstreamError.upstream(message)
                        }
                        throw UpstreamError.http(status: http.statusCode, body: text)
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

    // MARK: - 解析工具

    /// 把服务器返回的 challenge 字典转成 Challenge
    static func parseChallenge(_ dict: [String: Any]) -> Challenge {
        var challenge = Challenge()
        challenge.algorithm = (dict["algorithm"] as? String) ?? "DeepSeekHashV1"
        challenge.challenge = (dict["challenge"] as? String) ?? ""
        challenge.salt = jsString(dict["salt"])
        challenge.difficulty = intValue(dict["difficulty"]) ?? 0
        challenge.signature = (dict["signature"] as? String) ?? ""
        challenge.expireAt = jsString(dict["expireAt"] ?? dict["expire_at"])
        return challenge
    }

    /// 在任意 JSON 里找到带 salt/challenge 的那层字典
    static func findChallenge(in json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if dict["salt"] != nil, dict["challenge"] != nil || dict["difficulty"] != nil {
                return dict
            }
            for (_, value) in dict {
                if let found = findChallenge(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = findChallenge(in: value) { return found }
            }
        }
        return nil
    }

    /// 提取 DeepSeek 的错误码文案
    static func errorMessage(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = dict["error"] as? String { return message }
            if let message = dict["message"] as? String, dict["code"] != nil { return message }
            if let data = dict["data"] as? [String: Any] {
                if let message = errorMessage(in: data) { return message }
            }
            if let bizData = dict["biz_data"] as? [String: Any] {
                if let message = errorMessage(in: bizData) { return message }
            }
        }
        return nil
    }

    static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return errorMessage(in: json)
    }

    /// 尽量还原网页端 JavaScript 的字符串化规则
    static func jsString(_ any: Any?) -> String {
        guard let any else { return "" }
        if let text = any as? String { return text }
        if let number = any as? NSNumber {
            if CFNumberIsFloatType(number) {
                let value = number.doubleValue
                if value == value.rounded(), abs(value) < 1e21 {
                    return String(Int64(value))
                }
                return String(value)
            }
            return String(number.int64Value)
        }
        if let value = any as? Int { return String(value) }
        if let value = any as? Double { return String(Int64(value)) }
        return String(describing: any)
    }

    static func intValue(_ any: Any?) -> Int? {
        if let number = any as? Int { return number }
        if let number = any as? Double { return Int(number) }
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String { return Int(text) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let number = any as? Double { return number }
        if let number = any as? Int { return Double(number) }
        if let number = any as? NSNumber { return number.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }
}

enum UpstreamError: LocalizedError {
    case missingCredential
    case http(status: Int, body: String)
    case badResponse(String)
    case upstream(String)
    case powFailed(String)
    case challengeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "还没有 DeepSeek 网页端登录凭证，请在设置里登录或粘贴 access token"
        case let .http(status, body):
            let preview = String(body.prefix(300))
            return "DeepSeek 返回 HTTP \(status)：\(preview.isEmpty ? "空响应" : preview)"
        case let .badResponse(text):
            return "无法解析 DeepSeek 响应：\(String(text.prefix(300)))"
        case let .upstream(text):
            return text
        case let .powFailed(text):
            return "工作量证明失败：\(text)"
        case let .challengeFailed(text):
            return "拿不到 PoW 题目：\(text)"
        }
    }
}
