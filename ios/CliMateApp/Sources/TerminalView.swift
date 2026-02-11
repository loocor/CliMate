import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var client = CodexClient()

    @State private var inputText: String = ""
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack { mainContent }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            transcriptView
            inputBar
        }
        .padding()
        .navigationTitle(titleText)
        .toolbar { terminalToolbar }
        .sheet(isPresented: $showSettings, onDismiss: autoConnectIfPossible) { SettingsView() }
        .onAppear {
            if shouldPromptForSettings {
                showSettings = true
            }
            autoConnectIfPossible()
        }
        .onChange(of: settings.autoConnect) { _ in autoConnectIfPossible() }
        .onChange(of: settings.effectiveServerURLString) { _ in autoConnectIfPossible() }
        .confirmationDialog(
            "Approval Required",
            isPresented: Binding(
                get: { client.pendingApproval != nil },
                set: { newValue in
                    if !newValue {
                        client.pendingApproval = nil
                    }
                }
            ),
            presenting: client.pendingApproval
        ) { approval in
            Button("Accept") {
                client.respondToApproval(approvalId: approval.id, decision: "accept")
            }
            Button("Decline", role: .destructive) {
                client.respondToApproval(approvalId: approval.id, decision: "decline")
            }
            Button("Cancel", role: .cancel) {
                client.respondToApproval(approvalId: approval.id, decision: "cancel")
            }
        } message: { approval in
            Text(approval.summary)
        }
        .alert("Error", isPresented: Binding(
            get: { client.lastError != nil },
            set: { newValue in
                if !newValue {
                    client.lastError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                client.lastError = nil
            }
        } message: {
            Text(client.lastError ?? "")
        }
    }

    private var transcriptView: some View {
        ScrollView {
            Text(client.transcript)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, 8)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $inputText, axis: .vertical)
                .lineLimit(1 ... 4)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .textFieldStyle(.roundedBorder)
                .disabled(client.connectionState != .connected)
                .onSubmit {
                    send()
                }

            Button("Send") {
                send()
            }
            .disabled(client.connectionState != .connected)
        }
    }

    @ToolbarContentBuilder
    private var terminalToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if client.connectionState == .connected {
                    Button("Disconnect") { client.disconnect() }
                } else {
                    Button("Connect") { connectOrOpenSettings() }
                        .disabled(client.connectionState == .connecting)
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Connection status")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        client.sendUserText(text)
    }

    private var shouldPromptForSettings: Bool {
        settings.effectiveServerURLString == nil
    }

    private var titleText: String {
        settings.effectiveServerDisplayName
    }

    private func connectOrOpenSettings() {
        guard let url = settings.effectiveServerURLString, !url.isEmpty else {
            showSettings = true
            return
        }
        client.connect(urlString: url, mode: .manual)
    }

    private func autoConnectIfPossible() {
        guard settings.autoConnect else { return }
        guard client.connectionState == .disconnected else { return }
        guard let url = settings.effectiveServerURLString, !url.isEmpty else { return }
        client.connect(urlString: url, mode: .auto)
    }

    private var statusText: String {
        switch client.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    private var statusColor: Color {
        switch client.connectionState {
        case .connected: return .blue
        case .connecting: return .blue.opacity(0.6)
        case .disconnected: return .red
        }
    }
}
