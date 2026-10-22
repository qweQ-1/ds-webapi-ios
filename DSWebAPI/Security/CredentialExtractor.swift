import Foundation

/// 从网页端登录态里把 access token / session cookie 抠出来。
/// 纯逻辑，方便单测。
enum CredentialExtractor {
    static let tokenKeys = ["access_token", "accesstoken", "access-token", "id_token", "idtoken", "usertoken", "authtoken", "token"]

    /// 从 localStorage / sessionStorage 快照里找 access token
    static func findToken(in storage: [String: String]) -> String? {
        let lowercasedKeys = tokenKeys.map { $0.lowercased() }

        // 1) 先按 key 名精确匹配
        for (key, raw) in storage {
            guard lowercasedKeys.contains(key.lowercased()) else { continue }
            if let token = token(inBlob: raw) { return token }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeToken(trimmed) { return trimmed }
        }

        // 2) 再在所有 value 里递归找
        for (_, raw) in storage {
            if let token = token(inBlob: raw) { return token }
        }
        return nil
    }

    /// 从一段 JSON 文本里找 token
    static func token(inBlob raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return findToken(inJSON: object)
    }

    /// 递归找 token
    static func findToken(inJSON object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let lower = key.lowercased()
                if tokenKeys.contains(lower), let text = value as? String, !text.isEmpty {
                    return text
                }
            }
            for (_, value) in dict {
                if let found = findToken(inJSON: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findToken(inJSON: value) { return found }
            }
        }
        return nil
    }

    /// 判断是否像 token（JWT 一般以 eyJ 开头且带两个点）
    static func looksLikeToken(_ text: String) -> Bool {
        guard text.count > 20 else { return false }
        if text.hasPrefix("eyJ") { return true }
        let dots = text.reduce(0) { $1 == "." ? $0 + 1 : $0 }
        return dots >= 2
    }

    /// 把 HTTPCookie 数组拼成 Cookie 请求头（只保留 deepseek 域）
    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { $0.domain.lowercased().contains("deepseek") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
