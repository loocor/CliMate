import Foundation
import TailscaleKit

private struct ConsoleLogSink: LogSink {
    var logFileHandle: Int32? = STDOUT_FILENO

    func log(_ message: String) {
        print("[tailscale] \(message)")
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
    private var lastAuthKey: String?
    private var proxyConfig: TailscaleProxyConfig?

    func proxyConfig(authKey: String) async throws -> TailscaleProxyConfig {
        if let proxyConfig, lastAuthKey == authKey {
            return proxyConfig
        }

        if let existing = node {
            try await existing.close()
            node = nil
            proxyConfig = nil
        }

        print("[climate] starting embedded tailscale")

        let dataDir = try Self.ensureDataDir()
        let config = Configuration(
            hostName: "CliMate-iOS",
            path: dataDir,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        let node = try TailscaleNode(config: config, logger: ConsoleLogSink())
        try await node.up()

        let addrs = try await node.addrs()
        print("[climate] embedded tailscale up; ip4=\(addrs.ip4 ?? "-") ip6=\(addrs.ip6 ?? "-")")

        let loopback = try await node.loopback()
        print("[climate] socks5 proxy at \(loopback.address)")

        guard let proxyHost = loopback.ip, let proxyPort = loopback.port else {
            throw TailscaleError.invalidProxyAddress
        }

        let proxyConfig = TailscaleProxyConfig(
            host: proxyHost,
            port: proxyPort,
            username: "tsnet",
            password: loopback.proxyCredential,
            debugDescription: "socks5://\(proxyHost):\(proxyPort) (user=tsnet)"
        )

        self.node = node
        self.proxyConfig = proxyConfig
        self.lastAuthKey = authKey

        return proxyConfig
    }

    private static func ensureDataDir() throws -> String {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tsDir = docDir.appendingPathComponent("tailscale", isDirectory: true)
        try FileManager.default.createDirectory(at: tsDir, withIntermediateDirectories: true)
        return tsDir.path
    }
}
