import SwiftUI

/// بوابة الإنترنت الوحيدة في التطبيق: كل اتصال يمر من هنا.
/// - `on` = زر الإنترنت (البحث في الويب) في خانة الكتابة؛ يُحفظ.
/// - لما يكون مقفول: التنزيلات والتحقق من التحديث تطلب سماح لمرة وحدة.
@MainActor
final class NetworkGate: ObservableObject {
    static let shared = NetworkGate()

    @Published var on: Bool {
        didSet { UserDefaults.standard.set(on, forKey: "netOn") }
    }
    @Published var pending: Request?

    struct Request: Identifiable {
        let id = UUID()
        let reason: String
        let done: (Bool) -> Void
    }

    private init() { on = UserDefaults.standard.bool(forKey: "netOn") }

    /// مسموح الحين؟ إذا مقفول يسأل المستخدم سماح لهالمرة بس.
    func permit(_ reason: String) async -> Bool {
        if on { return true }
        if let p = pending { p.done(false) }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            pending = Request(reason: reason) { c.resume(returning: $0) }
        }
        slog("net: one-time \(reason) -> \(ok)")
        return ok
    }

    func answer(_ ok: Bool) {
        let p = pending
        pending = nil
        p?.done(ok)
    }
}

/// تنبيه "الإنترنت مقفول" — يُركّب مرة وحدة على الواجهة الرئيسية.
struct NetworkGateAlert: ViewModifier {
    @ObservedObject var gate = NetworkGate.shared

    func body(content: Content) -> some View {
        content.alert("الإنترنت مقفول", isPresented: Binding(
            get: { gate.pending != nil },
            set: { if !$0, gate.pending != nil { gate.answer(false) } }
        )) {
            Button("اسمح هالمرة") { gate.answer(true) }
            Button("إلغاء", role: .cancel) { gate.answer(false) }
        } message: {
            Text("\(gate.pending?.reason ?? "هالعملية") يحتاج إنترنت. نسمح له هالمرة بس؟ زر الإنترنت يظل مقفول.")
        }
    }
}
