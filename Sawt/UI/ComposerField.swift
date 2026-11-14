import SwiftUI
import UIKit

/// خانة الكتابة مبنية على UITextView بدل TextField:
/// إملاء لوحة المفاتيح (مايك النظام) يخلي جلسة إدخال شغالة ويرجع يكتب النص بعد ما نفضّي الـBinding،
/// فلازم ننهي الجلسة على مستوى UIKit: unmarkText ثم resign ثم نفضي النص مباشرة ثم نرجع التركيز.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    /// يزيد مع كل إرسال: يفضي الخانة بالطريقة الآمنة
    var clearToken: Int
    var maxLines: Int = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.textAlignment = .natural
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ph = UILabel()
        ph.font = tv.font
        ph.adjustsFontForContentSizeCategory = true
        ph.textColor = .placeholderText
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.frameLayoutGuide.leadingAnchor),
            ph.trailingAnchor.constraint(lessThanOrEqualTo: tv.frameLayoutGuide.trailingAnchor),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 12),
        ])
        context.coordinator.placeholder = ph
        tv.text = text
        context.coordinator.lastToken = clearToken
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.placeholder?.text = placeholder
        if clearToken != c.lastToken {
            c.lastToken = clearToken
            c.clear(tv)
        } else if tv.markedTextRange == nil, tv.text != text, !c.clearing {
            // تغيير من البرنامج (مثلًا رجّعنا النص لما فشل الإرسال، أو نتيجة الإملاء حقنا)
            tv.text = text
        }
        c.placeholder?.isHidden = !tv.text.isEmpty
        if focused, !tv.isFirstResponder, tv.window != nil, !c.clearing {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !focused, tv.isFirstResponder, !c.clearing {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 240
        let fit = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        let line = tv.font?.lineHeight ?? 20
        let maxH = line * CGFloat(maxLines) + tv.textContainerInset.top + tv.textContainerInset.bottom
        let h = min(fit.height, maxH)
        let scroll = fit.height > maxH
        if tv.isScrollEnabled != scroll { DispatchQueue.main.async { tv.isScrollEnabled = scroll } }
        return CGSize(width: w, height: h)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        var lastToken = 0
        weak var placeholder: UILabel?
        var clearing = false
        private var sent = ""
        private var guardUntil = Date.distantPast

        init(_ p: ComposerField) { parent = p }

        func clear(_ tv: UITextView) {
            sent = tv.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasFirst = tv.isFirstResponder
            let dictating = tv.textInputMode?.primaryLanguage == "dictation"
            let marked = tv.markedTextRange != nil
            clearing = true
            if marked { tv.unmarkText() }
            // نهاية جلسة الإدخال (توقف إملاء النظام وتثبيت الاقتراحات) قبل التفضية
            if wasFirst { tv.resignFirstResponder() }
            tv.text = ""
            placeholder?.isHidden = false
            parent.text = ""
            guardUntil = Date().addingTimeInterval(1.0)
            slog("composer: cleared after send (dictation=\(dictating) marked=\(marked) focused=\(wasFirst))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.dropEcho(tv)
                self.clearing = false
                if wasFirst && !dictating { tv.becomeFirstResponder() }
            }
        }

        /// إذا رجع نفس النص المرسل (أو جزء منه) خلال ثانية بعد الإرسال، نشيله
        private func dropEcho(_ tv: UITextView) {
            let now = tv.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !now.isEmpty, !sent.isEmpty, Date() < guardUntil else { return }
            if now == sent || sent.hasPrefix(now) || (now.hasPrefix(sent) && now.count - sent.count <= 2) {
                if tv.markedTextRange != nil { tv.unmarkText() }
                tv.text = ""
                parent.text = ""
                placeholder?.isHidden = false
                slog("composer: sent text came back → cleared")
            }
        }

        func textViewDidChange(_ tv: UITextView) {
            placeholder?.isHidden = !tv.text.isEmpty
            if Date() < guardUntil { dropEcho(tv) }
            if parent.text != tv.text { parent.text = tv.text }
            tv.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if !clearing, !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if !clearing, parent.focused { parent.focused = false }
        }
    }
}
