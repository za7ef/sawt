import ActivityKit
import AppIntents
import Foundation

/// نشاط الوكيل المباشر (الجزيرة الديناميكية وشاشة القفل) — مشترك بين التطبيق والإضافة
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: String
        var n: Int
        var waiting: Bool
        /// مرحلة المشغّل: sleep (نايم) / ready (جاهز) / prep (يجهّز) / thinking (يفكّر) / step (الخطوة) / done (خلص)
        var phase: String? = nil
        /// هدف المهمة الحالية (النشاط نفسه يبقى من تشغيل المشغّل)
        var task: String? = nil

        var phaseTitle: String {
            switch phase ?? "step" {
            case "sleep": return L("خامل")
            case "ready": return L("جاهز")
            case "prep": return L("جارٍ التجهيز")
            case "thinking": return L("يفكّر")
            case "done": return L("انتهى")
            default: return L("الخطوة %@", String(n))
            }
        }
        var phaseIcon: String {
            switch phase ?? "step" {
            case "sleep": return "moon.zzz.fill"
            case "ready": return "power"
            case "prep": return "hourglass"
            case "thinking": return "brain"
            case "done": return "checkmark.circle.fill"
            default: return waiting ? "questionmark.circle.fill" : "wand.and.stars"
            }
        }
        /// مهمة شغّالة (يطلع زر إيقاف المهمة)
        var busy: Bool { phase == nil || phase == "thinking" || phase == "step" }
    }
    var goal: String
}

/// زر إيقاف الوكيل (ينفّذ داخل التطبيق)
struct StopAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إيقاف الوكيل"
    init() {}
    func perform() async throws -> some IntentResult {
        // التطبيق ينهي النشاط أو يرجّعه «جاهز» لو المشغّل شغّال
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.stopAgent"), object: nil) }
        return .result()
    }
}

/// زر إيقاف المشغّل كله (لما يكون نايم أو جاهز)
struct StopRunnerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إيقاف المشغّل"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.stopRunner"), object: nil) }
        return .result()
    }
}

/// موافقة على الخطوة الحساسة (من الجزيرة/شاشة القفل)
struct ApproveAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "موافقة على خطوة الوكيل"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.confirmYes"), object: nil) }
        return .result()
    }
}

/// رفض الخطوة الحساسة
struct DenyAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "رفض خطوة الوكيل"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.confirmNo"), object: nil) }
        return .result()
    }
}
