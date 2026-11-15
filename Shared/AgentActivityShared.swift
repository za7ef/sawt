import ActivityKit
import AppIntents
import Foundation

/// نشاط الوكيل المباشر (الجزيرة الديناميكية وشاشة القفل) — مشترك بين التطبيق والإضافة
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: String
        var n: Int
        var waiting: Bool
    }
    var goal: String
}

/// زر إيقاف الوكيل (ينفّذ داخل التطبيق)
struct StopAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "إيقاف الوكيل"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run { NotificationCenter.default.post(name: Notification.Name("sawt.stopAgent"), object: nil) }
        for a in Activity<AgentActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        return .result()
    }
}
