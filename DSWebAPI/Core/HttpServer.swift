import Foundation
import Network

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
}

/// 解析好的 HTTP 请求
struct HTTPRequest {
    var method: HTTPMethod = .get
    var path: String = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data = Data()

    func header(_ name: String) -> String {
        headers[name.lowercased()] ?? ""
    }

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }
}

/// 响应写出器：支持"先发头，再分块流式写，最后结束"
final class HTTPResponseWriter {
    private struct Pending {
        let data: Data
        let completion: (() -> Void)?
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var pending: [Pending] = []
    private var isWriting = false
    private var isClosed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// 发响应头
    func sendHead(status: Int = 200,
                  contentType: String = "application/json; charset=utf-8",
                  extraHeaders: [String: String] = [:]) {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = headers["Access-Control-Allow-Origin"] ?? "*"
        headers["Access-Control-Allow-Headers"] = headers["Access-Control-Allow-Headers"] ?? "Authorization, Content-Type, Accept, X-Requested-With"
        headers["Access-Control-Allow-Methods"] = headers["Access-Control-Allow-Methods"] ?? "GET, POST, PUT, DELETE, OPTIONS"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"

        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for key in headers.keys.sorted() {
            text += "\(key): \(headers[key] ?? "")\r\n"
        }
        text += "\r\n"
        write(Data(text.utf8))
    }

    /// 发一段内容
    func write(_ data: Data) {
        queue.async {
            guard !self.isClosed else { return }
            self.pending.append(Pending(data: data, completion: nil))
            self.drain()
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// 结束响应并断开连接
    func close() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.pending.append(Pending(data: Data(), completion: { [weak self] in
                self?.connection.cancel()
            }))
            self.drain()
        }
    }

    private func drain() {
        guard !isWriting, let next = pending.first else { return }
        pending.removeFirst()
        isWriting = true
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.isWriting = false
                next.completion?()
                self.drain()
            }
        }
        if next.data.isEmpty {
            finish()
        } else {
            connection.send(content: next.data, completion: .contentProcessed { _ in
                finish()
            })
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

/// 基于 Network.framework 的极简 HTTP/1.1 服务器（无第三方依赖）
final class HttpServer {
    typealias RequestHandler = (HTTPRequest, HTTPResponseWriter) -> Void

    private let queue = DispatchQueue(label: "com.qweq-1.dswebapi.http", qos: .userInitiated)
    private let handler: RequestHandler
    private var listener: NWListener?
    private(set) var boundPort: UInt16 = 0

    init(handler: @escaping RequestHandler) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 30
        }

        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: endpoint)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { state in
                if case .failed = state { connection.cancel() }
                if case .cancelled = state { connection.cancel() }
            }
            connection.start(queue: self.queue)
            let connectionHandler = HTTPConnectionHandler(connection: connection,
                                                        queue: self.queue,
                                                        handler: self.handler)
            connectionHandler.start()
        }
        listener.start(queue: queue)
        self.listener = listener
        self.boundPort = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit {
        stop()
    }
}

/// 单条连接：读请求 → 交给路由 → 关闭
private final class HTTPConnectionHandler {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HttpServer.RequestHandler
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HttpServer.RequestHandler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processIfComplete()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func processIfComplete() {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        let headData = buffer[buffer.startIndex..<separator.lowerBound]
        let headText = String(decoding: headData, as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let available = buffer.distance(from: buffer.startIndex, to: buffer.endIndex) - buffer.distance(from: buffer.startIndex, to: bodyStart)
        guard available >= contentLength else { return }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let parts = requestLine.split(separator: " ")
        let method = HTTPMethod(rawValue: parts.first.map(String.init) ?? "GET") ?? .get
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"

        var path = rawPath
        var query: [String: String] = [:]
        if let mark = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<mark])
            let queryString = String(rawPath[rawPath.index(after: mark)...])
            for pair in queryString.split(separator: "&") {
                let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = pieces.first else { continue }
                let value = pieces.count > 1 ? pieces[1].removingPercentEncoding ?? pieces[1] : ""
                query[key] = value
            }
        }

        var request = HTTPRequest()
        request.method = method
        request.path = path
        request.query = query
        request.headers = headers
        request.body = body

        let writer = HTTPResponseWriter(connection: connection, queue: queue)
        self.handler(request, writer)
    }
}
