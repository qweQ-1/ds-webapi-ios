import Foundation

/// 一个 SSE 事件
struct SSEEvent: Equatable {
    var id: String?
    var event: String?
    var data: String
    var retry: String?
}

/// 增量解析 SSE 文本流。纯逻辑，方便单测。
struct SSEParser {
    private var buffer = ""

    /// 喂入一段原始文本，返回解析完整的事件
    mutating func feed(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []

        while true {
            let separatorRange = Self.findSeparator(in: buffer)
            guard let separatorRange else { break }
            let block = String(buffer[buffer.startIndex..<separatorRange.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<separatorRange.upperBound)
            if let event = Self.parseBlock(block) {
                events.append(event)
            }
        }
        return events
    }

    /// 流结束时把残留内容也算作一个事件
    mutating func flush() -> [SSEEvent] {
        guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let block = buffer
        buffer = ""
        return Self.parseBlock(block).map { [$0] } ?? []
    }

    /// 找事件分隔符：空行（\n\n 或 \r\n\r\n）
    private static func findSeparator(in text: String) -> Range<String.Index>? {
        let lf = text.range(of: "\n\n")
        let crlf = text.range(of: "\r\n\r\n")
        switch (lf, crlf) {
        case let (a?, b?):
            return a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        default:
            return nil
        }
    }

    /// 解析一段事件块
    static func parseBlock(_ block: String) -> SSEEvent? {
        var id: String?
        var name: String?
        var dataLines: [String] = []
        var retry: String?

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue }  // 注释/心跳

            if let colon = line.firstIndex(of: ":") {
                let field = String(line[line.startIndex..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                switch field {
                case "data": dataLines.append(value)
                case "event": name = value
                case "id": id = value
                case "retry": retry = value
                default: break
                }
            } else {
                // 没有冒号：整行当作 data
                dataLines.append(line)
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(id: id, event: name, data: dataLines.joined(separator: "\n"), retry: retry)
    }
}
