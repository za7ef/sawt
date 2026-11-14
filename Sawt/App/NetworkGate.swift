import SwiftUI
import UIKit

/// بوابة الإنترنت الوحيدة في التطبيق: كل اتصال يمر من هنا.
/// - `on` = زر الإنترنت (البحث في الويب) في خانة الكتابة؛ يُحفظ.
/// - لما يكون مقفول: التنزيلات والتحقق من التحديث تطلب سماح لمرة وحدة.
@MainActor
final class NetworkGate: ObservableObject {
    static let shared = NetworkGate()

    @Published var on: Bool {
        didSet { UserDefaults.standard.set(on, forKey: "netOn") }
    }

    private init() { on = UserDefaults.standard.bool(forKey: "netOn") }

    /// مسموح الحين؟ إذا مقفول يسأل المستخدم سماح لهالمرة بس.
    /// التنبيه يطلع من UIKit فوق أعلى شاشة (حتى لو فيه sheet مفتوح)، وإذا ما قدر يعرضه يرجع "لا" بدل ما يعلّق.
    func permit(_ reason: String) async -> Bool {
        if on { return true }
        guard let top = Self.topController() else {
            slog("net: no window to ask → denied")
            return false
        }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let finish: (Bool) -> Void = { v in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: v)
            }
            let a = UIAlertController(title: "الإنترنت مقفول",
                                      message: "\(reason) يحتاج إنترنت. نسمح له هالمرة بس؟ زر الإنترنت يظل مقفول.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in finish(false) })
            a.addAction(UIAlertAction(title: "اسمح هالمرة", style: .default) { _ in finish(true) })
            top.present(a, animated: true)
        }
        slog("net: one-time \(reason) -> \(ok)")
        return ok
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}
