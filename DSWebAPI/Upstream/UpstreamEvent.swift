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
/// 网页端协议不是公开文档，而且改过几次，所以这里写得尽量"宽容"：
///
/// 1. **最新官方 path/op 操作符格式**（2026-10 从 bundle 逆向）：
///    ```json
///    {"p":"response/fragments/-1/content","o":"APPEND","v":"，"}   // 增量追加
///    {"p":"response/fragments/0/type","o":"SET","v":"THINK"}      // 设置
///    {"p":"response","o":"BATCH","v":[{...子操作...}]}            // 批量
///    {"v":{"response":{...}}}                                     // 初始快照
///    ```
///    - `p` 与 `o` 跨事件持久化：后续事件可省略，沿用上一次的值。
///    - `o` 默认 `SET`；`APPEND` 对字符串是 `+=`；`BATCH` 递归分解子项。
///    - 正文在路径 `response/fragments/-1/content`（或 index 位置）下，靠 `v` 携带。
///
/// 2. **旧版 OpenAI 风格**：`choices[].delta.content`、顶层 `content`/`text` 等。
enum UpstreamEventParser {

    /// 解析一个 SSE 事件，可能产出多条增量
    static func interpret(_ event: SSEEvent) -> [UpstreamDelta] {
        let raw = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return [] }

        if raw == "[DONE]" { return [.finish("stop")] }

        let name = event.event?.lowercased() ?? ""
        if name == "error" { return [.failure(raw)] }
        if name == "finish" { return [.finish("stop")] }
        if name == "close" {
            if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]),
               let dict = json as? [String: Any],
               let reason = dict["close_reason"] as? String {
                return [.finish(reason == "success" ? "stop" : reason)]
            }
            return [.finish("stop")]
        }
        if name == "ready" || name == "toast" || name == "title" || name == "hint" { return [] }
        if name == "updateSession" || name == "updateParentMessage" || name == "updateFile" { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else {
            // 不是 JSON，当成纯文本增量
            return [.content(raw)]
        }

        return interpret(json: json)
    }

    static func interpret(json: Any) -> [UpstreamDelta] {
        if let dict = json as? [String: Any] {
            // 官方 path/op 操作符格式优先
            let ops = interpretOps(dict)
            if !ops.isEmpty { return ops }
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

    // MARK: - 官方 path/op 操作符格式

    /// 尝试按官方 path/op 格式解释一个事件。非该格式返回空数组，交回通用解析。
    private static func interpretOps(_ dict: [String: Any]) -> [UpstreamDelta] {
        // 初始快照：{"v": {"response": {...}}} —— 里面带 message_id / fragments
        if let value = dict["v"] as? [String: Any], dict["p"] == nil, dict["o"] == nil {
            return interpretSnapshot(value)
        }

        guard dict["p"] != nil || dict["o"] != nil || dict["v"] != nil else {
            return []
        }

        let op = (dict["o"] as? String) ?? "SET"
        let path = (dict["p"] as? String) ?? ""
        let value = dict["v"]
        // fragment 类型：官方可能用 f / type 字段标识 THINK / RESPONSE
        let fragmentType = (dict["f"] as? String) ?? (dict["type"] as? String) ?? ""

        // BATCH：递归分解子操作，父路径作为前缀
        if op == "BATCH", let items = value as? [[String: Any]] {
            var out: [UpstreamDelta] = []
            for item in items {
                var child = item
                if !path.isEmpty {
                    if let subPath = child["p"] as? String, !subPath.isEmpty {
                        child["p"] = (path + "/" + subPath)
                    } else {
                        child["p"] = path
                    }
                }
                out.append(contentsOf: interpretOps(child))
            }
            return out
        }

        // 归一化路径：去掉开头的 response/ 与结尾的响应控制段
        let norm = normalizePath(path)

        // 正文 / 思考内容提取
        if let text = value as? String, !text.isEmpty {
            if norm.contains("content") && !norm.contains("search") {
                if fragmentType.uppercased() == "THINK" || isThinkingPath(norm) {
                    return [.thinking(text)]
                }
                return [.content(text)]
            }
            if norm.contains("elapsed_secs") || norm.contains("search") {
                return []
            }
            // 其它 path 下的字符串值，暂不当作正文
            return []
        }

        // value 是对象（如 fragment 快照）时，从里面挖正文
        if let fragment = value as? [String: Any] {
            var out: [UpstreamDelta] = []
            if let type = fragment["type"] as? String, type == "THINK",
               let thinking = fragment["content"] as? String, !thinking.isEmpty {
                out.append(.thinking(thinking))
            }
            if let type = fragment["type"] as? String, type == "RESPONSE",
               let content = fragment["content"] as? String, !content.isEmpty {
                out.append(.content(content))
            }
            return out
        }

        // 结束信号
        if let status = value as? String, status.uppercased() == "FINISHED" {
            return [.finish("stop")]
        }
        if let status = value as? String, status.uppercased() == "INCOMPLETE" {
            return [.finish("length")]
        }

        return []
    }

    /// 初始快照 {"v":{"response":{...}}} 里直接挖正文/思考。
    private static func interpretSnapshot(_ value: [String: Any]) -> [UpstreamDelta] {
        guard let response = value["response"] as? [String: Any] else {
            // 也许整个 value 就是 fragments 数组
            return extractFrom(value)
        }
        return extractFrom(response)
    }

    /// 从任意包含 fragments 的字典里挖正文/思考（兼容旧版 fragments 数组）。
    private static func extractFrom(_ dict: [String: Any]) -> [UpstreamDelta] {
        var out: [UpstreamDelta] = []
        if let fragments = dict["fragments"] as? [[String: Any]] {
            for fragment in fragments {
                if let type = fragment["type"] as? String, type == "THINK",
                   let thinking = fragment["content"] as? String, !thinking.isEmpty {
                    out.append(.thinking(thinking))
                }
                if let content = fragment["content"] as? String, !content.isEmpty,
                   let type = fragment["type"] as? String, type != "THINK" {
                    out.append(.content(content))
                }
            }
        }
        if let status = dict["status"] as? String, status.uppercased() == "FINISHED" {
            out.append(.finish("stop"))
        }
        return out
    }

    /// 判断某路径是否指向思考片段。
    private static func isThinkingPath(_ norm: String) -> Bool {
        norm.contains("THINK") || norm.contains("thinking")
    }

    /// 把官方路径归一化，方便匹配。
    private static func normalizePath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "response" }
        return parts.joined(separator: "/")
    }

    // MARK: - 旧版 / 通用解析

    private static func interpret(dict: [String: Any]) -> [UpstreamDelta] {
        var deltas: [UpstreamDelta] = []

        if let error = dict["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? (error["type"] as? String) ?? "未知错误"
            deltas.append(.failure(message))
            return deltas
        }
        if let message = dict["error"] as? String {
            deltas.append(.failure(message))
            return deltas
        }
        if let code = DeepSeekWebClient.intValue(dict["code"]), code != 0, code != 200 {
            let message = (dict["message"] as? String) ?? (dict["biz_msg"] as? String) ?? "DeepSeek 返回错误码 \(code)"
            deltas.append(.failure(message))
            return deltas
        }

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

        if let wrapped = dict["biz_data"] as? [String: Any] {
            deltas.append(contentsOf: interpret(dict: wrapped))
        }
        if let wrapped = dict["data"] as? [String: Any] {
            deltas.append(contentsOf: interpret(dict: wrapped))
        }

        if let thinking = thinkingText(dict) { deltas.append(.thinking(thinking)) }

        var contentText: String?
        for key in ["content", "text", "delta", "answer", "chunk"] {
            if let value = dict[key] as? String, !value.isEmpty {
                contentText = value
                break
            }
        }
        if let fragments = dict["fragments"] as? [[String: Any]] {
            for fragment in fragments {
                if let thinking = thinkingText(fragment) {
                    deltas.append(.thinking(thinking))
                }
                if let text = fragment["content"] as? String, !text.isEmpty {
                    deltas.append(.content(text))
                }
            }
        }
        if let text = contentText, !text.isEmpty {
            if let isThink = dict["is_think"] as? Bool, isThink {
                deltas.append(.thinking(text))
            } else {
                deltas.append(.content(text))
            }
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