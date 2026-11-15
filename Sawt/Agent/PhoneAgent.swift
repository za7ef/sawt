import SwiftUI
import UIKit
import UserNotifications
import ActivityKit
import Vision

/// الوكيل: يقرأ الشاشة → النموذج المحلي يختار خطوة وحدة (JSON) → ننفذها → نعيد. حد أقصى ١٠ خطوات.
/// أي إرسال/حذف/دفع/كلمة سر يوقف ويطلب تأكيد.
@MainActor
final class PhoneAgent: ObservableObject {
    static let shared = PhoneAgent()

    struct Step: Identifiable { let id = UUID(); let text: String }
    struct Element { let kind: String; let label: String; let value: String; let frame: CGRect; let secure: Bool }

    @Published var running = false
    @Published var goal = ""
    @Published var log: [Step] = []
    @Published var confirm: String?          // نص السؤال لما ننتظر تأكيد
    @Published var lastResult = ""

    private var task: Task<Void, Never>?
    private var activity: Activity<AgentActivityAttributes>?
    private var stepNo = 0
    private var obs: NSObjectProtocol?

    private init() {
        obs = NotificationCenter.default.addObserver(forName: Notification.Name("sawt.stopAgent"), object: nil, queue: .main) { _ in
            Task { @MainActor in PhoneAgent.shared.stop() }
        }
        AgentNotify.setup()
    }

    /// يحدّث النشاط المباشر والإشعار الثابت بالخطوة الحالية
    private func surface(_ step: String, waiting: Bool = false) {
        let st = AgentActivityAttributes.ContentState(step: step, n: stepNo, waiting: waiting)
        if let activity {
            Task { await activity.update(ActivityContent(state: st, staleDate: nil)) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: AgentActivityAttributes(goal: String(goal.prefix(60))),
                                             content: ActivityContent(state: st, staleDate: nil))
            slog("agent: activity \(activity == nil ? "failed" : "started")")
        }
        AgentNotify.progress(goal: goal, step: step)
    }

    private func unsurface() {
        let a = activity; activity = nil
        Task {
            await a?.end(nil, dismissalPolicy: .immediate)
            for x in Activity<AgentActivityAttributes>.activities { await x.end(nil, dismissalPolicy: .immediate) }
        }
        AgentNotify.clear()
    }
    private var confirmCont: CheckedContinuation<Bool, Never>?
    /// الحد الأقصى للخطوات (١٠/٢٠/٣٠) من الإعدادات
    var maxSteps: Int { let v = UserDefaults.standard.integer(forKey: "agentMaxSteps"); return [10, 20, 30].contains(v) ? v : 10 }
    /// فقاعة الحالة في المحادثة لما ينطلق من «/جوال»
    var chatTarget: (conv: UUID?, msg: UUID)?

    private func updateBubble(final: Bool = false) {
        guard let t = chatTarget else { return }
        // فقاعة الإقرار تعرض الخطوات؛ والنتيجة تنزل كرد عادي مستقل
        var lines = ["تمام، جاري تنفيذ المهمة…"]
        let steps = log.dropFirst().suffix(final ? 12 : 6).map { "• " + $0.text }
        if !steps.isEmpty { lines.append(""); lines += steps }
        if !final { lines.append("(تقدر توقفه من الإشعار أو الجزيرة)") }
        ChatStore.shared.updateText(t.msg, in: t.conv, lines.joined(separator: "\n"), save: final)
        if final {
            let res = lastResult.replacingOccurrences(of: "✅ ", with: "")
            ChatStore.shared.append(Message(role: .assistant, text: lastResult.hasPrefix("✅") ? "خلصت: \(res)" : "ما كملت المهمة: \(res)"), to: t.conv)
            chatTarget = nil
        }
    }

    // ───── التشغيل والإيقاف ─────
    func start(_ goal: String) {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !running else { return }
        guard PhoneControl.available, PhoneControl.hasPairing else {
            lastResult = "التحكم بالجوال مو جاهز (اقتران/الأداة)"
            if let t = chatTarget { ChatStore.shared.updateText(t.msg, in: t.conv, "🤖 " + lastResult, save: true); chatTarget = nil }
            return
        }
        self.goal = g; log = []; lastResult = ""; running = true; stepNo = 0
        say("الهدف: \(g)")
        surface("يبدأ…")
        task = Task { await self.loop() }
    }

    func stop() {
        task?.cancel()
        answer(false)
        if running { say("⏹️ انوقف") }
        finish("انوقف بطلبك")
    }

    func answer(_ yes: Bool) {
        confirm = nil
        confirmCont?.resume(returning: yes); confirmCont = nil
    }

    private func finish(_ r: String) {
        guard running else { return }
        running = false; lastResult = r
        updateBubble(final: true)
        unsurface()
        AgentNotify.done(r)
        HostPairing.shared.keepAlive(false)
        slog("agent: finish \(r)")
    }

    private func say(_ s: String) {
        log.append(Step(text: s)); slog("agent: \(s.prefix(300))")
        if running { stepNo += s.first?.isNumber == true ? 1 : 0; surface(s); updateBubble() }
    }

    // ───── الحلقة ─────
    private func loop() async {
        // يبقى صاحي لما نطلع لتطبيقات ثانية
        HostPairing.shared.keepAlive(true)
        if Self.see == .share { ScreenShare.shared.start() }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "agent") { }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        let tl = Date()
        let lo = await Self.exec(.liveOpen)
        Self.useLive = lo.contains("\"ok\":true")
        slog("agent: live session \(Self.useLive ? "open" : "failed") \(Int(Date().timeIntervalSince(tl) * 1000))ms \(Self.useLive ? "" : String(lo.prefix(160)))")
        defer { Self.useLive = false; Task { _ = await Self.exec(.liveClose) } }
        if await shortcut() { return }
        // اختصار: لو الهدف يذكر تطبيق معروف نفتحه مباشرة قبل النموذج
        if let app = Self.mentionedApp(goal) {
            let t = Date()
            let o = await openApp(app)
            say("1. افتح \(app)" + (o.ok ? "" : " ⚠️"))
            slog("agent: timing pre-open action=\(Int(Date().timeIntervalSince(t) * 1000))ms")
            if o.ok, Self.isOnlyOpen(goal) { finish("✅ فتحت \(app)"); return }
        }
        if Task.isCancelled { return }
        var history: [String] = []
        var fails = 0
        var lastFailed = false
        for n in 1...maxSteps {
            if Task.isCancelled { return }
            let tAX = Date()
            guard let scr = await readScreen() else {
                fails += 1
                if fails >= 2 { finish("ما قدرت أقرأ الشاشة"); return }
                try? await Task.sleep(nanoseconds: 800_000_000); continue
            }
            let (app, els) = scr
            let axMs = Int(Date().timeIntervalSince(tAX) * 1000)
            let tLLM = Date()
            let screenText = Self.describe(app: app, els)
            let user = """
            الهدف: \(goal)
            الخطوات السابقة: \(history.isEmpty ? "لا شيء" : history.suffix(6).joined(separator: " ← "))
            الخطوة رقم \(n) من \(maxSteps).
            الشاشة الحالية:
            \(screenText)
            """
            var raw = ""
            var action: [String: Any]?
            let img = await visionImage(els, lastFailed: lastFailed)
            let userV = img == nil ? user : user + "\n\n[مرفقة صورة الشاشة. الأرقام المرسومة على المربعات هي نفس أرقام العناصر.]"
            for attempt in 0..<2 {
                raw = await ask(userV + (attempt == 1 ? "\n\nردك السابق ما كان JSON صالح. رد بسطر JSON واحد فقط." : ""), image: img)
                action = Self.parse(raw)
                if action != nil { break }
            }
            if Task.isCancelled { return }
            let llmMs = Int(Date().timeIntervalSince(tLLM) * 1000)
            guard let first = action, let kind0 = first["action"] as? String else {
                say("⚠️ رد غير مفهوم: \(raw.prefix(120))"); finish("النموذج ما رد بخطوة صالحة"); return
            }
            _ = kind0
            let acts = Self.actions(raw)
            var actMs = 0
            for action in acts {
                guard let kind = action["action"] as? String else { continue }
                let desc = Self.describeAction(action, els)
                say("\(n). \(desc)")
                if kind == "done" {
                    let sum = (action["summary"] as? String) ?? "خلصت"
                    finish("✅ \(sum)"); return
                }
                if let why = Self.sensitive(action, els) {
                    let ok = await askConfirm("\(why)\n\(desc)\nأكمل؟")
                    if Task.isCancelled { return }
                    if !ok { say("رفضت — وقفت"); finish("انلغى قبل خطوة حساسة"); return }
                }
                let tA = Date()
                let r = await perform(kind, action, els)
                actMs += Int(Date().timeIntervalSince(tA) * 1000)
                history.append(desc + (r.ok ? "" : " (فشل: \(r.info.prefix(60)))"))
                lastFailed = !r.ok
                if !r.ok { say("⚠️ \(r.info.prefix(160))"); break }
                if Task.isCancelled { return }
                // عناصر الشاشة تتغير بعد اللمس: ما نكمل بأرقام قديمة إلا للكتابة/الإدخال
                if kind == "tap" || kind == "open" || kind == "back" || kind == "home" { if acts.count > 1 { try? await Task.sleep(nanoseconds: 400_000_000) } }
            }
            slog("agent: timing step=\(n) ax=\(axMs)ms llm=\(llmMs)ms action=\(actMs)ms els=\(els.count) acts=\(acts.count)")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        finish("وصلت الحد (\(maxSteps) خطوات) قبل ما أخلص")
    }

    private func askConfirm(_ q: String) async -> Bool {
        say("❓ \(q)")
        confirm = q
        surface("ينتظر تأكيدك", waiting: true)
        AgentNotify.agentConfirm(q)
        return await withCheckedContinuation { c in confirmCont = c }
    }

    // ───── النموذج ─────
    static let system = """
    أنت وكيل يتحكم بجوال iPhone نيابة عن المستخدم. كل مرة تشوف وصف الشاشة كقائمة عناصر مرقّمة، وتختار خطوة وحدة بس.
    رد بسطر JSON واحد فقط بدون أي كلام ثاني، بأحد هذي الأشكال:
    {"action":"tap","id":3}
    {"action":"type","text":"النص"}   (يكتب في الخانة المفتوحة؛ اضغط على الخانة أول لو ما كانت مفتوحة)
    {"action":"enter"}               (زر الإدخال/إرسال في الكيبورد)
    {"action":"swipe","dir":"up"}     (up يمرر لتحت المحتوى، down لفوق، left، right)
    {"action":"open","app":"WhatsApp"}
    {"action":"back"}
    {"action":"home"}
    {"action":"done","summary":"وش سويت باختصار"}
    لو واضح تقدر ترجع حتى ٣ خطوات مرة وحدة: {"actions":[{"action":"tap","id":2},{"action":"type","text":"هلا"}]}
    في open اكتب اسم التطبيق بالإنجليزي إذا تعرفه (Notes, Settings, WhatsApp...).
    قواعد: لا تخترع أرقام عناصر غير موجودة. لو الهدف تحقق قل done. لو انحسبت نفس الخطوة مرتين بدون تغيير جرّب شي ثاني.
    """

    private func ask(_ user: String, image: URL? = nil) async -> String {
        var out = ""
        do {
            let st = try await LLMService.shared.stream(system: Self.system, history: [], user: user, maxTokens: 60,
                                                        images: image.map { [$0] } ?? [])
            for try await c in st {
                out += c
                if out.contains("}"), !out.contains("\"actions\""), Self.parse(out) != nil { break }
                if out.contains("]"), out.hasSuffix("}") || out.hasSuffix("}\n"), !Self.actions(out).isEmpty { break }
            }
        } catch { slog("agent: llm error \(error)") }
        return out
    }

    /// يقبل خطوة وحدة أو {"actions":[...]} (حتى ٣ خطوات)
    static func actions(_ s: String) -> [[String: Any]] {
        guard let a = s.firstIndex(of: "{") else { return [] }
        if let d = try? JSONSerialization.jsonObject(with: Data(String(s[a...]).utf8)) as? [String: Any],
           let arr = d["actions"] as? [[String: Any]] { return Array(arr.filter { valid($0) }.prefix(3)) }
        if let one = parse(s) { return [one] }
        return []
    }
    static func valid(_ o: [String: Any]) -> Bool {
        guard let k = o["action"] as? String else { return false }
        return ["tap", "type", "enter", "swipe", "open", "back", "home", "done"].contains(k)
    }

    static func firstJSONArray(_ s: String) -> String {
        guard let a = s.firstIndex(of: "[") else { return "[]" }
        var depth = 0
        for i in s[a...].indices {
            if s[i] == "[" { depth += 1 }
            if s[i] == "]" { depth -= 1; if depth == 0 { return String(s[a...i]) } }
        }
        return "[]"
    }

    /// اختبار المطابقة: يرجع سطر لكل حالة (المتوقع ← الناتج)
    static func matchSelfTest() -> [String] {
        let cases: [(String, String)] = [
            ("روح تطبيق متصفح Google", "com.google.chrome.ios"),
            ("متصفح قوقل", "com.google.chrome.ios"),
            ("Google", "com.google.GoogleMobile"),
            ("قوقل ماب", "com.google.Maps"),
            ("خرائط قوقل", "com.google.Maps"),
            ("الخرائط", "com.apple.Maps"),
            ("المتصفح", "com.apple.mobilesafari"),
            ("الملاحظات", "com.apple.mobilenotes"),
            ("ملاحظات", "com.apple.mobilenotes"),
            ("الاعدادات", "com.apple.Preferences"),
            ("واتساب", "net.whatsapp.WhatsApp"),
            ("الساعه", "com.apple.mobiletimer"),
            ("Notes", "com.apple.mobilenotes"),
        ]
        return cases.map { c in
            let got = lookup(c.0)?.bundle ?? "nil"
            return "\(got == c.1 ? "✅" : "❌") «\(c.0)» → \(got)"
        }
    }

    /// بس لو الهدف يبدأ بـ«افتح/open/شغّل» + اسم تطبيق من الجدول بعده مباشرة
    static func mentionedApp(_ g: String) -> String? {
        let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = ["افتح", "إفتح", "open", "شغّل", "شغل"].first(where: { t.lowercased().hasPrefix($0) }) else { return nil }
        let rest = t.dropFirst(v.count).trimmingCharacters(in: .whitespaces)
        let words = rest.split(separator: " ").map(String.init)
        // نجرب أول كلمة، وأول كلمتين، وأول ثلاث (أسماء مثل «واتساب للأعمال»)، والأطول يفوز
        for n in stride(from: min(3, words.count), through: 1, by: -1) {
            var cand = words.prefix(n).joined(separator: " ")
            if cand.hasPrefix("و") && n == 1 && lookup(cand) == nil { cand = String(cand.dropFirst()) }
            if let e = lookup(cand), !e.bundle.isEmpty { return cand }
        }
        return nil
    }
    static func isOnlyOpen(_ g: String) -> Bool {
        let w = g.split(separator: " ")
        return w.count <= 3 && (g.hasPrefix("افتح") || g.lowercased().hasPrefix("open") || g.hasPrefix("شغل") || g.hasPrefix("شغّل"))
    }

    static func parse(_ s: String) -> [String: Any]? {
        guard let a = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        for i in s[a...].indices {
            if s[i] == "{" { depth += 1 }
            if s[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        guard let end else { return nil }
        let j = String(s[a...end])
        guard let o = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any] else { return nil }
        if let arr = o["actions"] as? [[String: Any]], let f = arr.first(where: { valid($0) }) { return f }
        guard let k = o["action"] as? String,
              ["tap", "type", "enter", "swipe", "open", "back", "home", "done"].contains(k) else { return nil }
        return o
    }

    // ───── الشاشة ─────
    private func readScreen() async -> (String, [Element])? {
        let r = await Self.exec(.screen(4000))
        guard let d = try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any],
              d["ok"] as? Bool == true else { say("⚠️ قراءة الشاشة: \(r.prefix(160))"); return nil }
        let app = ((d["app"] as? [String: Any])?["name"] as? String) ?? "؟"
        var els: [Element] = []
        for e in (d["elements"] as? [[String: Any]]) ?? [] {
            guard let f = e["f"] as? [Double], f.count == 4 else { continue }
            els.append(Element(kind: e["k"] as? String ?? "other",
                               label: (e["l"] as? String) ?? (e["p"] as? String) ?? "",
                               value: e["v"] as? String ?? "",
                               frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]),
                               secure: e["sec"] as? Bool ?? false))
        }
        let b = UIScreen.main.bounds
        els = els.filter { $0.frame.intersects(b) }
        els = Array(els.prefix(40))
        // مشاركة الشاشة + المعالج (خلفية): ما فيه رؤية للنموذج، فنقرأ النص من الصورة ونضيفه كعناصر قابلة للضغط
        if Self.see == .share, LLMService.onCPU {
            let extra = await ocrElements(existing: els)
            els += extra.prefix(max(0, 55 - els.count))
        }
        return (app, els)
    }

    static func describe(app: String, _ els: [Element]) -> String {
        var lines = ["التطبيق: \(app)"]
        for (i, e) in els.enumerated() {
            var l = "[\(i)] \(e.kind)"
            if !e.label.isEmpty { l += " \"\(e.label.prefix(30))\"" }
            if !e.value.isEmpty && e.value != e.label { l += " = \"\(e.value.prefix(20))\"" }
            if e.secure { l += " (كلمة سر)" }
            lines.append(l)
        }
        if els.isEmpty { lines.append("(ما فيه عناصر مقروءة)") }
        return lines.joined(separator: "\n")
    }

    static func describeAction(_ a: [String: Any], _ els: [Element]) -> String {
        let k = a["action"] as? String ?? "?"
        switch k {
        case "tap":
            let i = (a["id"] as? Int) ?? -1
            return "اضغط [\(i)] \(els.indices.contains(i) ? els[i].label : "؟")"
        case "type": return "اكتب «\((a["text"] as? String ?? "").prefix(60))»"
        case "enter": return "إدخال"
        case "swipe": return "سحب \(a["dir"] as? String ?? "")"
        case "open": return "افتح \(a["app"] as? String ?? "")"
        case "back": return "رجوع"
        case "home": return "الشاشة الرئيسية"
        case "done": return "خلصت"
        default: return k
        }
    }

    static let riskyWords = ["send", "إرسال", "ارسال", "أرسل", "ارسل", "delete", "حذف", "احذف", "مسح", "remove", "pay", "ادفع",
                             "دفع", "buy", "شراء", "اشتر", "purchase", "subscribe", "اشترك", "transfer", "تحويل", "حوّل",
                             "call", "اتصال", "اتصل", "post", "نشر", "انشر", "confirm", "تأكيد"]

    static func sensitive(_ a: [String: Any], _ els: [Element]) -> String? {
        let k = a["action"] as? String ?? ""
        if k == "tap", let i = a["id"] as? Int, els.indices.contains(i) {
            let l = els[i].label.lowercased()
            if l.split(separator: " ").count <= 4, riskyWords.contains(where: { l.contains($0) }) { return "خطوة حساسة (إرسال/حذف/دفع)." }
        }
        if k == "type", els.contains(where: { $0.secure }) { return "فيه خانة كلمة سر على الشاشة." }
        if k == "enter" { return "زر الإدخال ممكن يرسل." }
        return nil
    }

    // ───── التنفيذ ─────
    private static func norm(_ p: CGPoint) -> (UInt16, UInt16) {
        let b = UIScreen.main.bounds
        let x = max(0, min(65535, p.x / b.width * 65535)), y = max(0, min(65535, p.y / b.height * 65535))
        return (UInt16(x), UInt16(y))
    }

    private func perform(_ kind: String, _ a: [String: Any], _ els: [Element]) async -> (ok: Bool, info: String) {
        func ok(_ r: String) -> (Bool, String) { (r.contains("\"ok\":true"), r) }
        switch kind {
        case "tap":
            guard let i = a["id"] as? Int, els.indices.contains(i) else { return (false, "رقم عنصر غلط") }
            let f = els[i].frame
            let (x, y) = Self.norm(CGPoint(x: f.midX, y: f.midY))
            return ok(await Self.exec(.tap(x, y)))
        case "type":
            let t = a["text"] as? String ?? ""
            return ok(await Self.typeText(t))
        case "enter":
            return ok(await Self.exec(.keys("return")))
        case "home":
            return ok(await Self.exec(.keys("home")))
        case "back":
            // سحب من الحافة اليسار
            let (x1, y) = Self.norm(CGPoint(x: 2, y: UIScreen.main.bounds.midY))
            let (x2, _) = Self.norm(CGPoint(x: UIScreen.main.bounds.width * 0.75, y: 0))
            return ok(await Self.exec(.drag(x1, y, x2, y)))
        case "swipe":
            let b = UIScreen.main.bounds
            let c = CGPoint(x: b.midX, y: b.midY)
            let dir = (a["dir"] as? String ?? "up").lowercased()
            var p1 = c, p2 = c
            switch dir {
            case "down": p1.y = b.height * 0.3; p2.y = b.height * 0.75
            case "left": p1.x = b.width * 0.85; p2.x = b.width * 0.15
            case "right": p1.x = b.width * 0.15; p2.x = b.width * 0.85
            default: p1.y = b.height * 0.75; p2.y = b.height * 0.3
            }
            let (x1, y1) = Self.norm(p1), (x2, y2) = Self.norm(p2)
            return ok(await Self.exec(.drag(x1, y1, x2, y2)))
        case "open":
            let app = (a["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { return (false, "اسم التطبيق فاضي") }
            return await openApp(app)
        default:
            return (false, "خطوة غير معروفة")
        }
    }

    // ───── النظر ─────
    /// طريقة رؤية الشاشة: قراءة النصوص (الافتراضي) أو مشاركة الشاشة (صورة + أرقام العناصر)
    enum See: String, CaseIterable { case ax, share
        var title: String { self == .ax ? "قراءة النصوص" : "مشاركة الشاشة" }
    }
    static var see: See {
        get { See(rawValue: UserDefaults.standard.string(forKey: "agentSee") ?? "") ?? .ax }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agentSee") }
    }

    /// صورة الشاشة مصغّرة مع أرقام العناصر مرسومة عليها: من البث لو شغّال، وإلا لقطة من خدمة الأدوات
    private func visionImage(_ els: [Element], lastFailed: Bool) async -> URL? {
        guard Self.see == .share else { return nil }
        if LLMService.onCPU { slog("agent: vision skipped (cpu/llama.cpp, no mmproj) — text only"); return nil }
        guard await ModelManager.shared.ensureVision() else { slog("agent: vision unavailable"); return nil }
        guard let fr = await currentFrame() else { return nil }
        let (img, src) = fr
        let mode = src
        let w: CGFloat = 448
        let size = CGSize(width: w, height: (img.size.height / img.size.width * w).rounded())
        let pts = UIScreen.main.bounds.size
        let k = size.width / pts.width
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            img.draw(in: CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            for (i, e) in els.enumerated() {
                let f = CGRect(x: e.frame.minX * k, y: e.frame.minY * k, width: e.frame.width * k, height: e.frame.height * k)
                c.setStrokeColor(UIColor.systemRed.cgColor); c.setLineWidth(1.5); c.stroke(f)
                let tag = "\(i)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.white]
                let ts = tag.size(withAttributes: attrs)
                let bg = CGRect(x: f.minX, y: max(0, f.minY - ts.height), width: ts.width + 4, height: ts.height)
                c.setFillColor(UIColor.systemRed.cgColor); c.fill(bg)
                tag.draw(at: CGPoint(x: bg.minX + 2, y: bg.minY), withAttributes: attrs)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-shot-\(UUID().uuidString.prefix(6)).jpg")
        guard let d = out.jpegData(compressionQuality: 0.8), (try? d.write(to: url)) != nil else { return nil }
        slog("agent: vision on (\(mode)) \(Int(size.width))x\(Int(size.height)) \(d.count / 1024)KB els=\(els.count)")
        return url
    }

    /// آخر إطار من البث، وإلا لقطة شاشة
    private func currentFrame() async -> (UIImage, String)? {
        if let d = ScreenShare.shared.latest, let i = UIImage(data: d) { return (i, "broadcast") }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("agent-shot.png")
        let r = await Self.exec(.shot(raw.path))
        if r.contains("\"ok\":true"), let i = UIImage(contentsOfFile: raw.path) { return (i, "screenshot") }
        slog("agent: shot failed \(r.prefix(200))")
        return nil
    }

    /// OCR (Apple Vision، عربي + إنجليزي) على صورة الشاشة → عناصر نص جديدة ما تكررت مع عناصر الوصول
    private func ocrElements(existing: [Element]) async -> [Element] {
        guard let fr = await currentFrame(), let cg = fr.0.cgImage else { return [] }
        let src = fr.1
        let t0 = Date()
        func run(cpu: Bool) throws -> [VNRecognizedTextObservation] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            req.recognitionLanguages = ["ar-SA", "en-US"]
            req.usesLanguageCorrection = false
            if cpu { req.usesCPUOnly = true }
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            return req.results ?? []
        }
        var obs: [VNRecognizedTextObservation] = []
        var how = "default"
        do { obs = try run(cpu: false) } catch {
            slog("agent: ocr error (default) \(error) — retry cpu-only")
            how = "cpu"
            do { obs = try run(cpu: true) } catch { slog("agent: ocr error (cpu) \(error)"); return [] }
        }
        let b = UIScreen.main.bounds
        var out: [Element] = []
        for o in obs {
            guard let t = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), t.count >= 2 else { continue }
            let r = o.boundingBox  // مطبّع، الأصل تحت يسار
            let f = CGRect(x: r.minX * b.width, y: (1 - r.maxY) * b.height, width: r.width * b.width, height: r.height * b.height)
            let dup = existing.contains { e in
                (!e.label.isEmpty && (e.label.contains(t) || t.contains(e.label))) && e.frame.intersects(f)
            }
            if !dup { out.append(Element(kind: "ocr", label: String(t.prefix(40)), value: "", frame: f, secure: false)) }
        }
        slog("agent: ocr src=\(src) via=\(how) \(Int(Date().timeIntervalSince(t0) * 1000))ms found=\(obs.count) added=\(out.count)")
        return out
    }

    /// كل الكتابة عن طريق الحافظة + Cmd+V (مستقلة عن لغة الكيبورد)
    static func typeText(_ t: String) async -> String {
        // دايمًا عن طريق الحافظة: أكواد HID تعتمد على لغة الكيبورد (العربي يقلب hello لحروف عربية)
        let hex = t.unicodeScalars.prefix(24).map { String(format: "%04X", $0.value) }.joined(separator: " ")
        slog("agent: type via=paste text=«\(t)» u=[\(hex)]")
        return await exec(.keys("paste:" + t))
    }

    /// جدول التطبيقات الشائعة: الاسم (عربي/إنجليزي) → معرّف الحزمة + الاسم الإنجليزي
    static let apps: [(names: [String], bundle: String, en: String)] = [
        (["الملاحظات", "ملاحظات", "notes"], "com.apple.mobilenotes", "Notes"),
        (["الإعدادات", "الاعدادات", "اعدادات", "إعدادات", "settings"], "com.apple.Preferences", "Settings"),
        (["الكاميرا", "كاميرا", "camera"], "com.apple.camera", "Camera"),
        (["الصور", "صور", "photos"], "com.apple.mobileslideshow", "Photos"),
        (["واتساب", "واتس", "الواتس", "whatsapp"], "net.whatsapp.WhatsApp", "WhatsApp"),
        (["واتساب للأعمال", "واتس أعمال", "whatsapp business"], "net.whatsapp.WhatsAppSMB", "WhatsApp Business"),
        (["يوتيوب", "اليوتيوب", "youtube"], "com.google.ios.youtube", "YouTube"),
        (["سفاري", "المتصفح", "safari"], "com.apple.mobilesafari", "Safari"),
        (["الرسائل", "رسائل", "messages", "imessage"], "com.apple.MobileSMS", "Messages"),
        (["الساعة", "ساعة", "المنبه", "منبه", "clock", "alarm"], "com.apple.mobiletimer", "Clock"),
        (["التقويم", "تقويم", "calendar"], "com.apple.mobilecal", "Calendar"),
        (["الخرائط", "خرائط", "maps"], "com.apple.Maps", "Maps"),
        (["قوقل ماب", "قوقل مابس", "خرائط قوقل", "خرائط جوجل", "جوجل ماب", "google maps"], "com.google.Maps", "Google Maps"),
        (["قوقل", "جوجل", "google", "تطبيق قوقل", "بحث قوقل"], "com.google.GoogleMobile", "Google"),
        (["كروم", "متصفح كروم", "متصفح قوقل", "متصفح جوجل", "متصفح google", "chrome", "google chrome"], "com.google.chrome.ios", "Chrome"),
        (["متجر التطبيقات", "اب ستور", "آب ستور", "app store"], "com.apple.AppStore", "App Store"),
        (["الهاتف", "هاتف", "phone"], "com.apple.mobilephone", "Phone"),
        (["جهات الاتصال", "الأسماء", "contacts"], "com.apple.MobileAddressBook", "Contacts"),
        (["البريد", "الايميل", "الإيميل", "mail"], "com.apple.mobilemail", "Mail"),
        (["جيميل", "gmail"], "com.google.Gmail", "Gmail"),
        (["التذكيرات", "تذكيرات", "reminders"], "com.apple.reminders", "Reminders"),
        (["الحاسبة", "حاسبة", "calculator"], "com.apple.calculator", "Calculator"),
        (["الملفات", "ملفات", "files"], "com.apple.DocumentsApp", "Files"),
        (["الطقس", "طقس", "weather"], "com.apple.weather", "Weather"),
        (["الموسيقى", "ميوزك", "music"], "com.apple.Music", "Music"),
        (["الصحة", "health"], "com.apple.Health", "Health"),
        (["المحفظة", "wallet"], "com.apple.Passbook", "Wallet"),
        (["فيس تايم", "facetime"], "com.apple.facetime", "FaceTime"),
        (["تيك توك", "تيكتوك", "tiktok"], "com.zhiliaoapp.musically", "TikTok"),
        (["سناب", "سناب شات", "snapchat"], "com.toyopagroup.picaboo", "Snapchat"),
        (["انستقرام", "انستا", "instagram"], "com.burbn.instagram", "Instagram"),
        (["تويتر", "اكس", "إكس", "x", "twitter"], "com.atebits.Tweetie2", "X"),
        (["تلقرام", "تيليجرام", "telegram"], "ph.telegra.Telegraph", "Telegram"),
        (["كرنشي رول", "crunchyroll"], "com.crunchyroll.iphone", "Crunchyroll"),
        (["صوت", "sawt"], "", "Sawt"),
    ]

    static func normName(_ x: String) -> String {
        var t = String(x.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
        for (f, r) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ٱ", "ا"), ("ة", "ه"), ("ى", "ي"), ("ؤ", "و"), ("ئ", "ي")] {
            t = t.replacingOccurrences(of: f, with: r)
        }
        if t.hasPrefix("ال"), t.count > 3 { t = String(t.dropFirst(2)) }
        return t
    }

    /// تطابق تام بس (بعد التطبيع) على العبارة كاملة — ما فيه "يحتوي" عشان ما يفتح تطبيق غلط
    static func lookup(_ name: String) -> (bundle: String, en: String)? {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for p in ["روح ", "افتح ", "إفتح ", "شغّل ", "شغل ", "open ", "تطبيق ", "برنامج ", "app ", "the "] where n.lowercased().hasPrefix(p) {
                n = String(n.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); changed = true
            }
        }
        let k = normName(n)
        // كلمات وصفية: متصفح/browser → كروم لو ذكر قوقل/كروم، وإلا سفاري؛ خرائط + قوقل → خرائط قوقل
        let l = n.lowercased()
        let google = ["قوقل", "جوجل", "google", "كروم", "chrome"].contains { l.contains($0) }
        if ["متصفح", "browser"].contains(where: { l.contains($0) }) {
            return google ? ("com.google.chrome.ios", "Chrome") : ("com.apple.mobilesafari", "Safari")
        }
        if ["خرائط", "ماب", "maps"].contains(where: { l.contains($0) }), google { return ("com.google.Maps", "Google Maps") }
        for e in apps where e.names.contains(where: { normName($0) == k }) || normName(e.en) == k { return (e.bundle, e.en) }
        return nil
    }

    /// جدول → إطلاق بالمعرّف؛ بعدها مطابقة من التطبيقات المثبتة؛ آخر شي البحث بالاسم الإنجليزي
    func openApp(_ name: String) async -> (ok: Bool, info: String) {
        let hit = Self.lookup(name)
        slog("agent: open requested=«\(name)» table=\(hit?.bundle ?? "none")")
        if let hit, !hit.bundle.isEmpty {
            let r = await Self.exec(.launch(hit.bundle))
            slog("agent: open chosen=\(hit.bundle) via=table ok=\(r.contains("\"ok\":true"))")
            if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 700_000_000); return (true, r) }
            say("⚠️ إطلاق \(hit.bundle): \(r.prefix(120))")
        }
        let q = hit?.en ?? name
        let r = await Self.exec(.launch(q))
        // السجل فيه المرشحين ودرجاتهم (خطوة match)
        slog("agent: open match «\(q)» → \(r.prefix(600))")
        if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 700_000_000); return (true, r) }
        // غامض: نسأله عن أقوى مرشح بدل ما نخمّن
        let err = ((try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: Any])?["error"] as? String ?? ""
        if err.hasPrefix("ambiguous: "),
           let cands = (try? JSONSerialization.jsonObject(with: Data(Self.firstJSONArray(err).utf8))) as? [[String: Any]],
           cands.count >= 2 {
            let names = cands.prefix(3).compactMap { $0["name"] as? String }
            let ok = await askConfirm("لقيت أكثر من تطبيق لـ«\(name)»: \(names.joined(separator: "، ")).\nأفتح «\(names[0])»؟")
            if ok, let bid = cands[0]["bundle"] as? String {
                let r3 = await Self.exec(.launch(bid))
                slog("agent: open chosen=\(bid) via=user-confirm")
                if r3.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 700_000_000); return (true, r3) }
            }
        }
        // ما لقينا أو رفض: بحث سبوتلايت باسم التطبيق (لصق، يشتغل على أي لغة كيبورد)
        say("ما تأكدت من «\(name)» — أبحث عنه")
        _ = await Self.exec(.keys("home"))
        try? await Task.sleep(nanoseconds: 600_000_000)
        let b = UIScreen.main.bounds
        let (x, y1) = Self.norm(CGPoint(x: b.midX, y: b.height * 0.4)), (_, y2) = Self.norm(CGPoint(x: 0, y: b.height * 0.65))
        _ = await Self.exec(.drag(x, y1, x, y2))
        try? await Task.sleep(nanoseconds: 800_000_000)
        _ = await Self.typeText(q)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let r2 = await Self.exec(.keys("return"))
        slog("agent: open chosen=spotlight «\(q)»")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return (r2.contains("\"ok\":true"), r2)
    }

    /// اختصار بدون النموذج: «افتح الملاحظات وأنشئ ملاحظة جديدة واكتب ...»
    /// يرجع true إذا خلص المهمة
    private func shortcut() async -> Bool {
        let g = goal
        let wantsNote = ["ملاحظة جديدة", "ملاحظه جديده", "new note", "أنشئ ملاحظة", "انشئ ملاحظة", "سو ملاحظة", "سوّ ملاحظة"].contains { g.lowercased().contains($0) }
        let text: String? = {
            for k in ["واكتب فيها", "واكتب", "اكتب فيها", "اكتب", "and type", "type", "write"] {
                if let r = g.range(of: k, options: .caseInsensitive) {
                    let t = g[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :«»\"'،,"))
                    return t.isEmpty ? nil : t
                }
            }
            return nil
        }()
        guard wantsNote || (g.contains("الملاحظات") && text != nil) else { return false }
        say("⚡ اختصار: ملاحظة جديدة")
        let o = await openApp("notes")
        say("1. افتح الملاحظات" + (o.ok ? "" : " ⚠️"))
        guard o.ok, !Task.isCancelled else { return false }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let scr = await readScreen() else { return false }
        let keys = ["new note", "ملاحظة جديدة", "compose", "إنشاء", "create note"]
        guard let i = scr.1.firstIndex(where: { e in keys.contains { e.label.lowercased().contains($0) } }) else {
            say("ما لقيت زر ملاحظة جديدة — أكمل بالنموذج"); return false
        }
        let f = scr.1[i].frame
        let (x, y) = Self.norm(CGPoint(x: f.midX, y: f.midY))
        _ = await Self.exec(.tap(x, y))
        say("2. اضغط «\(scr.1[i].label)»")
        guard let text else { finish("✅ فتحت ملاحظة جديدة"); return true }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let r = await Self.typeText(text)
        say("3. اكتب «\(text)»" + (r.contains("\"ok\":true") ? "" : " ⚠️"))
        guard r.contains("\"ok\":true") else { return false }
        finish("✅ أنشأت ملاحظة وكتبت «\(text)»")
        return true
    }

    /// ينفذ أمر sawtctl بنفس إعداد الاتصال حق شاشة الاختبار
    static func exec(_ op: PhoneControl.Op) async -> String {
        let info = PhoneControl.storedInfo()
        var port: UInt16 = 0
        if info.contains("kind=RemotePairing") {
            if cachedPort == 0 { cachedPort = await PhoneControl.discoverRPPort().port }
            port = cachedPort
        }
        let h = UserDefaults.standard.string(forKey: "pcHost") ?? "10.7.0.1"
        var op = op
        if useLive, let j = liveJSON(op) { op = .live(j) }
        let r = await PhoneControl.run(op, host: h, rpPort: port, rpHost: PhoneControl.lastRPHost)
        if !r.contains("\"ok\":true") { cachedPort = 0 }
        return r
    }
    private static var cachedPort: UInt16 = 0
    /// أثناء تشغيل الوكيل: كل الأوامر على جلسة وحدة مفتوحة (بدون اتصال/تحقق/بث جديد كل خطوة)
    static var useLive = false

    static func liveJSON(_ op: PhoneControl.Op) -> String? {
        let d: [String: Any]
        switch op {
        case .tap(let x, let y): d = ["op": "tap", "x": Int(x), "y": Int(y)]
        case .drag(let a, let b, let x, let y): d = ["op": "drag", "x1": Int(a), "y1": Int(b), "x2": Int(x), "y2": Int(y)]
        case .keys(let w): d = ["op": "keys", "what": w]
        case .screen(let ms): d = ["op": "screen", "wait": Int(ms)]
        case .launch(let q): d = ["op": "launch", "q": q]
        default: return nil
        }
        return (try? JSONSerialization.data(withJSONObject: d)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// إشعارات الوكيل: ثابت بزر «إيقاف» + تأكيد بزرين
enum AgentNotify {
    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
            let id = r.actionIdentifier
            await MainActor.run {
                switch id {
                case "agent.stop": PhoneAgent.shared.stop()
                case "agent.yes": PhoneAgent.shared.answer(true)
                case "agent.no": PhoneAgent.shared.answer(false)
                default: break
                }
            }
        }
        func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
            // داخل التطبيق: نخفي إشعار التقدم (الشاشة تعرضه)، ونعرض الباقي
            n.request.identifier == "agent-progress" ? [] : [.banner, .sound]
        }
    }
    static let delegate = Delegate()

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        let stop = UNNotificationAction(identifier: "agent.stop", title: "إيقاف", options: [.destructive])
        let yes = UNNotificationAction(identifier: "agent.yes", title: "كمّل", options: [])
        let no = UNNotificationAction(identifier: "agent.no", title: "لا", options: [.destructive])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "agent.run", actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "agent.confirm", actions: [yes, no, stop], intentIdentifiers: []),
        ])
    }

    static func progress(goal: String, step: String) {
        let c = UNMutableNotificationContent()
        c.title = "الوكيل شغّال: \(goal.prefix(50))"
        c.body = step
        c.categoryIdentifier = "agent.run"
        c.interruptionLevel = .passive
        c.threadIdentifier = "agent"
        // نفس المعرّف = يستبدل نفسه (إشعار واحد ثابت)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-progress", content: c, trigger: nil))
    }

    static func agentConfirm(_ q: String) {
        let c = UNMutableNotificationContent()
        c.title = "صوت يحتاج تأكيدك"
        c.body = q
        c.sound = .default
        c.categoryIdentifier = "agent.confirm"
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-confirm", content: c, trigger: nil))
    }

    static func done(_ r: String) {
        clear()
        let c = UNMutableNotificationContent()
        c.title = "الوكيل خلص"
        c.body = r
        c.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-done", content: c, trigger: nil))
    }

    static func clear() {
        let ids = ["agent-progress", "agent-confirm"]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

struct PhoneAgentView: View {
    @ObservedObject var agent = PhoneAgent.shared
    @State private var goal = ""
    @State private var see = PhoneAgent.see
    @AppStorage("agentMaxSteps") private var maxSteps = 10
    @State private var testOut = ""
    @State private var shareLive = false

    var body: some View {
        Form {
            Section {
                TextField("وش تبيني أسوي؟ مثال: افتح الملاحظات واكتب مرحبا", text: $goal, axis: .vertical)
                if agent.running {
                    Button(role: .destructive) { agent.stop() } label: {
                        Label("إيقاف", systemImage: "stop.circle.fill").font(.title3.bold()).frame(maxWidth: .infinity)
                    }
                } else {
                    Button("ابدأ") { agent.start(goal) }.disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("أقصى عدد خطوات", selection: $maxSteps) {
                    ForEach([10, 20, 30], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("طريقة رؤية الشاشة", selection: $see) {
                    ForEach(PhoneAgent.See.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: see) { _, v in PhoneAgent.see = v; if v == .share { ScreenShare.shared.start() } }
                if see == .share {
                    HStack {
                        Text(shareLive ? "البث شغّال 🔴" : "اضغط الزر وبعدين «بدء البث»")
                        Spacer()
                        BroadcastPicker().frame(width: 44, height: 44)
                    }
                    .task {
                        ScreenShare.shared.start()
                        while !Task.isCancelled {
                            shareLive = ScreenShare.shared.live
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                }
            } footer: {
                Text("«مشاركة الشاشة»: يرسل صورة الشاشة مع أرقام العناصر لنموذج الرؤية (لو البث طافي ياخذ لقطة). الصورة تشتغل على كرت الشاشة بس؛ على المعالج نص فقط.\nيقرأ الشاشة ويختار خطوة وحدة كل مرة (الحد حسب الإعداد). أي إرسال أو حذف أو دفع أو كلمة سر يوقف ويسألك. تقدر توقفه بأي وقت.")
            }
            if let q = agent.confirm {
                Section("يحتاج تأكيد") {
                    Text(q)
                    HStack {
                        Button("كمّل") { agent.answer(true) }.buttonStyle(.borderedProminent)
                        Button("لا", role: .destructive) { agent.answer(false) }.buttonStyle(.bordered)
                    }
                }
            }
            if !agent.lastResult.isEmpty { Section("النتيجة") { Text(agent.lastResult) } }
            Section {
                Button("اختبار مطابقة أسماء التطبيقات") {
                    let r = PhoneAgent.matchSelfTest()
                    r.forEach { slog("agent: matchtest \($0)") }
                    testOut = r.joined(separator: "\n")
                }
                if !testOut.isEmpty { Text(testOut).font(.footnote.monospaced()).textSelection(.enabled) }
            }
            if !agent.log.isEmpty {
                Section("الخطوات") {
                    ForEach(agent.log) { s in Text(s.text).font(.footnote) }
                }
            }
        }
        .navigationTitle("الوكيل (تجريبي)")
    }
}

/// يكتشف أوامر الوكيل في الدردشة أو المكالمة
enum PhoneAgentTrigger {
    static func isStop(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.split(separator: " ").count <= 4 else { return false }
        return ["وقف", "وقّف", "اوقف", "أوقف", "توقف", "بس خلاص", "stop"].contains { s.contains($0) }
    }
    static let chatPrefixes = ["/جوال", "/agent", "جوال:", "نفذ على الجوال", "نفّذ على الجوال"]
    static let voicePrefixes = ["على الجوال", "نفذ على الجوال", "نفّذ على الجوال", "يا صوت نفذ", "يا صوت نفّذ", "on the phone"]
    static func goal(_ t: String, voice: Bool = false) -> String? {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in (voice ? voicePrefixes : chatPrefixes) where s.lowercased().hasPrefix(p.lowercased()) {
            let g = String(s.dropFirst(p.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :،,.-"))
            return g.isEmpty ? nil : g
        }
        return nil
    }
}
