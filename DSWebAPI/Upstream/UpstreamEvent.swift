import Foundation

/// 上游（DeepSeek 网页端）的一条增量，已经翻译成统一语义
enum UpstreamDelta: Equatable {
    /// 正文
    case content(String)
    /// 深度思考内容
    case thinking(String)
    /// 结束（带 finish_reason）
    case finish(String?)
    /// 出错
    case failure(String)
    /// 其它无法识别的负载（原样保留，调试用）
    case unknown(String)
}

/// 把上游各种可能的 SSE 负载统一翻译成 UpstreamDelta。
///
/// DeepSeek 网页端协议不是公开文档，而且改过几次，所以这里写得尽量"宽容"：
/// 同时兼容 OpenAI 风格（choices[].delta.content）、自研风格（顶层 content / text）
/// 以及思考内容字段（thinking_content / reasoning_content）。
enum UpstreamEventParser {

    /// 解析一个 SSE 事件，可能产出多条增量
    static func interpret(_ event: SSEEvent) -> [UpstreamDelta] {
        let raw = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return [] }

        if raw == "[DONE]" { return [.finish("stop")] }

        if let name = event.event?.lowercased() {
            if name == "error" { return [.failure(raw)] }
            if name == "finish" || name == "done" || name == "end" { return [.finish("stop")] }
            if name == "keepalive" || name == "ping" { return [] }
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else {
            // 不是 JSON，当成纯文本增量
            return [.content(raw)]
        }

        return interpret(json: json)
    }

    static func interpret(json: Any) -> [UpstreamDelta] {
        if let dict = json as? [String: Any] {
            return interpret(dict: dict)
        }
        if let array = json as? [Any] {
            return array.flatMap { interpret(json: $0) }
        }
        if let text = json as? String {
            return text.isEmpty ? [] : [.content(text)]
        }
        return []
    }

    private static func interpret(dict: [String: Any]) -> [UpstreamDelta] {
        var deltas: [UpstreamDelta] = []

        // 错误
        if let error = dict["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["type"] as? String) ?? "未知错误"
            deltas.append(.failure(message))
            return deltas
        }
        if let message = dict["error"] as? String {
            deltas.append(.failure(message))
            return deltas
        }

        // OpenAI 风格
        if let choices = dict["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    if let thinking = thinkingText(delta) { deltas.append(.thinking(thinking)) }
                    if let content = delta["content"] as? String, !content.isEmpty {
                        deltas.append(.content(content))
                    }
                }
                if let message = choice["message"] as? [String: Any] {
                    if let thinking = thinkingText(message) { deltas.append(.thinking(thinking)) }
                    if let content = message["content"] as? String, !content.isEmpty {
                        deltas.append(.content(content))
                    }
                }
                if let reason = choice["finish_reason"] as? String {
                    deltas.append(.finish(reason))
                }
            }
            return deltas
        }

        // 自研风格：顶层字段
        if let thinking = thinkingText(dict) { deltas.append(.thinking(thinking)) }

        if let content = dict["content"] as? String {
            if !content.isEmpty { deltas.append(.content(content)) }
        } else if let content = dict["text"] as? String {
            if !content.isEmpty { deltas.append(.content(content)) }
        } else if let content = dict["delta"] as? String {
            if !content.isEmpty { deltas.append(.content(content)) }
        } else if let content = dict["answer"] as? String {
            if !content.isEmpty { deltas.append(.content(content)) }
        }

        // 网页端有时把正文放在 choices 之外的对象里
        if let response = dict["response"] as? [String: Any] {
            deltas.append(contentsOf: interpret(dict: response))
        }

        if let reason = dict["finish_reason"] as? String {
            deltas.append(.finish(reason))
        } else if let status = dict["status"] as? String, status.lowercased() == "finished" {
            deltas.append(.finish("stop"))
        }

        if deltas.isEmpty, !dict.isEmpty {
            deltas.append(.unknown(summarize(dict)))
        }
        return deltas
    }

    /// 思考内容字段名各家叫法不一，这里统一找
    private static func thinkingText(_ dict: [String: Any]) -> String? {
        let keys = ["thinking_content", "reasoning_content", "reasoning", "thought"]
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func summarize(_ dict: [String: Any]) -> String {
        let keys = dict.keys.sorted().joined(separator: ",")
        let preview = dict
            .compactMap { key, value -> String? in
                guard let text = value as? String else { return nil }
                return "\(key)=\(String(text.prefix(40)))"
            }
            .joined(separator: " ")
        return "{\(keys)} \(preview)".trimmingCharacters(in: .whitespaces)
    }
}
