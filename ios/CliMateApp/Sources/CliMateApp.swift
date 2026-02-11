import SwiftUI

@main
struct CliMateApp: App {
    @StateObject private var logs = AppLogStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(logs)
                .environmentObject(settings)
        }
    }
}
