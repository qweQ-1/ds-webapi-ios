import SwiftUI

/// App 内置聊天框：走的是本机自己的 /v1/chat/completions，
/// 等于每次都在验证"网页端 → API"这条链路是通的。
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var input: String = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                if store.chat.isEmpty {
                    emptyState
                } else {
                    messageList
                }
                Divider()
                inputBar
            }
            .navigationTitle("网页端转 API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newConversation()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.serverRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(store.serverRunning ? "本地 API 运行中 · 127.0.0.1:\(store.settings.port)" : "本地 API 未启动")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if store.serverRunning == false {
                Button("启动") { store.startServer() }
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("这就是那个「被转换」的对话框")
                .font(.headline)
            Text("这里发出的每一句话，都会先请求本机 127.0.0.1 的 OpenAI 兼容接口，\n再由它转发给 DeepSeek 网页端。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !store.tokenPresent {
                Text("⚠️ 还没有 DeepSeek 登录凭证，去「设置」登录一下")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.chat) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: store.chat.count) {
                if let last = store.chat.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: store.chat.last?.content ?? "") {
                if let last = store.chat.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    Text(message.thinking)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(message.displayText)
                    .font(.callout)
                    .padding(10)
                    .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(message.failed ? Color.red : Color.primary)
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("说点什么…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }

        var history = store.chat.map { message in
            (role: message.role == .user ? "user" : "assistant", content: message.content)
        }
        history.append((role: "user", content: text))

        input = ""
        sending = true
        store.appendUserMessage(text)
        store.beginAssistantMessage()

        LocalAPIClient.send(messages: history,
                            port: store.settings.port,
                            apiKey: store.settings.apiKey,
                            model: store.settings.model,
                            conversationID: store.conversationID,
                            handlers: LocalAPIClient.StreamHandlers(
                                onThinking: { text in
                                    DispatchQueue.main.async { store.appendAssistantThinking(text) }
                                },
                                onContent: { text in
                                    DispatchQueue.main.async { store.appendAssistantText(text) }
                                },
                                onFinish: { error in
                                    DispatchQueue.main.async {
                                        store.finishAssistantMessage(error: error)
                                        sending = false
                                    }
                                }
                            ))
    }
}
