import Foundation
import SwiftUI

/// 全局状态：设置、凭证、服务状态、日志、聊天记录
final class AppStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if oldValue != settings { settings.save() }
        }
    }

    @Published private(set) var log: [LogLine] = []
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var serverRunning = false
    @Published private(set) var tokenPresent = false
    @Published private(set) var cookiePresent = false
    @Published var statusMessage: String?

    private var bridge: BridgeServer?

    init() {
        settings = AppSettings.load()
        refreshCredentialState()
    }

    // MARK: - 凭证

    func refreshCredentialState() {
        tokenPresent = !KeychainStore.read(.accessToken).isEmpty
        cookiePresent = !KeychainStore.read(.sessionCookie).isEmpty
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(.accessToken)
        } else {
            KeychainStore.save(trimmed, for: .accessToken)
        }
        refreshCredentialState()
        append(.ok, trimmed.isEmpty ? "已清除 access token" : "已保存 access token")
    }

    func saveCookie(_ cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(.sessionCookie)
        } else {
            KeychainStore.save(trimmed, for: .sessionCookie)
        }
        refreshCredentialState()
        append(.ok, trimmed.isEmpty ? "已清除 session cookie" : "已保存 session cookie")
    }

    func accessToken() -> String { KeychainStore.read(.accessToken) }
    func sessionCookie() -> String { KeychainStore.read(.sessionCookie) }

    // MARK: - 服务

    func startServer() {
        guard bridge == nil else { return }
        let server = BridgeServer(settingsProvider: { [weak self] in self?.settings ?? AppSettings() },
                                 tokenProvider: { [weak self] in self?.accessToken() ?? "" },
                                 cookieProvider: { [weak self] in self?.sessionCookie() ?? "" },
                                 logger: { [weak self] level, text in self?.append(level, text) })
        do {
            try server.start()
            bridge = server
            serverRunning = true
            statusMessage = "运行中"
        } catch {
            serverRunning = false
            statusMessage = nil
            append(.error, "启动失败：\(error.localizedDescription)")
        }
    }

    func stopServer() {
        bridge?.stop()
        bridge = nil
        serverRunning = false
        statusMessage = nil
    }

    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startServer()
        }
    }

    // MARK: - 日志

    func append(_ level: LogLine.Level, _ text: String) {
        let line = LogLine(level: level, text: text)
        DispatchQueue.main.async {
            self.log.insert(line, at: 0)
            if self.log.count > 400 {
                self.log.removeLast(self.log.count - 400)
            }
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - 聊天

    func clearChat() {
        chat.removeAll()
    }

    func appendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.append(ChatMessage(role: .user, content: trimmed))
    }

    func beginAssistantMessage() {
        chat.append(ChatMessage(role: .assistant, content: "", isStreaming: true))
    }

    func appendAssistantText(_ text: String) {
        guard !chat.isEmpty else { return }
        chat[chat.count - 1].content += text
    }

    func appendAssistantThinking(_ text: String) {
        guard !chat.isEmpty else { return }
        chat[chat.count - 1].thinking += text
    }

    func finishAssistantMessage(error: String?) {
        guard !chat.isEmpty else { return }
        chat[chat.count - 1].isStreaming = false
        if let error = error {
            chat[chat.count - 1].failed = true
            if chat[chat.count - 1].content.isEmpty {
                chat[chat.count - 1].content = error
            }
        }
    }
}
