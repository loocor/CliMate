import Foundation
import Network

enum SOCKS5Error: LocalizedError {
    case invalidPort(Int)
    case connectTimeout
    case proxyHandshakeFailed(String)
    case proxyAuthFailed
    case proxyConnectFailed(UInt8)
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case unsupportedURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p):
            "Invalid port: \(p)"
        case .connectTimeout:
            "Timed out connecting to proxy"
        case .proxyHandshakeFailed(let detail):
            "SOCKS5 handshake failed: \(detail)"
        case .proxyAuthFailed:
            "SOCKS5 proxy authentication failed"
        case .proxyConnectFailed(let rep):
            "SOCKS5 CONNECT failed (rep=\(rep))"
        case .invalidHTTPResponse:
            "Invalid HTTP response"
        case .httpStatus(let code, let body):
            "HTTP \(code): \(body)"
        case .unsupportedURL(let url):
            "Unsupported URL: \(url)"
        }
    }
}

actor SOCKS5HTTPClient {
    struct Target: Sendable {
        let host: String
        let port: Int
    }

    private let proxyHost: NWEndpoint.Host
    private let proxyPort: NWEndpoint.Port
    private let proxyUsername: String
    private let proxyPassword: String
    private let target: Target

    init(proxy: TailscaleProxyConfig, target: Target) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) else {
            throw SOCKS5Error.invalidPort(proxy.port)
        }
        self.proxyHost = NWEndpoint.Host(proxy.host)
        self.proxyPort = port
        self.proxyUsername = proxy.username
        self.proxyPassword = proxy.password
        self.target = target
    }

    func get(path: String) async throws -> Data {
        let request = buildRequest(method: "GET", path: path, headers: [:], body: nil)
        let (status, _, body) = try await sendOneShotHTTP(request)
        guard status == 200 else {
            throw SOCKS5Error.httpStatus(status, String(data: body, encoding: .utf8) ?? "<non-utf8>")
        }
        return body
    }

    func postJSON(path: String, jsonBody: Data) async throws -> Data {
        let headers = [
            "Content-Type": "application/json",
        ]
        let request = buildRequest(method: "POST", path: path, headers: headers, body: jsonBody)
        let (status, _, body) = try await sendOneShotHTTP(request)
        guard status == 200 else {
            throw SOCKS5Error.httpStatus(status, String(data: body, encoding: .utf8) ?? "<non-utf8>")
        }
        return body
    }

    func sse(path: String) async -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await openTunneledConnection()
                    defer { connection.cancel() }

                    let request = buildRequest(
                        method: "GET",
                        path: path,
                        headers: [
                            "Accept": "text/event-stream",
                            "Cache-Control": "no-cache",
                            "Connection": "keep-alive",
                        ],
                        body: nil
                    )
                    try await connection.sendData(request)

                    var buffer = Data()
                    // Read headers.
                    while true {
                        try Task.checkCancellation()
                        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                            let headersData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                            let rest = buffer.suffix(from: headerEnd.upperBound)
                            buffer = Data(rest)

                            guard let headerText = String(data: headersData, encoding: .utf8) else {
                                throw SOCKS5Error.invalidHTTPResponse
                            }
                            let status = parseHTTPStatus(headerText)
                            if status != 200 {
                                throw SOCKS5Error.httpStatus(status, headerText)
                            }
                            break
                        }

                        let chunk = try await connection.receiveSome()
                        if chunk.isEmpty {
                            throw SOCKS5Error.proxyHandshakeFailed("SSE connection closed before headers")
                        }
                        buffer.append(chunk)
                    }

                    // Stream lines.
                    var lineBuffer = LineBuffer()
                    if !buffer.isEmpty {
                        lineBuffer.append(buffer)
                    }

                    while true {
                        try Task.checkCancellation()

                        while let line = lineBuffer.popLine() {
                            continuation.yield(line)
                        }

                        let chunk = try await connection.receiveSome()
                        if chunk.isEmpty {
                            break
                        }
                        lineBuffer.append(chunk)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - HTTP

    private func buildRequest(method: String, path: String, headers: [String: String], body: Data?) -> Data {
        var lines: [String] = []
        lines.append("\(method) \(path) HTTP/1.1")
        lines.append("Host: \(target.host):\(target.port)")
        lines.append("User-Agent: CliMate-iOS/0.1.0")
        lines.append("Accept: */*")

        var merged = headers
        if let body {
            merged["Content-Length"] = String(body.count)
        }
        // Default: close to simplify parsing (except SSE overrides).
        if merged["Connection"] == nil {
            merged["Connection"] = "close"
        }

        for (k, v) in merged {
            lines.append("\(k): \(v)")
        }
        lines.append("") // header terminator
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    private func sendOneShotHTTP(_ request: Data) async throws -> (Int, [String: String], Data) {
        let connection = try await openTunneledConnection()
        defer { connection.cancel() }

        try await connection.sendData(request)

        var buffer = Data()
        while true {
            let chunk = try await connection.receiveSome()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            throw SOCKS5Error.invalidHTTPResponse
        }

        let headersData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        let bodyData = buffer.suffix(from: headerEnd.upperBound)
        guard let headerText = String(data: headersData, encoding: .utf8) else {
            throw SOCKS5Error.invalidHTTPResponse
        }

        let status = parseHTTPStatus(headerText)
        let headers = parseHTTPHeaders(headerText)

        if let contentLength = headers["content-length"].flatMap(Int.init) {
            let body = Data(bodyData.prefix(contentLength))
            return (status, headers, body)
        }

        return (status, headers, Data(bodyData))
    }

    private func parseHTTPStatus(_ headerText: String) -> Int {
        let firstLine = headerText.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2, let code = Int(parts[1]) {
            return code
        }
        return 0
    }

    private func parseHTTPHeaders(_ headerText: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in headerText.split(separator: "\n").dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = value
            }
        }
        return result
    }

    // MARK: - SOCKS5

    private func openTunneledConnection() async throws -> NWConnection {
        let connection = NWConnection(host: proxyHost, port: proxyPort, using: .tcp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false

            connection.stateUpdateHandler = { state in
                if finished { return }
                switch state {
                case .ready:
                    finished = true
                    cont.resume()
                case .failed(let err):
                    finished = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }

        do {
            try await socks5Handshake(connection: connection)
            try await socks5Connect(connection: connection, host: target.host, port: target.port)
        } catch {
            connection.cancel()
            throw error
        }

        return connection
    }

    private func socks5Handshake(connection: NWConnection) async throws {
        // VER=5, NMETHODS=2, METHODS=[no-auth, user/pass]
        let greeting = Data([0x05, 0x02, 0x00, 0x02])
        try await connection.sendData(greeting)

        let resp = try await connection.receiveExact(2)
        guard resp.count == 2, resp[0] == 0x05 else {
            throw SOCKS5Error.proxyHandshakeFailed("bad greeting response")
        }

        let method = resp[1]
        if method == 0x00 {
            return
        }
        if method != 0x02 {
            throw SOCKS5Error.proxyHandshakeFailed("unsupported method \(method)")
        }

        let u = Data(proxyUsername.utf8)
        let p = Data(proxyPassword.utf8)
        guard u.count <= 255, p.count <= 255 else {
            throw SOCKS5Error.proxyHandshakeFailed("credentials too long")
        }

        var auth = Data([0x01, UInt8(u.count)])
        auth.append(u)
        auth.append(UInt8(p.count))
        auth.append(p)

        try await connection.sendData(auth)
        let authResp = try await connection.receiveExact(2)
        guard authResp.count == 2, authResp[0] == 0x01, authResp[1] == 0x00 else {
            throw SOCKS5Error.proxyAuthFailed
        }
    }

    private func socks5Connect(connection: NWConnection, host: String, port: Int) async throws {
        guard port >= 0, port <= 65535 else {
            throw SOCKS5Error.invalidPort(port)
        }

        var req = Data([0x05, 0x01, 0x00]) // VER, CMD=CONNECT, RSV
        req.append(encodeAddress(host))
        req.append(UInt8((port >> 8) & 0xff))
        req.append(UInt8(port & 0xff))

        try await connection.sendData(req)

        // First 4 bytes: VER, REP, RSV, ATYP
        let head = try await connection.receiveExact(4)
        guard head.count == 4, head[0] == 0x05 else {
            throw SOCKS5Error.proxyHandshakeFailed("bad connect response")
        }

        let rep = head[1]
        if rep != 0x00 {
            throw SOCKS5Error.proxyConnectFailed(rep)
        }

        // Consume BND.ADDR + BND.PORT.
        let atyp = head[3]
        switch atyp {
        case 0x01: // IPv4
            _ = try await connection.receiveExact(4 + 2)
        case 0x04: // IPv6
            _ = try await connection.receiveExact(16 + 2)
        case 0x03: // DOMAIN
            let len = try await connection.receiveExact(1)
            let n = Int(len[0])
            _ = try await connection.receiveExact(n + 2)
        default:
            throw SOCKS5Error.proxyHandshakeFailed("unknown ATYP \(atyp)")
        }
    }

    private func encodeAddress(_ host: String) -> Data {
        if let ip4 = IPv4Address(host) {
            return Data([0x01]) + ip4.rawValue
        }
        if let ip6 = IPv6Address(host) {
            return Data([0x04]) + ip6.rawValue
        }
        let bytes = Data(host.utf8)
        var out = Data([0x03, UInt8(min(bytes.count, 255))])
        out.append(bytes.prefix(255))
        return out
    }
}

private extension NWConnection {
    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func receiveSome(max: Int = 64 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if isComplete {
                    cont.resume(returning: Data())
                    return
                }
                cont.resume(returning: content ?? Data())
            }
        }
    }

    func receiveExact(_ n: Int) async throws -> Data {
        var out = Data()
        while out.count < n {
            let chunk = try await receiveSome(max: n - out.count)
            if chunk.isEmpty {
                throw SOCKS5Error.proxyHandshakeFailed("unexpected EOF")
            }
            out.append(chunk)
        }
        return out
    }
}

private struct LineBuffer {
    private var buf = Data()

    mutating func append(_ data: Data) {
        buf.append(data)
    }

    mutating func popLine() -> String? {
        guard let range = buf.firstRange(of: Data([0x0a])) else { // \n
            return nil
        }
        let lineData = buf.subdata(in: buf.startIndex..<range.lowerBound)
        buf.removeSubrange(buf.startIndex..<range.upperBound)
        let trimmed = lineData.last == 0x0d ? lineData.dropLast() : lineData[...]
        return String(data: Data(trimmed), encoding: .utf8)
    }
}
