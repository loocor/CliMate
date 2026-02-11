import Foundation

struct PendingApproval: Identifiable {
    let id: Int
    let method: String
    let summary: String
}

@MainActor
final class CodexClient: ObservableObject {
    enum ConnectMode {
        case manual
        case auto
    }

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var transcript: String = ""
    @Published var pendingApproval: PendingApproval?
    @Published var lastError: String?

    private static let maxTranscriptCharacters: Int = 200_000

    enum SSEPayloadKindForTests: Equatable {
        case serverRequest
        case response
        case transcriptDelta
        case transcriptBoundary
        case transcriptError
        case ignore
    }

    private(set) var lastURL: String?

    private var eventsTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt: Int = 0

    private var baseURL: URL?
    private var httpClient: SOCKS5HTTPClient?

    private var nextId: Int = 0
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var threadId: String?

    func connect(urlString: String, mode: ConnectMode = .manual) {
        if connectionState != .disconnected {
            return
        }

        if mode == .manual {
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
        }

        guard let baseURL = URL(string: urlString) else {
            if mode == .manual {
                lastError = "Invalid URL"
            }
            return
        }
        if baseURL.scheme?.lowercased() != "http" {
            if mode == .manual {
                lastError = "Only http:// is supported (server is HTTP + SSE)."
            }
            return
        }
        guard let host = baseURL.host else {
            if mode == .manual {
                lastError = "Invalid URL (missing host)"
            }
            return
        }
        let port = baseURL.port ?? 80

        lastURL = urlString
        connectionState = .connecting
        transcript = ""
        threadId = nil
        self.baseURL = baseURL

        log("connect baseURL=\(baseURL.absoluteString)")

        Task {
            do {
                let proxy = try await EmbeddedTailscale.shared.proxyConfig()
                self.appendLine("[tailscale] proxy \(proxy.debugDescription)")
                let resolvedHost = await EmbeddedTailscale.shared.bestEffortResolveTargetHost(host)
                self.appendLine("[tailscale] target http://\(host):\(port)")
                if resolvedHost != host {
                    self.appendLine("[tailscale] resolved target http://\(resolvedHost):\(port)")
                }

                do {
                    let client = try SOCKS5HTTPClient(
                        proxy: proxy,
                        target: .init(host: resolvedHost, port: port)
                    )
                    self.httpClient = client

                    try await self.preflightHealthz()
                    self.log("healthz ok")
                } catch {
                    self.log("healthz failed: \(error)")
                    throw error
                }

                self.log("starting SSE /events")

                guard let sseClient = self.httpClient else {
                    throw ClientError.notConnected
                }
                self.eventsTask = self.startEventsLoop(httpClient: sseClient)

                try await self.initializeHandshake()
                try await self.startThread()
                self.appendLine("[connected]")
                self.connectionState = .connected
                self.log("connected")
                self.retryTask?.cancel()
                self.retryTask = nil
                self.retryAttempt = 0
            } catch EmbeddedTailscaleError.needsLogin(let urlString) {
                self.log("tailscale needs login: \(urlString)")
                if mode == .manual {
                    self.lastError = "Sign-in required. Open Settings → Servers and sign in."
                } else {
                    self.appendLine("[tailscale] sign-in required (Settings → Servers)")
                }
                self.disconnect()
            } catch EmbeddedTailscaleError.backendNotReady(let message) {
                self.log("tailscale backend not ready: \(message)")
                if mode == .manual {
                    self.lastError = "Network is starting. Try again in a moment."
                } else {
                    self.appendLine("[tailscale] network starting; will retry")
                    self.scheduleRetry(urlString: urlString)
                }
                self.disconnect(cancelRetryTask: mode == .manual, resetRetryAttempt: mode == .manual)
            } catch {
                self.log("connect failed: \(error)")
                if mode == .manual {
                    self.lastError = Self.describe(error)
                } else {
                    self.appendLine("[error] \(Self.describe(error))")
                }
                self.disconnect()
            }
        }
    }

    private func preflightHealthz() async throws {
        guard let client = httpClient else { throw ClientError.notConnected }
        _ = try await client.get(path: "/healthz")
    }

    func disconnect(cancelRetryTask: Bool = true, resetRetryAttempt: Bool = true) {
        log("disconnect")
        eventsTask?.cancel()
        eventsTask = nil
        if cancelRetryTask {
            retryTask?.cancel()
            retryTask = nil
        }
        if resetRetryAttempt {
            retryAttempt = 0
        }
        baseURL = nil
        httpClient = nil

        let pending = Array(pendingResponses.values)
        pendingResponses.removeAll()
        for cont in pending {
            cont.resume(throwing: ClientError.notConnected)
        }
        pendingApproval = nil
        threadId = nil
        connectionState = .disconnected
    }

    private func scheduleRetry(urlString: String) {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt += 1
        let delay = Self.retryDelaySecondsForTests(attempt: retryAttempt)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run { [weak self] in
                self?.connect(urlString: urlString, mode: .auto)
            }
        }
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
            ],
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

        do {
            _ = try await request(method: "initialize", params: params)
            _ = try await postRPC(["method": "initialized", "params": [:]])
        } catch let ClientError.remoteError(message) where message.contains("Already initialized") {
            // Reconnects may hit an existing per-client codex process. In that case,
            // "initialize" is expected to be rejected and should be treated as success.
            log("initialize skipped: already initialized")
        }
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
                    if pendingResponses.removeValue(forKey: id) != nil {
                        cont.resume(throwing: error)
                    }
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

    private func log(_ message: String, level: AppLogLevel = .info) {
        AppLog.post(level: level, category: "codex", message: message)
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


    private func startEventsLoop(httpClient: SOCKS5HTTPClient) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            await self?.eventsLoopBackground(httpClient: httpClient)
        }
    }

    private nonisolated func eventsLoopBackground(httpClient: SOCKS5HTTPClient) async {
        do {
            var currentData: String?
            var pendingTranscript: String = ""
            var lastFlushAt = Date()

            func flushTranscript(force: Bool = false) async {
                if pendingTranscript.isEmpty {
                    return
                }
                let now = Date()
                if !force, pendingTranscript.count < 2048, now.timeIntervalSince(lastFlushAt) < 0.06 {
                    return
                }

                let chunk = pendingTranscript
                pendingTranscript = ""
                lastFlushAt = now
                await MainActor.run { [weak self] in
                    self?.appendToTranscript(chunk)
                }
            }

            let stream = await httpClient.sse(path: "/events")
            for try await line in stream {
                if Task.isCancelled {
                    break
                }

                if line.isEmpty {
                    if let data = currentData {
                        switch Self.parseSSEPayload(data) {
                        case let .serverRequest(id, method, params):
                            await flushTranscript(force: true)
                            await MainActor.run { [weak self] in
                                self?.handleServerRequest(id: id, method: method, params: params)
                            }
                        case let .response(id, result, error):
                            await flushTranscript(force: true)
                            await MainActor.run { [weak self] in
                                self?.handleResponse(id: id, result: result, error: error)
                            }
                        case let .transcriptDelta(delta):
                            pendingTranscript.append(delta)
                        case .transcriptBoundary:
                            pendingTranscript.append("\n\n")
                        case let .transcriptError(message):
                            pendingTranscript.append("[error] \(message)\n")
                        case .ignore:
                            break
                        }
                    }
                    currentData = nil
                    await flushTranscript(force: false)
                    continue
                }

                if line.hasPrefix(":") {
                    // SSE comment/keepalive.
                    continue
                }

                if line.hasPrefix("data:") {
                    let value = line.dropFirst(5).trimmingCharacters(in: CharacterSet.whitespaces)
                    currentData = value
                }

                await flushTranscript(force: false)
            }

            if Task.isCancelled {
                return
            }
            await flushTranscript(force: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.log("SSE ended", level: .warn)
                if self.connectionState != .disconnected {
                    self.disconnect()
                }
            }
        } catch {
            if error is CancellationError {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.log("SSE failed: \(error)", level: .error)
                if self.connectionState == .connected || self.connectionState == .connecting {
                    self.lastError = Self.describe(error)
                }
                self.disconnect()
            }
        }
    }

    private enum SSEPayloadAction {
        case serverRequest(id: Int, method: String, params: Any?)
        case response(id: Int, result: Any?, error: Any?)
        case transcriptDelta(String)
        case transcriptBoundary
        case transcriptError(String)
        case ignore
    }

    private nonisolated static func parseSSEPayload(_ text: String) -> SSEPayloadAction {
        guard let data = text.data(using: .utf8) else { return .ignore }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return .ignore }
        guard let obj = json as? [String: Any] else { return .ignore }

        if let method = obj["method"] as? String {
            if let id = parseIdNonisolated(obj["id"]) {
                return .serverRequest(id: id, method: method, params: obj["params"])
            }

            if method == "item/agentMessage/delta" {
                if let params = obj["params"] as? [String: Any], let delta = params["delta"] as? String {
                    return .transcriptDelta(delta)
                }
                return .ignore
            }

            if method == "turn/completed" {
                return .transcriptBoundary
            }

            if method == "error" {
                if let params = obj["params"] as? [String: Any], let message = params["message"] as? String {
                    return .transcriptError(message)
                }
                return .ignore
            }

            return .ignore
        }

        if let id = parseIdNonisolated(obj["id"]) {
            return .response(id: id, result: obj["result"], error: obj["error"])
        }

        return .ignore
    }

    nonisolated static func ssePayloadKindForTests(_ text: String) -> SSEPayloadKindForTests {
        switch parseSSEPayload(text) {
        case .serverRequest:
            return .serverRequest
        case .response:
            return .response
        case .transcriptDelta:
            return .transcriptDelta
        case .transcriptBoundary:
            return .transcriptBoundary
        case .transcriptError:
            return .transcriptError
        case .ignore:
            return .ignore
        }
    }

    nonisolated static func clippedTranscriptForTests(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        if text.count <= max {
            return text
        }
        return String(text.suffix(max))
    }

    nonisolated static func retryDelaySecondsForTests(attempt: Int) -> Double {
        let normalized = max(1, attempt)
        return min(pow(1.6, Double(normalized)), 20)
    }

    @MainActor
    func setRetryAttemptForTests(_ value: Int) {
        retryAttempt = value
    }

    @MainActor
    func retryAttemptForTests() -> Int {
        retryAttempt
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

    private nonisolated func parseId(_ raw: Any?) -> Int? {
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

    private nonisolated static func parseIdNonisolated(_ raw: Any?) -> Int? {
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
        appendToTranscript(text)
    }

    private func appendLine(_ line: String) {
        appendToTranscript("\(line)\n")
    }

    private func appendToTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        transcript.append(text)
        transcript = Self.clippedTranscriptForTests(transcript, max: Self.maxTranscriptCharacters)
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
        case let .httpError(code, body):
            "HTTP \(code): \(body)"
        case let .remoteError(message):
            "Server error: \(message)"
        case let .unexpectedResponse(detail):
            "Unexpected response: \(detail)"
        }
    }
}
