import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Label("Servers", systemImage: "server.rack")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsStatusRow: View {
    let tailnetReady: Bool
    let serverSelected: Bool
    let serverName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isConfigured ? Color.blue : Color.red)
                    .frame(width: 10, height: 10)

                Text(isConfigured ? "Ready" : "Incomplete")
                    .font(.body)
            }

            Group {
                if !tailnetReady {
                    Text("Not signed in.")
                } else if !serverSelected {
                    Text("No server selected.")
                } else {
                    Text("Server: \(serverName)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var isConfigured: Bool {
        tailnetReady && serverSelected
    }
}

private struct ServerSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var directory = TailnetDirectory()
    @State private var showOtherOnline: Bool = false
    @State private var showOtherCandidates: Bool = false
    @State private var didAutoOpenAuthURL: Bool = false

    var body: some View {
        Form {
            Section {
                switch directory.state {
                case .idle, .starting:
                    Text("Starting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .running:
                    Text(directory.accountLabel.isEmpty ? "Signed in" : directory.accountLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .needsLogin:
                    Text("Sign-in required")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case let .error(message):
                    Text("Error: \(message)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if directory.state == .running {
                    Button("Sign out", role: .destructive) {
                        directory.resetAuth()
                    }
                    .disabled(directory.isSigningOut || directory.isSigningIn)
                } else {
                    Button(directory.isSigningIn ? "Signing in…" : "Sign in") {
                        didAutoOpenAuthURL = false
                        directory.startLoginInteractive()
                    }
                    .disabled(directory.isSigningIn || directory.isSigningOut)
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Used to access your Tailnet and discover available CliMate servers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if directory.state == .running {
                Section("Auto-discovered servers") {
                    if reachableCliMateServers.isEmpty {
                        Text(discoveryStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(reachableCliMateServers) { peer in
                            Button {
                                settings.selectedTarget = ServerTarget(
                                    stableID: peer.stableID,
                                    dnsName: peer.dnsName,
                                    port: AppSettings.defaultPort
                                )
                            } label: {
                                serverRow(for: peer, probeText: nil)
                            }
                        }
                    }

                    Toggle("Show other candidates", isOn: $showOtherCandidates)
                    Toggle("Show other online devices", isOn: $showOtherOnline)
                }

                if showOtherCandidates {
                    Section("Other candidates") {
                        if otherCliMateCandidates.isEmpty {
                            Text("No other candidates found.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(otherCliMateCandidates) { peer in
                                Button {
                                    settings.selectedTarget = ServerTarget(
                                        stableID: peer.stableID,
                                        dnsName: peer.dnsName,
                                        port: AppSettings.defaultPort
                                    )
                                } label: {
                                    serverRow(for: peer, probeText: probeLabel(for: peer))
                                }
                            }
                        }
                    }
                }

                if showOtherOnline {
                    Section("Other online devices") {
                        if otherOnlineCandidates.isEmpty {
                            Text("No other online devices found yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(otherOnlineCandidates) { peer in
                                Button {
                                    settings.selectedTarget = ServerTarget(
                                        stableID: peer.stableID,
                                        dnsName: peer.dnsName,
                                        port: AppSettings.defaultPort
                                    )
                                } label: {
                                    serverRow(for: peer, probeText: nil)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Auto-connect to server", isOn: $settings.autoConnect)
            } header: {
                Text("Auto-connect")
            } footer: {
                Text("Enable this after selecting a server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                SettingsStatusRow(
                    tailnetReady: directory.state == .running,
                    serverSelected: settings.effectiveServerURLString != nil,
                    serverName: settings.effectiveServerDisplayName
                )
            }
        }
        .navigationTitle("Servers")
        .onAppear {
            directory.start()
        }
        .onDisappear {
            directory.stop()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                directory.refreshNow()
                if let authURL = directory.authURL, !didAutoOpenAuthURL {
                    openURL(authURL)
                    didAutoOpenAuthURL = true
                }
            }
        }
        .onChange(of: directory.authURL) { newURL in
            guard let newURL else { return }
            guard !didAutoOpenAuthURL else { return }
            openURL(newURL)
            didAutoOpenAuthURL = true
        }
    }

    private var reachableCliMateServers: [TailnetPeer] {
        directory.peers
            .filter { $0.online && $0.isCliMateServerCandidate }
            .filter { directory.serverProbe[$0.id] == .reachable }
    }

    private var otherCliMateCandidates: [TailnetPeer] {
        directory.peers
            .filter { $0.online && $0.isCliMateServerCandidate }
            .filter { directory.serverProbe[$0.id] != .reachable }
    }

    private var otherOnlineCandidates: [TailnetPeer] {
        directory.peers
            .filter { $0.online }
            .filter { !$0.isCliMateServerCandidate }
    }

    private var discoveryStatusText: String {
        let states = otherCliMateCandidates.compactMap { directory.serverProbe[$0.id] }
        if states.contains(.unknown) {
            return "Searching for CliMate servers…"
        }
        if directory.peers.contains(where: { $0.online && $0.isCliMateServerCandidate }) {
            return "No CliMate servers responded on port \(AppSettings.defaultPort) yet."
        }
        return "No online CliMate candidates found."
    }

    private func probeLabel(for peer: TailnetPeer) -> String {
        switch directory.serverProbe[peer.id] ?? .unknown {
        case .unknown: return "Checking…"
        case .reachable: return "OK"
        case .unreachable: return "Unreachable"
        }
    }

    private func isSelected(_ peer: TailnetPeer) -> Bool {
        if settings.selectedTarget?.stableID == peer.stableID, !peer.stableID.isEmpty {
            return true
        }
        if settings.selectedTarget?.dnsName == peer.dnsName {
            return true
        }
        return false
    }

    private func displayName(for peer: TailnetPeer) -> String {
        if !peer.hostName.isEmpty {
            return peer.hostName
        }
        return peer.dnsName
    }

    private func serverRow(for peer: TailnetPeer, probeText: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: peer))
                    .font(.body)
                Text(peer.dnsName)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let probeText {
                Text(probeText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isSelected(peer) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }
}
