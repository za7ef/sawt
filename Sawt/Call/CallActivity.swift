import ActivityKit
import Foundation

/// يدير نشاط المكالمة المباشر من داخل التطبيق
@MainActor
enum CallActivity {
    private static var current: Activity<CallActivityAttributes>?
    private static var last: CallActivityAttributes.ContentState?

    static func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            slog("activity: disabled by user/system")
            return
        }
        end()
        let st = CallActivityAttributes.ContentState(status: "starting", muted: false)
        do {
            current = try Activity.request(attributes: CallActivityAttributes(startedAt: Date()),
                                           content: .init(state: st, staleDate: nil), pushType: nil)
            last = st
            slog("activity: started")
        } catch {
            slog("activity: request failed \(error)")
        }
    }

    static func update(status: String, muted: Bool) {
        guard let a = current else { return }
        let st = CallActivityAttributes.ContentState(status: status, muted: muted)
        guard st != last else { return }
        last = st
        Task { await a.update(.init(state: st, staleDate: nil)) }
    }

    static func end() {
        guard let a = current else { return }
        current = nil
        last = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
        slog("activity: ended")
    }
}
