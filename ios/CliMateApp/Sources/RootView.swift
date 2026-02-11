import SwiftUI

private let climateAuthCallbackNotification = Notification.Name("climate.auth.callback")

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TerminalView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }

            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
        }
        .onAppear {
            AppLog.info("app started", category: "lifecycle")
        }
        .onChange(of: scenePhase) { phase in
            AppLog.info("scenePhase=\(String(describing: phase))", category: "lifecycle")
            if phase == .active {
                NotificationCenter.default.post(name: climateAuthCallbackNotification, object: nil)
            }
        }
        .onOpenURL { url in
            AppLog.info("openURL=\(url.absoluteString)", category: "deeplink")
            NotificationCenter.default.post(name: climateAuthCallbackNotification, object: url)
        }
    }
}
