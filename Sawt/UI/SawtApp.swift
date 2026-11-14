import SwiftUI

@main
struct SawtApp: App {
    @StateObject private var models = ModelManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ChatStore.shared
    @StateObject private var call = CallController()
    @Environment(\.scenePhase) private var phase

    init() {
        CrashCollector.shared.start()
        let l = Log.shared
        slog("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") prevCrashed=\(l.previousRunCrashed) at=\(l.previousStage)")
    }

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
                    slog("⚠️ memory warning: footprint=\(RAM.footprintMB)MB avail=\(RAM.availableMB)MB llm=\(AppSettings.shared.llmID) stt=\(AppSettings.shared.sttID) voice=\(AppSettings.shared.voiceID)")
                    Task { await LLMService.shared.trim() }
                    // الصوت يرجع يتحمل وقت الحاجة؛ نفكه إذا ما فيه مكالمة
                    // ما نفك شي إلا إذا الذاكرة فعلًا قليلة (iOS أحيانًا يحذّر والمتبقي كثير)
                    if !AudioIO.shared.ownedByCall, RAM.availableMB < 1000 { SpeechSynth.shared.unload() }
                    URLCache.shared.removeAllCachedResponses()
                }
                .onChange(of: phase) { _, p in
                    // الخلفية مو كراش: النظام يقفل التطبيقات اللي بالخلفية عادي
                    if p == .background { slog("background"); if !AudioIO.shared.ownedByCall { slog.stage("") } }
                    if p == .active { slog.stage(call.state == .idle ? "idle" : "call") }
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
