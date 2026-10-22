import Foundation

/// App 内聊天界面用的一条消息
struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user, assistant, system
    }

    let id = UUID()
    var role: Role
    var content: String
    /// 深度思考内容（reasoning / thinking）
    var thinking: String = ""
    var isStreaming: Bool = false
    var failed: Bool = false

    var displayText: String {
        content.isEmpty && !thinking.isEmpty ? "（只在思考中）" : content
    }
}

/// 一条日志
struct LogLine: Identifiable, Equatable {
    enum Level: String {
        case info = "INFO"
        case ok = "OK"
        case warn = "WARN"
        case error = "ERR"
    }

    let id = UUID()
    let time: Date
    let level: Level
    let text: String

    init(level: Level, text: String, time: Date = Date()) {
        self.level = level
        self.text = text
        self.time = time
    }

    var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: time)
    }
}

// MARK: - OpenAI 兼容的请求体

/// 客户端发给我们本地 API 的请求（OpenAI /v1/chat/completions 格式）
struct OpenAIChatRequest: Codable {
    struct Message: Codable {
        var role: String
        var content: String
        /// 多模态内容数组（本 App 只取纯文本）
        var contentParts: [ContentPart]?

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    struct ContentPart: Codable {
        var type: String?
        var text: String?
    }

    var model: String?
    var messages: [Message] = []
    var stream: Bool?
    var temperature: Double?
    var max_tokens: Int?
    var top_p: Double?
    var stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case max_tokens = "max_tokens"
        case top_p = "top_p"
        case stop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        max_tokens = try container.decodeIfPresent(Int.self, forKey: .max_tokens)
        top_p = try container.decodeIfPresent(Double.self, forKey: .top_p)
        stop = try container.decodeIfPresent([String].self, forKey: .stop)
    }

    /// 把 content 统一成纯文本（content 可能是 string，也可能是 [{type:text,text:...}]）
    static func plainText(_ raw: Any) -> String {
        if let text = raw as? String { return text }
        if let parts = raw as? [[String: Any]] {
            let joined = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                return nil
            }
            return joined.joined(separator: "\n")
        }
        return ""
    }
}
