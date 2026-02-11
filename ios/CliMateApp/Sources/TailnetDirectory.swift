import Foundation
import Network
import TailscaleKit

private let climateAuthCallbackNotification = Notification.Name("climate.auth.callback")

struct TailnetPeer: Identifiable, Hashable {
    let stableID: String
    let dnsName: String
    let hostName: String
    let os: String
    let osVersion: String
    let preferredIP: String
    let online: Bool

    var id: String {
        stableID.isEmpty ? dnsName : stableID
    }

    var isCliMateServerCandidate: Bool {
        let dns = dnsName.lowercased()
        if dns.hasPrefix("climate-") { return true }
        let host = hostName.lowercased()
        if host.hasPrefix("climate-") { return true }
        return false
    }

    var probeTargetHost: String {
        if !preferredIP.isEmpty { return preferredIP }
        return dnsName
    }
}

private actor DirectoryBusConsumer: MessageConsumer {
    let onNotify: @Sendable (Ipn.Notify) async -> Void
    let onError: @Sendable (any Error) async -> Void

    init(
        onNotify: @escaping @Sendable (Ipn.Notify) async -> Void,
        onError: @escaping @Sendable (any Error) async -> Void
    ) {
        self.onNotify = onNotify
        self.onError = onError
    }

    func notify(_ notify: Ipn.Notify) {
        Task { await onNotify(notify) }
    }

    func error(_ error: any Error) {
        Task { await onError(error) }
    }
}

@MainActor
final class TailnetDirectory: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case needsLogin(String)
        case error(String)
    }

    enum ServerProbeState: Equatable {
        case unknown
        case reachable
        case unreachable
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var peers: [TailnetPeer] = []
    @Published private(set) var authURL: URL?
    @Published private(set) var serverProbe: [String: ServerProbeState] = [:]
    @Published private(set) var isSigningIn: Bool = false
    @Published private(set) var isSigningOut: Bool = false
    @Published private(set) var accountLabel: String = ""

    private var watchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var localAPI: LocalAPIClient?
    private var busProcessor: MessageProcessor?
    private var accountTask: Task<Void, Never>?
    private var lastAccountRefreshAt: Date?
    private var authCallbackObserver: NSObjectProtocol?
    private var backendStatusFailures: Int = 0

    private var lastStatus: IpnState.Status?
    private var lastBackendState: String?
    private var lastAuthURLLog: String?

    func start() {
        if watchTask != nil {
            return
        }

        state = .starting
        watchTask = Task { [weak self] in
            guard let self else { return }
            do {
                AppLog.info("directory start", category: "tailscale")
                try await EmbeddedTailscale.shared.ensureRunning(authKey: nil)
                AppLog.info("directory ensureRunning ok", category: "tailscale")

                let localAPI = try await EmbeddedTailscale.shared.localAPIClient()
                self.localAPI = localAPI
                AppLog.info("directory localapi ok", category: "tailscale")

                do {
                    try await startBusWatch()
                } catch {
                    AppLog.warn("watchIPNBus failed (will rely on polling): \(error)", category: "tailscale")
                }
                startRefreshLoop()
                startAuthCallbackObserver()

                await refreshBackendStatus()
            } catch {
                let message = String(describing: error)
                AppLog.error("tailnet directory start failed: \(message)", category: "tailscale")
                if message.localizedCaseInsensitiveContains("buffer too small") {
                    AppLog.warn("wiping local state after start failure", category: "tailscale")
                    await EmbeddedTailscale.shared.wipeState()
                    self.stop()
                    self.start()
                    return
                }
                self.state = .error(message)
                self.stop()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        for (_, task) in probeTasks {
            task.cancel()
        }
        probeTasks.removeAll()
        busProcessor?.cancel()
        busProcessor = nil
        accountTask?.cancel()
        accountTask = nil
        if let authCallbackObserver {
            NotificationCenter.default.removeObserver(authCallbackObserver)
        }
        authCallbackObserver = nil
        localAPI = nil
        lastStatus = nil
        lastBackendState = nil
        lastAuthURLLog = nil
        authURL = nil
        serverProbe = [:]
        isSigningIn = false
        isSigningOut = false
        accountLabel = ""
        lastAccountRefreshAt = nil
        backendStatusFailures = 0
    }

    func startLoginInteractive() {
        if isSigningIn { return }
        isSigningIn = true
        Task { [weak self] in
            guard let self else { return }
            do {
                AppLog.info("manual login requested", category: "tailscale")
                try await EmbeddedTailscale.shared.ensureRunning(authKey: nil)
                if self.localAPI == nil {
                    self.localAPI = try await EmbeddedTailscale.shared.localAPIClient()
                }
                try await EmbeddedTailscale.shared.startLoginInteractive()
                for _ in 0 ..< 30 {
                    await refreshBackendStatus()
                    if self.authURL != nil { break }
                    try? await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
                }
                if self.authURL == nil {
                    AppLog.warn("manual login did not produce authURL yet", category: "tailscale")
                } else {
                    AppLog.info("manual login got authURL", category: "tailscale")
                }
            } catch {
                let message = String(describing: error)
                AppLog.error("startLoginInteractive failed: \(message)", category: "tailscale")

                // Some tailscale builds surface an internal error where the error message buffer is too small.
                // Best-effort recovery: wipe local state and retry once.
                if message.localizedCaseInsensitiveContains("buffer too small") {
                    AppLog.warn("retrying login after wiping local state", category: "tailscale")
                    await EmbeddedTailscale.shared.wipeState()
                    self.stop()
                    self.start()
                    return
                }

                self.state = .error(message)
            }
            await MainActor.run { [weak self] in
                self?.isSigningIn = false
            }
        }
    }

    func resetAuth() {
        if isSigningOut { return }
        isSigningOut = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await EmbeddedTailscale.shared.resetAuth()
                self.stop()
                self.start()
            } catch {
                let message = String(describing: error)
                AppLog.error("resetAuth failed: \(message)", category: "tailscale")
                if message.localizedCaseInsensitiveContains("buffer too small") {
                    AppLog.warn("retrying resetAuth after wiping local state", category: "tailscale")
                    await EmbeddedTailscale.shared.wipeState()
                    self.stop()
                    self.start()
                    return
                }
                self.state = .error(message)
            }
            await MainActor.run { [weak self] in
                self?.isSigningOut = false
            }
        }
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refreshBackendStatus()
        }
    }

    private func startBusWatch() async throws {
        guard let localAPI else { return }
        if busProcessor != nil { return }

        let consumer = DirectoryBusConsumer(
            onNotify: { [weak self] notify in
                guard let self else { return }
                await MainActor.run {
                    if let err = notify.ErrMessage, !err.isEmpty {
                        AppLog.warn("ipn bus err: \(err)", category: "tailscale")
                    }

                    if let browse = notify.BrowseToURL, !browse.isEmpty {
                        let sanitized = Self.sanitizeAuthURL(browse)
                        if sanitized != self.lastAuthURLLog {
                            self.lastAuthURLLog = sanitized
                            AppLog.info("authURL \(sanitized)", category: "tailscale")
                        }
                        self.authURL = URL(string: browse)
                        self.state = .needsLogin(browse)
                    }

                    if let st = notify.State {
                        switch st {
                        case .Running:
                            self.authURL = nil
                            self.state = .running
                            self.startAccountRefreshIfNeeded()
                        case .Starting:
                            if case .needsLogin = self.state {
                                break
                            }
                            self.state = .starting
                        case .NeedsLogin, .NeedsMachineAuth, .NoState, .Stopped, .InUseOtherUser:
                            if self.authURL == nil {
                                self.state = .needsLogin("")
                            }
                        default:
                            break
                        }
                    }

                    if notify.LoginFinished != nil {
                        Task { [weak self] in
                            await self?.refreshBackendStatus()
                        }
                    }
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                let message = String(describing: error)
                await MainActor.run {
                    if message.localizedCaseInsensitiveContains("queuecongested") {
                        AppLog.warn("ipn bus congested; falling back to polling", category: "tailscale")
                        self.busProcessor?.cancel()
                        self.busProcessor = nil
                        return
                    }
                    AppLog.warn("ipn bus error: \(message)", category: "tailscale")
                    if message.localizedCaseInsensitiveContains("buffer too small") {
                        Task { [weak self] in
                            guard let self else { return }
                            AppLog.warn("wiping local state after ipn bus error", category: "tailscale")
                            await EmbeddedTailscale.shared.wipeState()
                            await MainActor.run {
                                self.stop()
                                self.start()
                            }
                        }
                        return
                    }
                }
            }
        )

        let processor = try await localAPI.watchIPNBus(mask: [.initialState, .prefs], consumer: consumer)
        busProcessor = processor
        AppLog.info("directory watchIPNBus started", category: "tailscale")
    }

    private func normalizeDNSName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func startRefreshLoop() {
        if refreshTask != nil {
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let intervalSeconds: UInt64 = await MainActor.run {
                    if case .starting = self.state { return 1 }
                    if case .needsLogin = self.state, self.authURL == nil { return 1 }
                    return 8
                }
                try? await Task.sleep(nanoseconds: intervalSeconds * NSEC_PER_SEC)
                await refreshBackendStatus()
            }
        }
    }

    private func refreshBackendStatus() async {
        guard let localAPI else { return }
        do {
            lastStatus = try await withTimeout(seconds: 2) {
                try await localAPI.backendStatus()
            }
            backendStatusFailures = 0
            guard let status = lastStatus else { return }

            let backendState = status.BackendState.lowercased()
            if lastBackendState != backendState {
                lastBackendState = backendState
                AppLog.info("backendState=\(status.BackendState) authURL=\(!status.AuthURL.isEmpty)", category: "tailscale")
            }
            if !status.AuthURL.isEmpty {
                let sanitized = Self.sanitizeAuthURL(status.AuthURL)
                if sanitized != lastAuthURLLog {
                    lastAuthURLLog = sanitized
                    AppLog.info("authURL \(sanitized)", category: "tailscale")
                }
                authURL = URL(string: status.AuthURL)
            } else {
                authURL = nil
            }

            switch backendState {
            case "running":
                state = .running
                startAccountRefreshIfNeeded(status: status)
            case "starting":
                state = .starting
            case "needslogin", "needs_machine_auth", "needsmachineauth", "nostate", "stopped", "inuseotheruser":
                state = .needsLogin(status.AuthURL)
                accountLabel = ""
            default:
                // If we don't recognize the state, prefer a conservative UI.
                if authURL != nil {
                    state = .needsLogin(status.AuthURL)
                    accountLabel = ""
                } else {
                    state = .starting
                }
            }
            recomputePeers()
        } catch {
            backendStatusFailures += 1
            AppLog.warn("backendStatus failed: \(error)", category: "tailscale")
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("buffer too small") {
                AppLog.warn("wiping local state after backendStatus error", category: "tailscale")
                await EmbeddedTailscale.shared.wipeState()
                stop()
                start()
                return
            }
            if backendStatusFailures >= 3, state == .starting {
                state = .error("backendStatus failed: \(error)")
            }
        }
    }

    private func startAccountRefreshIfNeeded(status: IpnState.Status? = nil) {
        guard state == .running else { return }
        guard accountTask == nil else { return }
        guard let localAPI else { return }

        if let last = lastAccountRefreshAt, !accountLabel.isEmpty, Date().timeIntervalSince(last) < 30 {
            return
        }

        accountTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.accountTask = nil
            }

            let profile: IpnLocal.LoginProfile?
            do {
                profile = try await self.withTimeout(seconds: 2) {
                    try await localAPI.currentProfile()
                }
            } catch {
                AppLog.warn("currentProfile failed: \(error)", category: "tailscale")
                return
            }
            guard let profile else { return }

            let login = profile.UserProfile.LoginName.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = profile.UserProfile.DisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let primary = !login.isEmpty ? login : display
            if primary.isEmpty { return }

            self.accountLabel = primary
            self.lastAccountRefreshAt = Date()
        }
    }

    private func startAuthCallbackObserver() {
        if authCallbackObserver != nil { return }
        authCallbackObserver = NotificationCenter.default.addObserver(
            forName: climateAuthCallbackNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNow()
        }
    }

    private func recomputePeers() {
        let statusPeers = lastStatus?.Peer.map { Array($0.values) } ?? []
        var result: [TailnetPeer] = []
        result.reserveCapacity(statusPeers.count)

        for st in statusPeers {
            let dns = normalizeDNSName(st.DNSName)
            if dns.isEmpty { continue }
            let preferredIP = Self.preferredIP(from: st.TailscaleIPs) ?? ""
            result.append(
                TailnetPeer(
                    stableID: st.ID,
                    dnsName: dns,
                    hostName: st.HostName,
                    os: "",
                    osVersion: "",
                    preferredIP: preferredIP,
                    online: st.Online
                )
            )
        }

        // Stable order to avoid UI flicker.
        result.sort { a, b in
            if a.online != b.online { return a.online && !b.online }
            if a.os != b.os { return a.os < b.os }
            return a.dnsName < b.dnsName
        }

        peers = result
        reconcileServerProbes()
    }

    private static func preferredIP(from ips: [String]?) -> String? {
        guard let ips, !ips.isEmpty else { return nil }
        if let v4 = ips.first(where: { IPv4Address($0) != nil }) { return v4 }
        return ips.first
    }

    private func reconcileServerProbes() {
        // Only probe once the backend is running. While starting we may not have routing/DNS yet.
        guard state == .running else {
            for (_, task) in probeTasks {
                task.cancel()
            }
            probeTasks.removeAll()
            serverProbe = [:]
            return
        }

        let maxConcurrentProbes = 2

        let candidates = peers.filter { $0.online && $0.isCliMateServerCandidate }
        let candidateIDs = Set(candidates.map(\.id))

        // Drop probes for peers that disappeared.
        for key in serverProbe.keys where !candidateIDs.contains(key) {
            serverProbe.removeValue(forKey: key)
        }
        for key in probeTasks.keys where !candidateIDs.contains(key) {
            probeTasks[key]?.cancel()
            probeTasks.removeValue(forKey: key)
        }

        var available = max(0, maxConcurrentProbes - probeTasks.count)
        for peer in candidates {
            if available <= 0 { break }
            if serverProbe[peer.id] == nil {
                serverProbe[peer.id] = .unknown
            }
            if probeTasks[peer.id] != nil {
                continue
            }

            probeTasks[peer.id] = startProbeTask(peer: peer)
            available -= 1
        }
    }

    private func startProbeTask(peer: TailnetPeer) -> Task<Void, Never> {
        let peerID = peer.id
        let host = peer.probeTargetHost
        // Avoid doing network work on the MainActor; it can cause UI stutters on-device.
        return Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let ok = await Self.checkHealthz(host: host, port: 4500)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.serverProbe[peerID] = ok ? .reachable : .unreachable
                self.probeTasks.removeValue(forKey: peerID)
            }
        }
    }

    private nonisolated static func checkHealthz(host: String, port: Int) async -> Bool {
        do {
            let proxy = try await EmbeddedTailscale.shared.proxyConfig()
            let client = try SOCKS5HTTPClient(
                proxy: proxy,
                target: .init(host: host, port: port)
            )
            _ = try await client.get(path: "/healthz")
            return true
        } catch {
            return false
        }
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError(seconds: seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func sanitizeAuthURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return "<invalid url>" }
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.path = url.path

        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
            let keys = items.map(\.name).sorted()
            let base =
                parts.string
                ?? "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
            return "\(base)?keys=\(keys.joined(separator: ","))"
        }

        return parts.string ?? "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }
}

private struct TimeoutError: Error {
    let seconds: Double
}
