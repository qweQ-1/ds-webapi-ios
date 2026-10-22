import SwiftUI

/// 接口页：把本机提供的 API 端点摆出来，方便复制到任何客户端里用
struct ApiView: View {
    @EnvironmentObject private var store: AppStore
    @State private var healthResult: String?

    private var port: Int { store.settings.port }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务状态") {
                    HStack {
                        Label {
                            Text(store.serverRunning ? "运行中" : "已停止")
                        } icon: {
                            Circle()
                                .fill(store.serverRunning ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                        }
                        Spacer()
                        if store.serverRunning {
                            Button("重启") { store.restartServer() }
                                .font(.callout)
                            Button("停止") { store.stopServer() }
                                .font(.callout)
                        } else {
                            Button("启动") { store.startServer() }
                                .font(.callout)
                        }
                    }
                    if let healthResult {
                        Text(healthResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("测试 /health") { checkHealth() }
                        .font(.callout)
                }

                Section("接入地址") {
                    CopyRow(title: "本机（App 内 / 本机客户端）", value: NetworkInfo.localBaseURL(port: port))
                    if let lan = NetworkInfo.lanBaseURL(port: port) {
                        CopyRow(title: "局域网（同一 Wi-Fi 的电脑 / 手机）", value: lan)
                    } else {
                        Text("未取到局域网 IP，请确认已连上 Wi-Fi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !store.settings.apiKey.isEmpty {
                        CopyRow(title: "本地 API Key", value: store.settings.apiKey)
                    }
                }

                Section("网页版聊天框") {
                    Text("本 App 内置了一个网页聊天框，它调用的正是上面这个接口。\n在同一个 Wi-Fi 下，用电脑浏览器打开下面的地址就能像用 DeepSeek 网页版一样聊天。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let ip = NetworkInfo.lanIPv4() {
                        Link(destination: URL(string: "http://\(ip):\(port)/")!) {
                            Label("打开网页聊天框", systemImage: "safari")
                        }
                    }
                    Link(destination: URL(string: "http://127.0.0.1:\(port)/")!) {
                        Label("本机打开", systemImage: "iphone")
                    }
                }

                Section("curl 示例") {
                    CopyRow(title: "流式对话", value: curlExample(stream: true))
                    CopyRow(title: "普通对话", value: curlExample(stream: false))
                }

                Section("OpenAI SDK 示例") {
                    CopyRow(title: "Python（OpenAI SDK）", value: pythonExample())
                    CopyRow(title: "Base URL", value: NetworkInfo.localBaseURL(port: port))
                }

                Section("运行日志") {
                    if store.log.isEmpty {
                        Text("暂无日志")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.log.prefix(40))) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.text)
                                    .font(.system(.caption2, design: .monospaced))
                                Text("\(line.stamp) · \(line.level.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("清空日志") { store.clearLog() }
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("接口")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func curlExample(stream: Bool) -> String {
        var lines: [String] = []
        lines.append("curl \(NetworkInfo.localBaseURL(port: port))/chat/completions \\")
        lines.append("  -H \"Content-Type: application/json\" \\")
        if !store.settings.apiKey.isEmpty {
            lines.append("  -H \"Authorization: Bearer \(store.settings.apiKey)\" \\")
        }
        let body = stream ? "true" : "false"
        lines.append("  -d '{\"model\": \"\(store.settings.model)\", \"stream\": \(body), \"messages\": [{\"role\": \"user\", \"content\": \"你好\"}]}'")
        return lines.joined(separator: "\n")
    }

    private func pythonExample() -> String {
        var code = "from openai import OpenAI\n\nclient = OpenAI(\n    base_url=\"\(NetworkInfo.localBaseURL(port: port))\","
        if store.settings.apiKey.isEmpty {
            code += "\n    api_key=\"not-needed\","
        } else {
            code += "\n    api_key=\"\(store.settings.apiKey)\","
        }
        code += "\n)\n\nstream = client.chat.completions.create(\n    model=\"\(store.settings.model)\",\n    messages=[{\"role\": \"user\", \"content\": \"你好\"}],\n    stream=True,\n)\nfor chunk in stream:\n    print(chunk.choices[0].delta.content or \"\", end=\"\")"
        return code
    }

    private func checkHealth() {
        guard store.serverRunning else {
            healthResult = "服务没启动"
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            healthResult = "地址无效"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { healthResult = text }
            } catch {
                DispatchQueue.main.async { healthResult = "请求失败：\(error.localizedDescription)" }
            }
        }
    }
}
