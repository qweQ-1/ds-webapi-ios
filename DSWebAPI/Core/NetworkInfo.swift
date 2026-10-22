import Foundation
import Darwin

enum NetworkInfo {
    /// 本机在局域网里的 IPv4 地址（给同一 Wi-Fi 下的其它设备用）
    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard interface.ifa_name.pointee == "en0" || interface.ifa_name.pointee == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &hostname, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: hostname)
            if value == "127.0.0.1" { continue }
            if interface.ifa_name.pointee == "en0" { return value }
            if fallback == nil { fallback = value }
        }
        return fallback
    }

    static func localBaseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/v1"
    }

    static func lanBaseURL(port: Int) -> String? {
        guard let ip = lanIPv4() else { return nil }
        return "http://\(ip):\(port)/v1"
    }
}
