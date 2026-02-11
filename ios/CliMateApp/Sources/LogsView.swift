import SwiftUI
import UIKit

struct LogsView: View {
    @EnvironmentObject private var logs: AppLogStore

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logs.exportedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color(.systemBackground))
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        logs.clear()
                    }
                    .disabled(logs.entries.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button("Copy") {
                            UIPasteboard.general.string = logs.exportTextNow()
                        }
                        .disabled(logs.entries.isEmpty)

                        ShareLink(item: logs.exportedText) {
                            Text("Share")
                        }
                        .disabled(logs.entries.isEmpty)
                    }
                }
            }
        }
    }
}
