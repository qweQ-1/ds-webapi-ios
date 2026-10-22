import Foundation
import Security

/// Keychain 存取：DeepSeek 网页端登录凭证不能明文落盘
enum KeychainStore {
    private static let service = "com.qweq-1.dswebapi"

    enum Account: String {
        case accessToken = "deepseek.accessToken"
        case sessionCookie = "deepseek.sessionCookie"
    }

    @discardableResult
    static func save(_ value: String, for account: Account) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: Account) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func deleteAll() {
        Account.allCases.forEach { _ = delete($0) }
    }
}

extension KeychainStore.Account: CaseIterable {}
