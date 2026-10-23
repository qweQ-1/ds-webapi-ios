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
            // 网页端的 userToken 可能是不透明的字符串，不是 JWT，也要认
            if !trimmed.isEmpty, !trimmed.hasPrefix("{") { return trimmed }
        }

        // 2) 再在所有 value 里递归找
        for (_, raw) in storage {
            if let token = token(inBlob: raw) { return token }
        }

        // 3) 兜底：任何长得像 JWT 的值
        for (_, raw) in storage {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("eyJ"), trimmed.contains(".") { return trimmed }
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

        // 官方 storage 处理类（p.H）写入的是 { "value": <token>, "__version": ... } 包裹格式。
        // 比如 userToken 键的原始值可能是 {"value":"<真实token>","__version":"0"}。
        // 优先剥开这层再看；剥出的值要像个 token（可能是不透明长字符串，也可能 JWT），
        // 否则可能是无关字段，继续通用扫描。
        if let wrapped = unwrapOfficialTokenEnvelope(object),
           plausiblyToken(wrapped) {
            return wrapped
        }
        return findToken(inJSON: object)
    }

    /// 官方前端把鉴权值写成 `{ "value": ..., "__version": ... }`（带版本号标记的信封）。
    /// 递归剥掉这层外壳，直到拿到最内层的字符串 token。
    static func unwrapOfficialTokenEnvelope(_ object: Any) -> String? {
        if let dict = object as? [String: Any] {
            // 命中官方信封：要求带 value + __version 两个标记，取内层 value
            if let value = dict["value"], dict["__version"] != nil {
                if let text = value as? String, !text.isEmpty { return text }
                // value 本身又是个对象（可能再次包裹或直接是 {"access_token":...}）
                if let nested = unwrapOfficialTokenEnvelope(value) { return nested }
            }
            // 某些账号形态下 value 缺失或没有 __version，改用递归通用扫描
            for (_, sub) in dict where sub is [String: Any] {
                if let nested = unwrapOfficialTokenEnvelope(sub) { return nested }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let nested = unwrapOfficialTokenEnvelope(item) { return nested }
            }
        }
        return nil
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

    /// 更宽松的可信判断：DeepSeek 网页端的 userToken 是不透明长字符串，
    /// 不一定是 JWT。只要非空、不是 JSON 结构、长度达标就算疑似 token。
    static func plausiblyToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeToken(trimmed) { return true }
        guard trimmed.count >= 20 else { return false }
        let first = trimmed.first ?? " "
        // 排除 JSON 对象/数组外壳
        return first != "{" && first != "[" && first != "\""
    }

    /// 把 HTTPCookie 数组拼成 Cookie 请求头（只保留 deepseek 域）
    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { $0.domain.lowercased().contains("deepseek") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
