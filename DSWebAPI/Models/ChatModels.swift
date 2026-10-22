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
