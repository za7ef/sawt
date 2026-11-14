import SwiftUI

@main
struct SawtApp: App {
    @StateObject private var models = ModelManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ChatStore.shared
    @StateObject private var call = CallController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(models)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(call)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { models.loadAll() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    slog("⚠️ memory warning")
                    Task { await LLMService.shared.trim() }
                    URLCache.shared.removeAllCachedResponses()
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    slog("thermal: \(ThermalWatch.label)")
                }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let accent2 = Color(red: 0.68, green: 0.45, blue: 1.0)
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.06)
}
