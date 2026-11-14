import SwiftUI

@main
struct SawtApp: App {
    @StateObject private var models = ModelManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ChatStore.shared
    @StateObject private var call = CallController()
    @StateObject private var updater = UpdateChecker.shared
    @Environment(\.scenePhase) private var phase
    @State private var bgTask: Task<Void, Never>?

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
                .task {
                    // نخلي أول إطار يطلع قبل تحميل النموذج الثقيل
                    try? await Task.sleep(for: .milliseconds(400))
                    models.loadAll()
                    await updater.check()
                }
                .sheet(item: $updater.available) { UpdateSheet(info: $0).environment(\.layoutDirection, .rightToLeft) }
                .alert("التحديثات", isPresented: Binding(get: { updater.lastMessage != nil },
                                                        set: { if !$0 { updater.lastMessage = nil } })) {
                    Button("تمام", role: .cancel) {}
                } message: { Text(updater.lastMessage ?? "") }
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
                    if p == .background {
                        slog("background"); if !AudioIO.shared.ownedByCall { slog.stage("") }
                        Task { await LLMService.shared.trim() }
                        bgTask?.cancel()
                        bgTask = Task {
                            try? await Task.sleep(for: .seconds(180))
                            if Task.isCancelled { return }
                            await models.unloadForBackground()
                        }
                    }
                    if p == .active {
                        bgTask?.cancel(); bgTask = nil
                        slog.stage(call.state == .idle ? "idle" : "call")
                        if models.llm == .idle { models.loadAll() }
                    }
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
