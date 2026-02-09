import Foundation

struct PendingApproval: Identifiable {
    let id: Int
    let method: String
    let summary: String
}

@MainActor
final class CodexClient: ObservableObject {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var transcript: String = ""
    @Published var pendingApproval: PendingApproval?
    @Published var lastError: String?

    private(set) var lastURL: String? = nil

    private var eventsTask: Task<Void, Never>?

    private var baseURL: URL?
    private var httpClient: SOCKS5HTTPClient?

    private var nextId: Int = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var threadId: String?

    func connect(urlString: String, authKey: String) {
        if connectionState != .disconnected {
            return
        }

        guard let baseURL = URL(string: urlString) else {
            lastError = "Invalid URL"
            return
        }
        if baseURL.scheme?.lowercased() != "http" {
            lastError = "Only http:// is supported (server is HTTP + SSE)."
            return
        }
        guard let host = baseURL.host else {
            lastError = "Invalid URL (missing host)"
            return
        }
        let port = baseURL.port ?? 80

        let trimmedAuthKey = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAuthKey.isEmpty {
            lastError = "Missing Tailscale auth key"
            return
        }

        lastURL = urlString
        connectionState = .connecting
        transcript = ""
        threadId = nil
        self.baseURL = baseURL

        log("connect baseURL=\(baseURL.absoluteString)")

        Task {
            do {
                let proxy = try await EmbeddedTailscale.shared.proxyConfig(authKey: trimmedAuthKey)
                self.appendLine("[tailscale] proxy \(proxy.debugDescription)")
                self.appendLine("[tailscale] target http://\(host):\(port)")

                do {
                    let client = try SOCKS5HTTPClient(
                        proxy: proxy,
                        target: .init(host: host, port: port)
                    )
                    self.httpClient = client

                    try await self.preflightHealthz()
                    self.log("healthz ok")
                } catch {
                    self.log("healthz failed: \(error)")
                    throw error
                }

                self.log("starting SSE /events")

                self.eventsTask = Task { [weak self] in
                    await self?.eventsLoop()
                }

                do {
                    try await self.initializeHandshake()
                    try await self.startThread()
                    self.appendLine("[connected]")
                    self.connectionState = .connected
                    self.log("connected")
                } catch {
                    self.log("connect failed: \(error)")
                    self.lastError = Self.describe(error)
                    self.disconnect()
                }
            } catch {
                self.log("tailscale init failed: \(error)")
                self.lastError = Self.describe(error)
                self.disconnect()
            }
        }
    }

    private func preflightHealthz() async throws {
        guard let client = httpClient else { throw ClientError.notConnected }
        _ = try await client.get(path: "/healthz")
    }

    func disconnect() {
        log("disconnect")
        eventsTask?.cancel()
        eventsTask = nil
        baseURL = nil
        httpClient = nil

        pendingResponses.removeAll()
        pendingApproval = nil
        threadId = nil
        connectionState = .disconnected
    }

    func sendUserText(_ text: String) {
        guard connectionState == .connected else { return }
        guard let threadId else {
            lastError = "No threadId (not ready yet)"
            return
        }

        log("send turn/start")

        appendLine("\n> \(text)")

        let input: [[String: Any]] = [
            [
                "type": "text",
                "text": text,
                "textElements": [],
            ]
        ]

        let params: [String: Any] = [
            "threadId": threadId,
            "input": input,
        ]

        Task {
            do {
                _ = try await request(method: "turn/start", params: params)
            } catch {
                self.log("turn/start failed: \(error)")
                lastError = Self.describe(error)
            }
        }
    }

    func respondToApproval(approvalId: Int, decision: String) {
        guard let approval = pendingApproval, approval.id == approvalId else { return }

        pendingApproval = nil
        Task {
            do {
                let result: [String: Any] = ["decision": decision]
                _ = try await postRPC(["id": approvalId, "result": result])
                appendLine("[approval: \(approval.method) -> \(decision)]")
            } catch {
                lastError = Self.describe(error)
            }
        }
    }

    // MARK: - Protocol

    private func initializeHandshake() async throws {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "climate_ios",
                "title": "CliMate iOS",
                "version": "0.1.0",
            ],
        ]

        _ = try await request(method: "initialize", params: params)
        _ = try await postRPC(["method": "initialized", "params": [:]])
    }

    private func startThread() async throws {
        let result = try await request(method: "thread/start", params: [:])
        guard
            let thread = result["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else {
            throw ClientError.unexpectedResponse("missing thread.id")
        }
        threadId = id
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1

        log("rpc -> \(method) id=\(id)")

        let payload: [String: Any] = [
            "method": method,
            "id": id,
            "params": params,
        ]

        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[id] = cont
            Task {
                do {
                    _ = try await postRPC(payload)
                } catch {
                    pendingResponses.removeValue(forKey: id)
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func postRPC(_ object: [String: Any]) async throws -> [String: Any] {
        guard let client = httpClient else {
            throw ClientError.notConnected
        }

        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        let data = try await client.postJSON(path: "/rpc", jsonBody: body)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = json as? [String: Any] else {
            throw ClientError.unexpectedResponse("rpc response was not an object")
        }
        if let id = parseId(obj["id"]) {
            handleResponse(id: id, result: obj["result"], error: obj["error"])
        }
        return obj
    }

    private func eventsLoop() async {
        do {
            guard let client = httpClient else { return }
            var currentData: String?
            let stream = await client.sse(path: "/events")
            for try await line in stream {
                if Task.isCancelled { break }

                if line.isEmpty {
                    if let data = currentData {
                        handleIncoming(text: data)
                    }
                    currentData = nil
                    continue
                }

                if line.hasPrefix(":") {
                    // SSE comment/keepalive.
                    continue
                }

                if line.hasPrefix("data:") {
                    let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    currentData = value
                }
            }

            log("SSE ended")
        } catch {
            log("SSE failed: \(error)")
            if connectionState == .connected || connectionState == .connecting {
                lastError = Self.describe(error)
            }
            disconnect()
        }
    }

    private func log(_ message: String) {
        NSLog("[climate] %@", message)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = []
        parts.append(error.localizedDescription)
        parts.append("(\(ns.domain) \(ns.code))")

        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) \(underlying.code)")
        }
        return parts.joined(separator: " ")
    }

    private func handleIncoming(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return }
        guard let obj = json as? [String: Any] else { return }

        if let method = obj["method"] as? String {
            if let id = parseId(obj["id"]) {
                handleServerRequest(id: id, method: method, params: obj["params"])
            } else {
                handleNotification(method: method, params: obj["params"])
            }
            return
        }

        if let id = parseId(obj["id"]) {
            handleResponse(id: id, result: obj["result"], error: obj["error"])
        }
    }

    private func handleResponse(id: Int, result: Any?, error: Any?) {
        guard let cont = pendingResponses.removeValue(forKey: id) else {
            return
        }

        if let error = error as? [String: Any], let message = error["message"] as? String {
            cont.resume(throwing: ClientError.remoteError(message))
            return
        }

        if let result = result as? [String: Any] {
            cont.resume(returning: result)
        } else {
            cont.resume(throwing: ClientError.unexpectedResponse("result was not an object"))
        }
    }

    private func handleNotification(method: String, params: Any?) {
        if method == "item/agentMessage/delta" {
            if let params = params as? [String: Any], let delta = params["delta"] as? String {
                append(delta)
            }
            return
        }

        if method == "turn/completed" {
            appendLine("\n")
            return
        }

        if method == "error" {
            if let params = params as? [String: Any], let message = params["message"] as? String {
                appendLine("[error] \(message)")
            }
        }
    }

    private func handleServerRequest(id: Int, method: String, params: Any?) {
        if method == "item/commandExecution/requestApproval" {
            let summary = summarizeCommandApproval(params: params)
            pendingApproval = PendingApproval(id: id, method: method, summary: summary)
            return
        }

        if method == "item/fileChange/requestApproval" {
            let summary = summarizeFileChangeApproval(params: params)
            pendingApproval = PendingApproval(id: id, method: method, summary: summary)
            return
        }

        Task {
            do {
                _ = try await postRPC([
                    "id": id,
                    "error": [
                        "code": -32601,
                        "message": "method not implemented",
                    ],
                ])
            } catch {
                // Ignore.
            }
        }
    }

    private func summarizeCommandApproval(params: Any?) -> String {
        guard let params = params as? [String: Any] else {
            return "Command execution approval requested."
        }
        let reason = (params["reason"] as? String) ?? ""
        let command = (params["command"] as? String) ?? ""
        let cwd = (params["cwd"] as? String) ?? ""

        var parts: [String] = []
        if !reason.isEmpty { parts.append("reason: \(reason)") }
        if !command.isEmpty { parts.append("command: \(command)") }
        if !cwd.isEmpty { parts.append("cwd: \(cwd)") }
        if parts.isEmpty { return "Command execution approval requested." }
        return parts.joined(separator: "\n")
    }

    private func summarizeFileChangeApproval(params: Any?) -> String {
        guard let params = params as? [String: Any] else {
            return "File change approval requested."
        }
        let reason = (params["reason"] as? String) ?? ""
        let grantRoot = (params["grantRoot"] as? String) ?? ""

        var parts: [String] = []
        if !reason.isEmpty { parts.append("reason: \(reason)") }
        if !grantRoot.isEmpty { parts.append("grantRoot: \(grantRoot)") }
        if parts.isEmpty { return "File change approval requested." }
        return parts.joined(separator: "\n")
    }

    private func parseId(_ raw: Any?) -> Int? {
        if let id = raw as? Int {
            return id
        }
        if let id = raw as? Double {
            return Int(id)
        }
        if let id = raw as? String {
            return Int(id)
        }
        return nil
    }

    private func append(_ text: String) {
        transcript.append(text)
    }

    private func appendLine(_ line: String) {
        transcript.append("\(line)\n")
    }
}

enum ClientError: LocalizedError {
    case notConnected
    case invalidBaseURL
    case serializationFailed
    case httpError(Int, String)
    case remoteError(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected"
        case .invalidBaseURL:
            "Invalid base URL"
        case .serializationFailed:
            "Failed to serialize message"
        case .httpError(let code, let body):
            "HTTP \(code): \(body)"
        case .remoteError(let message):
            "Server error: \(message)"
        case .unexpectedResponse(let detail):
            "Unexpected response: \(detail)"
        }
    }
}
