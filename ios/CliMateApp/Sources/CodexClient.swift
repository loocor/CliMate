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

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private var nextId: Int = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var threadId: String?

    func connect(urlString: String) {
        if connectionState != .disconnected {
            return
        }

        guard let url = URL(string: urlString) else {
            lastError = "Invalid URL"
            return
        }

        lastURL = urlString
        connectionState = .connecting
        transcript = ""
        threadId = nil

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        Task {
            do {
                try await initializeHandshake()
                try await startThread()
                appendLine("[connected]")
                connectionState = .connected
            } catch {
                lastError = error.localizedDescription
                disconnect()
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil

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
                lastError = error.localizedDescription
            }
        }
    }

    func respondToApproval(approvalId: Int, decision: String) {
        guard let approval = pendingApproval, approval.id == approvalId else { return }

        pendingApproval = nil
        Task {
            do {
                let result: [String: Any] = ["decision": decision]
                try await send(["id": approvalId, "result": result])
                appendLine("[approval: \(approval.method) -> \(decision)]")
            } catch {
                lastError = error.localizedDescription
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
        try await send(["method": "initialized", "params": [:]])
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

        let payload: [String: Any] = [
            "method": method,
            "id": id,
            "params": params,
        ]

        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[id] = cont
            Task {
                do {
                    try await send(payload)
                } catch {
                    pendingResponses.removeValue(forKey: id)
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let webSocketTask else {
            throw ClientError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.serializationFailed
        }
        try await webSocketTask.send(.string(text))
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text):
                    handleIncoming(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncoming(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if connectionState == .connected || connectionState == .connecting {
                    lastError = error.localizedDescription
                }
                disconnect()
                return
            }
        }
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
                try await send([
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
    case serializationFailed
    case remoteError(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected"
        case .serializationFailed:
            "Failed to serialize message"
        case .remoteError(let message):
            "Server error: \(message)"
        case .unexpectedResponse(let detail):
            "Unexpected response: \(detail)"
        }
    }
}
