import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tokenInput: String = ""
    @State private var cookieInput: String = ""
    @State private var showLogin = false
    @State private var loginStatus: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("网页驱动模式（推荐）", isOn: $store.settings.useWebDriver)
                        .onChange(of: store.settings.useWebDriver) { _, _ in store.settings.save() }
                    Text(store.settings.useWebDriver
                         ? "API 请求交给「网页」页里的真实 DeepSeek 网页去发，我们只负责把它的回复转成 API。PoW、风控令牌、登录态都由官方网页自己处理，官方改内部协议也不影响。"
                         : "直连 DeepSeek 内部接口：自己算 PoW、自己带风控令牌。官方接口一改就容易失效，建议保持网页驱动模式。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("工作模式")
                }

                Section {
                    HStack {
                        Image(systemName: store.tokenPresent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(store.tokenPresent ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.tokenPresent ? "已登录 DeepSeek 网页端" : "还没有网页端凭证")
                                .font(.callout)
                            Text(store.tokenPresent ? "access token 已存在钥匙串" : "下面的按钮可以在 App 里直接登录网页版并自动抓取")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showLogin = true
                    } label: {
                        Label("在 App 内登录并自动抓取", systemImage: "safari")
                    }
                    if !loginStatus.isEmpty {
                        Text(loginStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("凭证")
                } footer: {
                    Text("DeepSeek 网页端的 token 相当于你的登录态，只存在本机钥匙串里，不会上传到任何第三方。")
                }

                Section("手动填写") {
                    TextField("access token", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存 access token") {
                        store.saveToken(tokenInput)
                        tokenInput = ""
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    TextField("session cookie（可选）", text: $cookieInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存 cookie") {
                        store.saveCookie(cookieInput)
                        cookieInput = ""
                    }
                    .disabled(cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("清除全部凭证", role: .destructive) {
                        store.saveToken("")
                        store.saveCookie("")
                    }
                }

                Section {
                    Picker("模型", selection: $store.settings.model) {
                        Text("deepseek-chat").tag("deepseek-chat")
                        Text("deepseek-reasoner").tag("deepseek-reasoner")
                        Text("deepseek-coder").tag("deepseek-coder")
                    }
                    Toggle("深度思考（reasoning）", isOn: $store.settings.thinkingEnabled)
                    Toggle("联网搜索", isOn: $store.settings.searchEnabled)
                    VStack(alignment: .leading) {
                        Text("温度：\(String(format: "%.2f", store.settings.temperature))")
                            .font(.caption)
                        Slider(value: $store.settings.temperature, in: 0...2, step: 0.1)
                    }
                    Stepper("最大长度：\(store.settings.maxTokens)", value: $store.settings.maxTokens, in: 256...32768, step: 256)
                    TextField("系统提示词（可选）", text: $store.settings.systemPrompt, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("模型与参数")
                }

                Section {
                    Stepper("端口：\(store.settings.port)", value: $store.settings.port, in: 1024...65535)
                    TextField("本地 API Key（留空＝不校验）", text: $store.settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("后台保活（静音音频）", isOn: $store.settings.keepAliveInBackground)
                    TextField("上游地址", text: $store.settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("改完端口或上游地址后，去「接口」页点一下「重启」。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("本地服务")
                }

                Section {
                    Toggle("记录上游原始事件", isOn: $store.settings.showRawStream)
                    Toggle("用官方接口建立真实会话", isOn: $store.settings.useServerSession)
                        .onChange(of: store.settings.useServerSession) { _ in store.settings.save() }
                    if store.settings.useServerSession {
                        Text("按官方前端流程调用 /chat_session/create 建立会话。若上游拒绝该端点，会自动退回本地会话。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设备 ID")
                            .font(.caption)
                        Text(AppSettings.deviceID)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("重置设备 ID") {
                        AppSettings.resetDeviceID()
                        store.append(.warn, "设备 ID 已重置")
                    }
                    Button("清空日志") { store.clearLog() }
                } header: {
                    Text("调试")
                }

                Section {
                    Text("DeepSeek Web → OpenAI API\n把 DeepSeek 网页版的对话框，变成一个任何客户端都能调的 API。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("版本 \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet { token, cookie, status in
                if !token.isEmpty {
                    store.saveToken(token)
                }
                if !cookie.isEmpty {
                    store.saveCookie(cookie)
                }
                loginStatus = status
            }
        }
    }
}

/// 登录页：内嵌 DeepSeek 网页，登录成功后自动抓凭证
struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCredential: (String, String, String) -> Void

    @State private var status: String = "正在打开 DeepSeek 网页…"
    @State private var manualToken: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
                LoginWebView(
                    onToken: { token in
                        onCredential(token, "", "已抓到 access token，可以关闭这个页面了")
                    },
                    onCookie: { cookie in
                        onCredential("", cookie, status)
                    },
                    onStatus: { text in
                        status = text
                    }
                )
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("没自动抓到？把网页里的 token 手动贴进来")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("access token", text: $manualToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                    Button("保存这个 token") {
                        let trimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCredential(trimmed, "", "已手动保存 access token")
                    }
                    .font(.caption)
                    .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("在电脑浏览器登录 DeepSeek 后按 F12 → Application → Local Storage → userToken，复制它的值")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .navigationTitle("登录 DeepSeek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
