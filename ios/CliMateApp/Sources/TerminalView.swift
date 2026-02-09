import SwiftUI

struct TerminalView: View {
    @StateObject private var client = CodexClient()

    @State private var urlText: String = ""
    @State private var authKeyText: String = ""
    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("http://100.x.y.z:4500", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)

                if client.connectionState == .connected {
                    Button("Disconnect") {
                        client.disconnect()
                    }
                } else {
                    Button("Connect") {
                        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = authKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        client.connect(urlString: url, authKey: key)
                    }
                    .disabled(
                        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || authKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            TextField("Tailscale auth key (tskey-...)", text: $authKeyText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(client.connectionState != .disconnected)

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

            HStack(spacing: 8) {
                TextField("Message", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
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
        .padding()
        .onAppear {
            if urlText.isEmpty {
                urlText = client.lastURL ?? ""
            }
            if authKeyText.isEmpty {
                authKeyText = (try? Keychain.getString(account: "tailscale_auth_key")) ?? ""
            }
        }
        .onChange(of: authKeyText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return
            }
            try? Keychain.setString(trimmed, account: "tailscale_auth_key")
        }
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

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        client.sendUserText(text)
    }
}
