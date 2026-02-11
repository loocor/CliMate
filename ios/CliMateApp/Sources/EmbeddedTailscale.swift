import Foundation
import Network
import TailscaleKit

enum EmbeddedTailscaleError: Error {
    case notRunning
    case needsLogin(String)
    case backendNotReady(String)
}

private struct ConsoleLogSink: LogSink {
    var logFileHandle: Int32? = STDOUT_FILENO

    func log(_ message: String) {
        AppLog.info(message, category: "tailscale")
    }
}

struct TailscaleProxyConfig: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let debugDescription: String
}

actor EmbeddedTailscale {
    static let shared = EmbeddedTailscale()

    private var node: TailscaleNode?
    private var localAPI: LocalAPIClient?
    private var lastAuthKey: String?
    private var proxyConfig: TailscaleProxyConfig?
    private var proxyConfigTask: Task<TailscaleProxyConfig, Error>?
    private var upTask: Task<Void, Never>?

    func shutdown() async {
        upTask?.cancel()
        upTask = nil
        proxyConfigTask?.cancel()
        proxyConfigTask = nil

        if let existing = node {
            try? await existing.close()
        }

        node = nil
        localAPI = nil
        proxyConfig = nil
        lastAuthKey = nil
    }

    func wipeState() async {
        await shutdown()
        do {
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let tsDir = docDir.appendingPathComponent("tailscale", isDirectory: true)
            if FileManager.default.fileExists(atPath: tsDir.path) {
                try FileManager.default.removeItem(at: tsDir)
            }
        } catch {
            AppLog.warn("failed to wipe tailscale state: \(error)", category: "tailscale")
        }
    }

    func proxyConfig() async throws -> TailscaleProxyConfig {
        try await ensureRunning(authKey: nil)
        return try await sharedProxyConfigReady()
    }

    func proxyConfig(authKey: String) async throws -> TailscaleProxyConfig {
        let trimmed = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmbeddedTailscaleError.notRunning
        }
        try await ensureRunning(authKey: trimmed)
        return try await sharedProxyConfigReady()
    }

    private func sharedProxyConfigReady() async throws -> TailscaleProxyConfig {
        if let proxyConfig {
            return proxyConfig
        }

        if let task = proxyConfigTask {
            return try await task.value
        }

        let task = Task { [weak self] () throws -> TailscaleProxyConfig in
            guard let self else { throw EmbeddedTailscaleError.notRunning }
            return try await self.ensureProxyConfigReady(timeoutSeconds: 25)
        }
        proxyConfigTask = task

        do {
            let cfg = try await task.value
            proxyConfig = cfg
            proxyConfigTask = nil
            return cfg
        } catch {
            proxyConfigTask = nil
            throw error
        }
    }

    func ensureRunning(authKey: String?) async throws {
        if node != nil, lastAuthKey == authKey {
            return
        }

        await shutdown()

        AppLog.info("starting embedded tailscale", category: "tailscale")

        let dataDir = try Self.ensureDataDir()
        let config = Configuration(
            hostName: "CliMate-iOS",
            path: dataDir,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )

        let node = try TailscaleNode(config: config, logger: ConsoleLogSink())
        let localAPI = LocalAPIClient(localNode: node, logger: nil)

        // NOTE: `node.up()` can block while waiting for login when authKey is nil.
        // Use LocalAPI `start` in the background to kick the backend without blocking UI.
        upTask = Task { [weak self] in
            do {
                try await Self.startBackendWithRetry(localAPI: localAPI, authKey: authKey)
            } catch {
                AppLog.error("tailscale start failed: \(error)", category: "tailscale")
                await self?.handleUpFailure(error)
            }
        }

        self.node = node
        self.localAPI = localAPI
        proxyConfig = nil
        lastAuthKey = authKey
    }

    private static func startBackendWithRetry(localAPI: LocalAPIClient, authKey: String?) async throws {
        let opts = try Self.makeStartOptions(authKey: authKey)
        var lastError: Error?

        for _ in 1 ... 5 {
            do {
                try await localAPI.start(options: opts)
                lastError = nil
                break
            } catch {
                lastError = error
                if isTransientStartError(error) {
                    try? await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
                    continue
                }
                throw error
            }
        }

        if let lastError {
            throw lastError
        }

        _ = try? await localAPI.editPrefs(mask: Ipn.MaskedPrefs().wantRunning(true))

        let deadline = Date().addingTimeInterval(8)
        var lastLogKey: String = ""
        while Date() < deadline {
            if let status = try? await localAPI.backendStatus() {
                let backend = status.BackendState.lowercased()
                let logKey = "\(backend)|\(!status.AuthURL.isEmpty)"
                if logKey != lastLogKey {
                    lastLogKey = logKey
                    AppLog.info(
                        "tailscale backend state=\(status.BackendState) authURL=\(!status.AuthURL.isEmpty)",
                        category: "tailscale"
                    )
                }

                if backend != "nostate", backend != "stopped" {
                    AppLog.info("tailscale start finished", category: "tailscale")
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 300 * NSEC_PER_MSEC)
        }

        throw EmbeddedTailscaleError.backendNotReady("tailscale backend not ready")
    }

    private static func isTransientStartError(_ error: Error) -> Bool {
        if let ts = error as? TailscaleError {
            switch ts {
            case .connectionClosed, .listenerClosed, .readFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func makeStartOptions(authKey: String?) throws -> Ipn.Options {
        var payload: [String: Any] = [:]
        if let authKey, !authKey.isEmpty {
            payload["AuthKey"] = authKey
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try JSONDecoder().decode(Ipn.Options.self, from: data)
    }

    private func handleUpFailure(_ error: Error) {
        // Currently only logs. Keeping a hook for future state reporting.
    }

    private func ensureProxyConfigReady(timeoutSeconds: Double = 10) async throws -> TailscaleProxyConfig {
        if let proxyConfig {
            return proxyConfig
        }
        guard let node else {
            throw EmbeddedTailscaleError.notRunning
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status: IpnState.Status
            do {
                status = try await backendStatus()
            } catch {
                if Self.isTransientStartError(error) {
                    try await Task.sleep(nanoseconds: 250 * NSEC_PER_MSEC)
                    continue
                }
                if String(describing: error).localizedCaseInsensitiveContains("buffer too small") {
                    AppLog.warn("tailscale internal error; wiping local state", category: "tailscale")
                    await wipeState()
                    throw EmbeddedTailscaleError.backendNotReady("tailscale internal error; state wiped")
                }
                throw error
            }
            if !status.AuthURL.isEmpty {
                throw EmbeddedTailscaleError.needsLogin(status.AuthURL)
            }

            if status.BackendState.lowercased() == "running" {
                let loopback = try await node.loopback()
                AppLog.info("socks5 proxy at \(loopback.address)", category: "tailscale")

                guard let proxyHost = loopback.ip, let proxyPort = loopback.port else {
                    throw TailscaleError.invalidProxyAddress
                }

                let cfg = TailscaleProxyConfig(
                    host: proxyHost,
                    port: proxyPort,
                    username: "tsnet",
                    password: loopback.proxyCredential,
                    debugDescription: "socks5://\(proxyHost):\(proxyPort) (user=tsnet)"
                )
                proxyConfig = cfg
                return cfg
            }

            try await Task.sleep(nanoseconds: 500 * NSEC_PER_MSEC)
        }

        throw EmbeddedTailscaleError.backendNotReady("tailscale backend not ready")
    }

    func localAPIClient() throws -> LocalAPIClient {
        guard let localAPI else {
            throw EmbeddedTailscaleError.notRunning
        }
        return localAPI
    }

    func backendStatus() async throws -> IpnState.Status {
        guard let localAPI else {
            throw EmbeddedTailscaleError.notRunning
        }
        return try await localAPI.backendStatus()
    }

    func startLoginInteractive() async throws {
        guard let localAPI else {
            throw EmbeddedTailscaleError.notRunning
        }
        AppLog.info("localapi login-interactive request", category: "tailscale")
        try await localAPI.startLoginInteractive()
        if let status = try? await localAPI.backendStatus() {
            AppLog.info("post login-interactive backendState=\(status.BackendState) authURL=\(!status.AuthURL.isEmpty)", category: "tailscale")
        }
    }

    func resetAuth() async throws {
        guard let localAPI else {
            throw EmbeddedTailscaleError.notRunning
        }
        do {
            try await localAPI.resetAuth()
        } catch {
            // Even if resetAuth fails, shutdown tends to be the safest recovery path.
            AppLog.warn("resetAuth failed: \(error)", category: "tailscale")
            await shutdown()
            // If the LocalAPI connection is already torn down, treat it as reset complete.
            if let ts = error as? TailscaleError {
                switch ts {
                case .connectionClosed:
                    return
                default:
                    break
                }
            }
            if String(describing: error).localizedCaseInsensitiveContains("buffer too small") {
                await wipeState()
                return
            }
            throw error
        }
        await shutdown()
    }

    func bestEffortResolveTargetHost(_ host: String) async -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return host }
        if isIPAddress(trimmed) { return trimmed }

        guard let localAPI else {
            AppLog.warn("localapi unavailable; cannot resolve \(trimmed)", category: "tailscale")
            return trimmed
        }

        do {
            let status = try await localAPI.backendStatus()
            if let tailnet = status.CurrentTailnet {
                AppLog.info(
                    "tailnet magicDNS enabled=\(tailnet.MagicDNSEnabled) suffix=\(tailnet.MagicDNSSuffix)",
                    category: "tailscale"
                )
            }

            let want = normalizeDNSName(trimmed)
            let peers = status.Peer.map { Array($0.values) } ?? []
            if let peer = peers.first(where: { normalizeDNSName($0.DNSName) == want }) {
                if let ip = peer.TailscaleIPs?.first {
                    AppLog.info("resolved \(trimmed) -> \(ip)", category: "tailscale")
                    return ip
                }
                AppLog.warn("peer matched but has no TailscaleIPs for \(trimmed)", category: "tailscale")
                return trimmed
            }

            AppLog.warn("no peer match for \(trimmed) in backendStatus", category: "tailscale")
            return trimmed
        } catch {
            AppLog.warn("backendStatus failed; cannot resolve \(trimmed): \(error)", category: "tailscale")
            return trimmed
        }
    }

    private func normalizeDNSName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func isIPAddress(_ s: String) -> Bool {
        if s.contains(":") {
            return IPv6Address(s) != nil
        }
        return IPv4Address(s) != nil
    }

    private static func ensureDataDir() throws -> String {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tsDir = docDir.appendingPathComponent("tailscale", isDirectory: true)
        try FileManager.default.createDirectory(at: tsDir, withIntermediateDirectories: true)
        return tsDir.path
    }
}
