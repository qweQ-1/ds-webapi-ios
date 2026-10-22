import Foundation

/// 生成 OpenAI 兼容的 SSE 分片与完整响应
struct OpenAIEnvelope {
    let id: String
    let model: String
    let created: Int

    init(model: String, id: String = "chatcmpl-" + String(UUID().uuidString.prefix(24)), created: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.model = model
        self.created = created
    }

    /// 流式分片
    func chunk(delta: [String: Any], finishReason: String?) -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let reason = finishReason {
            choice["finish_reason"] = reason
        } else {
            choice["finish_reason"] = NSNull()
        }
        let payload: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [choice]
        ]
        return Self.json(payload)
    }

    /// 非流式完整响应
    func completion(content: String, thinking: String, finishReason: String) -> String {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !thinking.isEmpty { message["reasoning_content"] = thinking }
        let payload: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason
            ]],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0
            ]
        ]
        return Self.json(payload)
    }

    /// 错误响应
    static func error(_ message: String, code: String = "invalid_request_error") -> String {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": code,
                "code": code
            ]
        ]
        return json(payload)
    }

    static func json(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
