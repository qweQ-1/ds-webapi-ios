import Foundation

/// DeepSeek 网页端的 HIF 风控令牌提供器。
///
/// 官方 Web 前端会并行轮询 `hif-leim` / `hif-dliq` 两个无鉴权端点，
/// 把返回的令牌缓存到 localStorage，并在 SSE 聊天请求上通过
/// `x-hif-leim` / `x-hif-dliq` 回传。缺少这些头时，最新版上游可能把请求
/// 判定为非官方客户端。
///
/// 这里按 App 的稳定设备 ID 获取并缓存令牌；取不到时跳过对应头，不阻断聊天。
actor HIFTokenProvider {

    enum Kind: String, CaseIterable {
        case leim
        case dliq

        var headerName: String {
            switch self {
            case .leim: return "x-hif-leim"
            case .dliq: return "x-hif-dliq"
            }
        }

        var endpoint: URL {
            switch self {
            case .leim: return URL(string: "https://hif-leim.deepseek.com/query")!
            case .dliq: return URL(string: "https://hif-dliq.deepseek.com/query")!
            }
        }
    }

    private struct CachedToken {
        var value: String?
        var expiresAt: Date?
        var nextAttemptAt: Date?
        var failures: Int = 0
    }

    private struct FetchedToken {
        var value: String
        var ttl: TimeInterval
    }

    private var caches: [Kind: CachedToken]

    init() {
        caches = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, CachedToken()) })
    }

    /// 返回当前可用的两个风控头。任何一个端点不可用时，只跳过对应头。
    func headers(baseHeaders: [String: String]) async -> [String: String] {
        async let leimValue = token(for: .leim, baseHeaders: baseHeaders)
        async let dliqValue = token(for: .dliq, baseHeaders: baseHeaders)

        let leim = await leimValue
        let dliq = await dliqValue
        var result: [String: String] = [:]
        if let leim, !leim.isEmpty { result[Kind.leim.headerName] = leim }
        if let dliq, !dliq.isEmpty { result[Kind.dliq.headerName] = dliq }
        return result
    }

    private func token(for kind: Kind, baseHeaders: [String: String]) async -> String? {
        let now = Date()
        let cached = caches[kind] ?? CachedToken()

        if let expiresAt = cached.expiresAt, expiresAt > now, let value = cached.value {
            return value
        }
        if let nextAttemptAt = cached.nextAttemptAt, nextAttemptAt > now {
            return cached.value
        }

        do {
            let fetched = try await Self.fetch(kind: kind, baseHeaders: baseHeaders)
            let usableTTL = max(fetched.ttl - 30, 1)
            caches[kind] = CachedToken(value: fetched.value,
                                      expiresAt: now.addingTimeInterval(usableTTL),
                                      nextAttemptAt: nil,
                                      failures: 0)
            return fetched.value
        } catch {
            let failures = cached.failures + 1
            caches[kind] = CachedToken(value: cached.value,
                                      expiresAt: cached.expiresAt,
                                      nextAttemptAt: now.addingTimeInterval(Self.failureBackoff(failures: failures)),
                                      failures: failures)
            // 与官方前端一致：取令牌失败不阻断业务请求。
            return cached.value
        }
    }

    private static func fetch(kind: Kind, baseHeaders: [String: String]) async throws -> FetchedToken {
        var request = URLRequest(url: kind.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://chat.deepseek.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://chat.deepseek.com", forHTTPHeaderField: "Origin")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        for (name, value) in baseHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HIFTokenError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HIFTokenError.httpStatus(http.statusCode)
        }
        let ttl = ttlSeconds(fromHeader: http.value(forHTTPHeaderField: "x-hif-ttl"))
        let value = try parseValue(in: data)
        return FetchedToken(value: value, ttl: ttl)
    }

    /// 解析官方信封：`data.biz_data.value`。
    static func parseValue(in data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let envelope = root as? [String: Any],
              let payload = envelope["data"] as? [String: Any] else {
            throw HIFTokenError.invalidResponse
        }
        let bizCode = (payload["biz_code"] as? NSNumber)?.intValue ?? 0
        guard bizCode == 0 else {
            let message = (payload["biz_msg"] as? String) ?? "未知错误"
            throw HIFTokenError.business(code: bizCode, message: message)
        }
        guard let bizData = payload["biz_data"] as? [String: Any],
              let value = bizData["value"] as? String,
              !value.isEmpty else {
            throw HIFTokenError.emptyValue
        }
        return value
    }

    static func ttlSeconds(fromHeader header: String?) -> TimeInterval {
        guard let header,
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0 else {
            return 600
        }
        return seconds
    }

    /// 失败退避：30 秒起步，指数增长，10 分钟封顶。
    static func failureBackoff(failures: Int) -> TimeInterval {
        let exponent = min(max(failures - 1, 0), 5)
        return min(30 * Double(1 << exponent), 600)
    }
}

enum HIFTokenError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case business(code: Int, message: String)
    case emptyValue

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "HIF 响应格式无效"
        case let .httpStatus(code): return "HIF 端点返回 HTTP \(code)"
        case let .business(code, message): return "HIF 业务错误 \(code)：\(message)"
        case .emptyValue: return "HIF 响应里没有令牌"
        }
    }
}
