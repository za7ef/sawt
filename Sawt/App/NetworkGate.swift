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

    /// تلقائي: يبحث بس لما السؤال يحتاج معلومة حديثة (on لازم يكون شغال)
    @Published var auto: Bool {
        didSet { UserDefaults.standard.set(auto, forKey: "netAuto") }
    }

    enum Mode { case off, auto, on }
    var mode: Mode { !on ? .off : (auto ? .auto : .on) }
    var modeLabel: String {
        switch mode { case .off: L("مغلق"); case .auto: L("تلقائي"); case .on: L("دائمًا") }
    }
    /// طافي ← تلقائي ← دايم ← طافي
    func cycle() {
        switch mode {
        case .off: auto = true; on = true
        case .auto: auto = false
        case .on: on = false
        }
    }

    private init() {
        on = UserDefaults.standard.bool(forKey: "netOn")
        auto = UserDefaults.standard.bool(forKey: "netAuto")
    }

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
            let a = UIAlertController(title: L("الإنترنت مغلق"),
                                      message: L("«%@» يحتاج إلى الإنترنت. هل تسمح بذلك هذه المرة فقط؟ سيبقى زر الإنترنت مغلقًا.", reason),
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("إلغاء"), style: .cancel) { _ in finish(false) })
            a.addAction(UIAlertAction(title: L("اسمح هذه المرة"), style: .default) { _ in finish(true) })
            // لو التنبيه ما انعرض (شاشة ثانية فوق مثلاً) أو ما أحد رد خلال دقيقة: نرفض بدل ما نعلّق
            top.present(a, animated: true) {
                MainActor.assumeIsolated { if a.presentingViewController == nil { finish(false) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                MainActor.assumeIsolated { if !resumed { a.dismiss(animated: true); finish(false) } }
            }
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
