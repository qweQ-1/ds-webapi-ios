import Foundation

/// App 内置聊天框用的客户端：调用本机自己的 /v1/chat/completions，
/// 相当于用真实客户端走一遍我们提供的 API。
enum LocalAPIClient {
    struct StreamHandlers {
        var onThinking: (String) -> Void = { _ in }
        var onContent: (String) -> Void = { _ in }
        var onFinish: (String?) -> Void = { _ in }
    }

    static func chatURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    }

    /// 发起一次流式对话
    static func send(messages: [(role: String, content: String)],
                     port: Int,
                     apiKey: String,
                     model: String,
                     handlers: StreamHandlers) {
        var request = URLRequest(url: chatURL(port: port))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    var payload = Data()
                    for try await byte in bytes { payload.append(byte) }
                    handlers.onFinish(String(decoding: payload, as: UTF8.self))
                    return
                }

                var parser = SSEParser()
                for try await rawLine in bytes.lines {
                    let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                    for event in parser.feed(line + "\n") {
                        guard event.data != "[DONE]" else { continue }
                        guard let data = event.data.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                              let dict = object as? [String: Any] else { continue }

                        if let error = dict["error"] as? [String: Any] {
                            handlers.onFinish((error["message"] as? String) ?? "未知错误")
                            continue
                        }
                        guard let choices = dict["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            handlers.onThinking(reasoning)
                        }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            handlers.onContent(content)
                        }
                    }
                }
                handlers.onFinish(nil)
            } catch {
                handlers.onFinish(error.localizedDescription)
            }
        }
    }
}
