import ActivityKit
import AppIntents
import Foundation

/// نشاط المكالمة المباشر (الجزيرة الديناميكية وشاشة القفل) — مشترك بين التطبيق والإضافة
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// starting / listening / thinking / speaking / paused
        var status: String
        var muted: Bool
    }
    var startedAt: Date
}

extension CallActivityAttributes.ContentState {
    var label: String {
        switch status {
        case "starting": return L("جارٍ التجهيز…")
        case "thinking": return L("يفكر…")
        case "speaking": return L("يتكلم")
        case "paused": return L("افتح التطبيق")
        default: return muted ? L("الميكروفون مكتوم") : L("يستمع")
        }
    }
    var icon: String {
        switch status {
        case "thinking": return "ellipsis.bubble.fill"
        case "speaking": return "waveform"
        case "paused": return "pause.circle.fill"
        default: return muted ? "mic.slash.fill" : "mic.fill"
        }
    }
}

/// زر إنهاء المكالمة (ينفّذ داخل التطبيق)
struct EndCallIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إنهاء المكالمة"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.endCall"), object: nil) }
        // ننهي النشاط بنفسنا حتى لو المكالمة مو موجودة
        await CallActivityAttributes.endAll()
        return .result()
    }
}

/// زر كتم المايك
struct ToggleMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "كتم الميكروفون"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.toggleMute"), object: nil) }
        return .result()
    }
}

extension CallActivityAttributes {
    /// ينهي كل أنشطة المكالمة (حتى اليتيمة من تشغيل سابق)
    static func endAll() async {
        for a in Activity<CallActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}
