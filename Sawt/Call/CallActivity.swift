import ActivityKit
import Foundation

/// يدير نشاط المكالمة المباشر من داخل التطبيق
@MainActor
enum CallActivity {
    private static var current: Activity<CallActivityAttributes>?
    private static var last: CallActivityAttributes.ContentState?
    private static var lastBeat = Date.distantPast
    private static var timer: Timer?
    /// لو التطبيق انقتل، النشاط يصير قديم بعد دقيقتين
    private static func stale() -> Date { Date().addingTimeInterval(120) }

    /// ينهي أي نشاط باقي من تشغيل سابق (التطبيق انقفل غصب)
    static func cleanupOrphans() {
        guard current == nil, !Activity<CallActivityAttributes>.activities.isEmpty else { return }
        slog("activity: ending \(Activity<CallActivityAttributes>.activities.count) orphan(s)")
        Task { await CallActivityAttributes.endAll() }
    }

    /// عند إغلاق التطبيق: ننهي بشكل متزامن قدر الإمكان
    static func endSync() {
        current = nil; last = nil
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await CallActivityAttributes.endAll(); sem.signal() }
        _ = sem.wait(timeout: .now() + 1.5)
    }

    static func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            slog("activity: disabled by user/system")
            return
        }
        end()
        let st = CallActivityAttributes.ContentState(status: "starting", muted: false)
        do {
            current = try Activity.request(attributes: CallActivityAttributes(startedAt: Date()),
                                           content: .init(state: st, staleDate: stale()), pushType: nil)
            last = st
            lastBeat = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in
                    if let l = CallActivity.last { CallActivity.update(status: l.status, muted: l.muted) }
                }
            }
            slog("activity: started")
        } catch {
            slog("activity: request failed \(error)")
        }
    }

    static func update(status: String, muted: Bool) {
        guard let a = current else { return }
        let st = CallActivityAttributes.ContentState(status: status, muted: muted)
        // نحدّث حتى لو ما تغيّر شي كل ٣٠ ثانية عشان تاريخ الصلاحية يتجدد
        if st == last, Date().timeIntervalSince(lastBeat) < 30 { return }
        last = st
        lastBeat = Date()
        Task { await a.update(.init(state: st, staleDate: stale())) }
    }

    static func end() {
        timer?.invalidate(); timer = nil
        current = nil
        last = nil
        let olds = Activity<CallActivityAttributes>.activities   // نلتقطها الحين عشان ما ننهي نشاط جديد
        guard !olds.isEmpty else { return }
        Task { for a in olds { await a.end(nil, dismissalPolicy: .immediate) } }
        slog("activity: ended")
    }
}
