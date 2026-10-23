import Foundation

/// App 的全部可配置项，存在 UserDefaults 里。
/// token 不在这里 —— 它单独放 Keychain（见 KeychainStore）。
struct AppSettings: Codable, Equatable {
    /// 本地 API 监听端口
    var port: Int = 8787
    /// 上游模型名（DeepSeek 网页端的 model id）
    var model: String = "deepseek-chat"
    /// 是否让 DeepSeek 开启深度思考（R1 风格）
    var thinkingEnabled: Bool = false
    /// 是否让 DeepSeek 联网搜索
    var searchEnabled: Bool = false
    /// 用官方 /chat_session/create 建立真实网页端会话（而非本地随机 UUID）
    var useServerSession: Bool = false
    /// 每次请求都带上这段系统提示词
    var systemPrompt: String = ""
    var temperature: Double = 0.7
    var maxTokens: Int = 4096
    /// 本地 API 的访问密钥：客户端必须带 Authorization: Bearer <key>。留空表示不校验。
    var apiKey: String = ""
    /// 切到后台时用静音音频保活，让 API 服务继续可用
    var keepAliveInBackground: Bool = true
    /// 上游 base url，出问题时可切
    var baseURL: String = "https://chat.deepseek.com"
    /// 把上游原始 SSE 打到日志里（协议变化时用来适配）
    var showRawStream: Bool = false
    /// 上游客户端版本头
    var clientVersion: String = "2.7.0"
    /// 设备型号（网页端要求带 x-device-model）
    var deviceModel: String = "iPhone"
    /// 客户端平台
    var clientPlatform: String = "web"
    /// 客户端 bundle id（网页端自己用的是 com.deepseek.chat）
    var clientBundleID: String = "com.deepseek.chat"
    /// 语言
    var clientLocale: String = "zh-CN"
    /// 时区偏移秒数
    var timezoneOffsetSeconds: Int = 28800

    private static let storageKey = "dswebapi.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            var fresh = AppSettings()
            fresh.port = 8787
            return fresh
        }
        if value.port <= 0 || value.port > 65535 { value.port = 8787 }
        if value.maxTokens <= 0 { value.maxTokens = 4096 }
        if value.temperature < 0 { value.temperature = 0 }
        if value.temperature > 2 { value.temperature = 2 }
        // 旧版占位客户端版本迁移到当前官方 Web 版本。
        if value.clientVersion == "20250101.99999" { value.clientVersion = "2.7.0" }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 稳定的设备 ID：网页端接口通常要求 x-device-id，重启 App 也要保持一致
    static var deviceID: String {
        let key = "dswebapi.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static func resetDeviceID() {
        UserDefaults.standard.set(UUID().uuidString, forKey: "dswebapi.deviceID")
    }
}
