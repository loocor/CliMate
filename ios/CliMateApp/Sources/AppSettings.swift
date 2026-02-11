import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: Self.udAutoConnectKey)
        }
    }

    @Published var selectedTarget: ServerTarget? {
        didSet {
            saveSelectedTarget()
        }
    }

    static let defaultPort: Int = 4500

    private static let udTargetKey = "climate.serverTarget.v1"
    private static let udAutoConnectKey = "climate.autoConnect.v1"

    init() {
        if UserDefaults.standard.object(forKey: Self.udAutoConnectKey) == nil {
            autoConnect = true
        } else {
            autoConnect = UserDefaults.standard.bool(forKey: Self.udAutoConnectKey)
        }

        selectedTarget = Self.loadSelectedTarget()
    }

    var effectiveServerURLString: String? {
        guard let selectedTarget else { return nil }
        return selectedTarget.urlString
    }

    var effectiveServerDisplayName: String {
        if let selectedTarget {
            return Self.displayName(fromDNSName: selectedTarget.dnsName)
        }
        return "CliMate"
    }

    private func saveSelectedTarget() {
        guard let selectedTarget else {
            UserDefaults.standard.removeObject(forKey: Self.udTargetKey)
            return
        }
        guard let data = try? JSONEncoder().encode(selectedTarget) else { return }
        UserDefaults.standard.set(data, forKey: Self.udTargetKey)
    }

    private static func loadSelectedTarget() -> ServerTarget? {
        guard let data = UserDefaults.standard.data(forKey: udTargetKey) else { return nil }
        return try? JSONDecoder().decode(ServerTarget.self, from: data)
    }

    private static func displayName(fromDNSName: String) -> String {
        let trimmed = fromDNSName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmed.split(separator: ".").first.map(String.init) ?? trimmed
        if host.isEmpty { return "CliMate" }
        if host.allSatisfy({ $0.isNumber || $0 == ":" }) {
            return host
        }
        let words =
            host
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { part -> String in
                let s = String(part)
                if s.count <= 1 { return s.uppercased() }
                return s.prefix(1).uppercased() + s.dropFirst().lowercased()
            }
        if words.isEmpty { return host }
        return words.joined(separator: " ")
    }
}

struct ServerTarget: Codable, Hashable, Identifiable {
    let stableID: String
    let dnsName: String
    let port: Int

    var id: String {
        stableID.isEmpty ? "\(dnsName):\(port)" : stableID
    }

    var urlString: String {
        let host = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "http://\(host):\(port)"
    }
}
