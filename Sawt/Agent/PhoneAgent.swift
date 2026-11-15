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
    struct Element { var kind: String; let label: String; let value: String; let frame: CGRect; let secure: Bool }

    @Published var running = false
    @Published var goal = ""
    @Published var log: [Step] = []
    @Published var confirm: String?          // نص السؤال لما ننتظر تأكيد
    @Published var lastResult = ""

    private var task: Task<Void, Never>?
    private var lastFront = ""
    private var overflowed = false
    private var confirmToken: UUID?
    private var firstRead = true
    private var isSelf: Bool { lastFront == Bundle.main.bundleIdentifier || lastFront.hasPrefix("com.za7ef.sawt") }
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
    /// يرجع سبب الرفض لو ما بدأ (nil = بدأ)
    @discardableResult
    func start(_ goal: String) -> String? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        var why: String?
        if g.isEmpty { why = "الهدف فاضي" }
        else if running { why = "الوكيل شغّال على مهمة ثانية — قل «وقف» أول" }
        else if !(PhoneControl.available && PhoneControl.hasPairing) { why = "التحكم بالجوال مو جاهز (اقتران/الأداة)" }
        else if Self.agentModel == "qwen", !GGUFSpec.qwen.isDownloaded { why = "Qwen غير منزّل — نزّله من شاشة الوكيل أو اختر Gemma" }
        if let why {
            slog("agent: start refused: \(why)")
            // لو شغّال ما نلمس فقاعة المهمة الحالية
            if !running, let t = chatTarget { ChatStore.shared.updateText(t.msg, in: t.conv, "🤖 ما بديت: " + why, save: true); chatTarget = nil }
            return why
        }
        self.goal = g; log = []; lastResult = ""; running = true; stepNo = 0; firstRead = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // يبقى صاحي لما نطلع لتطبيقات ثانية (هنا مو داخل الحلقة عشان ما يسبق finish)
        HostPairing.shared.keepAlive(true)
        say("الهدف: \(g)")
        surface("يبدأ…")
        // ننتظر المهمة القديمة تخلص تنظيفها (الجلسة) قبل نبدأ
        let old = task
        task = Task { await old?.value; await self.loop() }
        return nil
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
        // Qwen يتحمّل عند الطلب ويتفضّى بعد المهمة (الذاكرة)
        if Self.agentModel == "qwen" { Task { await LlamaEngine.qwen.unload() } }
        slog("agent: finish \(r)")
    }

    private func say(_ s: String) {
        log.append(Step(text: s)); slog("agent: \(s.prefix(300))")
        if running { surface(s); updateBubble() }
    }

    // ───── الحلقة ─────
    private func loop() async {
        if Task.isCancelled { return }
        if Self.see == .share { ScreenShare.shared.start() }
        let bg = BGTask("agent")
        defer { bg.end() }
        let tl = Date()
        // الجلسة الدائمة معطّلة افتراضيًا: قراءة الشاشة كانت تفشل معها؛ نرجع لاتصال لكل أمر مثل ١٤٣
        let liveOn = UserDefaults.standard.bool(forKey: "agentLive")
        let lo = liveOn ? await Self.exec(.liveOpen) : "{\"ok\":false,\"error\":\"disabled\"}"
        Self.useLive = lo.contains("\"ok\":true")
        slog("agent: live session \(Self.useLive ? "open" : "failed") \(Int(Date().timeIntervalSince(tl) * 1000))ms \(Self.useLive ? "" : String(lo.prefix(160)))")
        defer { if Self.useLive { Self.useLive = false; Task { _ = await Self.exec(.liveClose) } } }
        // كل الخطوات يقررها النموذج (ما فيه اختصارات)؛ بس لو صوت قدّام نطلع للرئيسية عشان ما يلمس واجهته
        if UIApplication.shared.applicationState == .active {
            _ = await Self.exec(.keys("home"))
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if Task.isCancelled { return }
        var history: [String] = []
        var fails = 0
        var lastFailed = false
        var verifying = false
        var n = 0
        while n < maxSteps {
            if Task.isCancelled { return }
            let tAX = Date()
            // القراءة الفاشلة ما تحسب خطوة؛ والعدّاد يتصفّر بعد أي قراءة ناجحة
            guard let scr = await readScreen() else {
                fails += 1
                if fails >= 3 { finish("ما قدرت أقرأ الشاشة"); return }
                try? await Task.sleep(nanoseconds: 800_000_000); continue
            }
            fails = 0
            n += 1
            stepNo = n
            var (app, els) = scr
            if isSelf {
                // ما نلمس واجهة صوت نفسها أبدًا: نطلع للرئيسية ونعيد القراءة
                say("صوت قدّام — أطلع للشاشة الرئيسية")
                _ = await Self.exec(.keys("home"))
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let s2 = await readScreen(), !isSelf else { finish("ما قدرت أطلع من صوت"); return }
                (app, els) = s2
            }
            let axMs = Int(Date().timeIntervalSince(tAX) * 1000)
            let tLLM = Date()
            var limit = els.count
            var screenText = Self.describe(app: app, els)
            var user = """
            الهدف: \(goal)
            الخطوات السابقة: \(history.isEmpty ? "لا شيء" : history.suffix(6).joined(separator: " ← "))
            الخطوة رقم \(n) من \(maxSteps).\(verifying ? "\nقلت إنك خلصت. تحقق من الشاشة الحالية: إذا الهدف متحقق فعلاً ويظهر على الشاشة رد done، وإلا رد الخطوة التالية." : "")
            الشاشة الحالية:
            \(screenText)
            """
            var raw = ""
            var action: [String: Any]?
            let img = await visionImage(els, lastFailed: lastFailed)
            let userV = img == nil ? user : user + "\n\n[مرفقة صورة الشاشة. الأرقام المرسومة على المربعات هي نفس أرقام العناصر.]"
            var userQ = userV
            var attempt = 0
            overflowed = false
            while attempt < 2 {
                raw = await ask(userQ + (attempt == 1 ? "\n\nردك السابق ما كان JSON صالح. رد بسطر JSON واحد فقط." : ""), image: img)
                // السياق ما كفى: نقص قائمة العناصر (60→40→25) ونعيد بدل ما ننهي
                if raw.isEmpty, overflowed, let next = [40, 25].first(where: { $0 < limit }) {
                    overflowed = false
                    limit = next
                    // نعيد الترتيب بسقف أصغر (مو prefix): خانة البحث والأشرطة تجي آخر القائمة وتنقص لو قصينا من الآخر
                    let oldCount = els.count, prevHidden = Self.hiddenRows
                    els = Self.rank(els, screen: UIScreen.main.bounds, cap: limit)
                    Self.hiddenRows += prevHidden + max(0, oldCount - els.count - Self.hiddenRows)
                    screenText = Self.describe(app: app, els)
                    user = user.components(separatedBy: "الشاشة الحالية:\n")[0] + "الشاشة الحالية:\n" + screenText
                    userQ = user
                    slog("agent: context overflow — retry with \(limit) elements")
                    continue
                }
                attempt += 1
                action = Self.parse(raw)
                if action != nil { break }
                if raw.isEmpty, Self.agentModel == "qwen" { break }   // خطأ تحميل/ذاكرة: ما نعيد
            }
            if Task.isCancelled { return }
            let llmMs = Int(Date().timeIntervalSince(tLLM) * 1000)
            slog("agent: raw step=\(n) «\(raw.prefix(300))»")
            log.append(Step(text: "🤖 النموذج (\(llmMs)ms\(img == nil ? "" : "، مع صورة")): \(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"))
            guard action?["action"] is String else {
                say("⚠️ رد غير مفهوم: \(raw.prefix(120))"); finish("النموذج ما رد بخطوة صالحة"); return
            }
            let acts = Self.actions(raw)
            var actMs = 0
            var screenChanged = false
            for action in acts {
                guard let kind = action["action"] as? String else { continue }
                // بعد لمس/فتح/رجوع الشاشة تغيّرت: أرقام العناصر قديمة، نوقف الدفعة ونقرأ من جديد
                if screenChanged, kind == "tap" || kind == "done" {
                    slog("agent: batch stopped (stale ids after screen change)"); break
                }
                if kind == "tap", !((action["id"] as? Int).map { els.indices.contains($0) } ?? false) {
                    say("⚠️ رقم عنصر غير موجود: \(action["id"] ?? "؟")")
                    history.append("رقم غلط \(action["id"] ?? "؟") — اختر رقم من القائمة"); lastFailed = true; break
                }
                let desc = Self.describeAction(action, els)
                say("\(n). 🤖 \(desc)")
                if kind == "done" {
                    let sum = (action["summary"] as? String) ?? "خلصت"
                    // لازم نتأكد من الشاشة: أول done نعيد القراءة ونسأله يتحقق
                    if !verifying && n < maxSteps {
                        verifying = true
                        say("🔎 أتأكد من الشاشة قبل ما أقول خلصت")
                        history.append("قال خلص (\(sum)) — يتحقق")
                        break
                    }
                    finish("✅ \(sum)"); return
                }
                verifying = false
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
                if ["tap", "open", "back", "home", "swipe", "url", "search"].contains(kind) {
                    screenChanged = true
                    if acts.count > 1 { try? await Task.sleep(nanoseconds: 400_000_000) }
                }
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
        // بدون رد خلال دقيقتين = لا
        let token = UUID(); confirmToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.confirmToken == token, self.confirmCont != nil else { return }
            self.say("⏱️ ما جاء رد — اعتبرتها لا"); self.answer(false)
        }
        return await withCheckedContinuation { c in confirmCont = c }
    }

    // ───── النموذج ─────
    static let system = """
    أنت وكيل يتحكم بجوال iPhone نيابة عن المستخدم. كل مرة تشوف وصف الشاشة كقائمة عناصر مرقّمة، وتختار خطوة وحدة بس.
    رد بسطر JSON واحد فقط بدون أي كلام ثاني، بأحد هذي الأشكال:
    {"action":"tap","id":N}   (N = رقم العنصر المطلوب من القائمة بالضبط، مو مثال)
    {"action":"type","text":"النص"}   (يكتب في الخانة المفتوحة؛ اضغط على الخانة أول لو ما كانت مفتوحة)
    {"action":"enter"}               (زر الإدخال/إرسال في الكيبورد)
    {"action":"swipe","dir":"up"}     (up يمرر لتحت المحتوى، down لفوق، left، right)
    {"action":"open","app":"اسم التطبيق"}   (يروح للرئيسية ويبحث عن التطبيق ويفتحه)
    {"action":"url","url":"https://..."}    (يفتح رابط في المتصفح)
    {"action":"search","q":"نص البحث"}      (بحث قوقل في المتصفح — بس لو المطلوب بحث في الويب، مو داخل تطبيق)
    {"action":"back"}
    {"action":"home"}
    {"action":"done","summary":"وش سويت باختصار"}
    لو واضح تقدر ترجع حتى ٣ خطوات مرة وحدة: {"actions":[{"action":"tap","id":N},{"action":"type","text":"..."}]}
    إذا التطبيق المطلوب مو قدّام، أول خطوة open باسمه.
    في open اكتب اسم التطبيق بالإنجليزي إذا تعرفه (Notes, Settings, WhatsApp...).
    للبحث داخل تطبيق (بريد، رسائل، ملاحظات...): اضغط عنصر search، بعدين type بالكلمة، بعدين enter. لا تفتح رسالة أو عنصر من القائمة إلا لو الهدف تقرأه. لو فتحت شاشة غلط اضغط back.
    قواعد: لا تخترع أرقام عناصر غير موجودة. لو الهدف تحقق قل done. لو انحسبت نفس الخطوة مرتين بدون تغيير جرّب شي ثاني.
    """

    /// نموذج الوكيل المختار: gemma (الحالي) أو qwen (Qwen3.5-4B على llama.cpp)
    static var agentModel: String { UserDefaults.standard.string(forKey: "agentModel") ?? "gemma" }

    /// GBNF: يجبر الرد يكون خطوة JSON وحدة أو {"actions":[…]} حتى ٣
    static let grammar = #"""
    root ::= act | multi
    multi ::= "{\"actions\":[" act ("," act)? ("," act)? "]}"
    act ::= tap | type | simple | swipe | open | url | search | done
    tap ::= "{\"action\":\"tap\",\"id\":" [0-9] [0-9]? "}"
    type ::= "{\"action\":\"type\",\"text\":" str "}"
    simple ::= "{\"action\":\"" ("enter" | "back" | "home") "\"}"
    swipe ::= "{\"action\":\"swipe\",\"dir\":\"" ("up" | "down" | "left" | "right") "\"}"
    open ::= "{\"action\":\"open\",\"app\":" str "}"
    url ::= "{\"action\":\"url\",\"url\":" str "}"
    search ::= "{\"action\":\"search\",\"q\":" str "}"
    done ::= "{\"action\":\"done\",\"summary\":" str "}"
    str ::= "\"" ( [^"\\\x00-\x1F] | "\\" ["\\/nt] )* "\""
    """#

    /// يحمّل Qwen عند الطلب؛ يفضّي نموذج المعالج الثاني، والـMLX لو الذاكرة ضيقة
    private func askQwen(_ user: String) async -> String {
        guard GGUFSpec.qwen.isDownloaded else { say("⚠️ Qwen3.5-4B مو منزّل — نزّله من شاشة الوكيل"); return "" }
        if !(await LlamaEngine.qwen.isLoaded) {
            await LlamaEngine.shared.unload()
            // ما نفضّي نموذج الدردشة/المكالمة (MLX) — لو الذاكرة ما تكفي نقول بوضوح
            if RAM.availableMB < 3000 {
                say("⚠️ الذاكرة ما تكفي لـQwen (\(RAM.availableMB)MB متوفر) — سكّر المكالمة أو اختر Gemma")
                return ""
            }
        }
        do {
            return try await LlamaEngine.qwen.complete(system: Self.system, user: user, maxTokens: 256, grammar: Self.grammar)
        } catch {
            slog("agent: qwen error \(error)")
            if "\(error)".contains("أطول من سياق") { overflowed = true; return "" }
            say("⚠️ Qwen: \(error)"); return ""
        }
    }

    private func ask(_ user: String, image: URL? = nil) async -> String {
        let t0 = Date()
        var model = "gemma-mlx"
        defer { slog("agent: model=\(model) \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        if Self.agentModel == "qwen" {
            model = "qwen3.5-4b-cpu+gbnf"
            return await askQwen(user)
        }
        // Gemma على المعالج (llama.cpp): نفس القيود
        if LLMService.onCPU, image == nil, LlamaModelFile.isDownloaded {
            model = "gemma-cpu+gbnf"
            do { return try await LlamaEngine.shared.complete(system: Self.system, user: user, maxTokens: 256, grammar: Self.grammar) }
            catch {
                slog("agent: gemma cpu error \(error)")
                if "\(error)".contains("أطول من سياق") { overflowed = true }
                return ""
            }
        }
        // Gemma على كرت الشاشة (MLX): بدون قيود، تحليل صارم
        var out = ""
        do {
            let st = try await LLMService.shared.stream(system: Self.system, history: [], user: user, maxTokens: 256,
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
        return ["tap", "type", "enter", "swipe", "open", "url", "search", "back", "home", "done"].contains(k)
    }

    /// بس لو الهدف يبدأ بـ«افتح/open/شغّل» + اسم تطبيق من الجدول بعده مباشرة
    static func mentionedApp(_ g: String) -> String? {
        let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
        let verbs = ["روح على", "روح الى", "روح إلى", "روح ل", "روح", "ادخل على", "ادخل", "أدخل", "اذهب الى", "اذهب إلى", "افتح", "إفتح", "open", "go to", "شغّل", "شغل"]
        guard let v = verbs.first(where: { t.lowercased().hasPrefix($0) }) else { return nil }
        let rest = t.dropFirst(v.count).trimmingCharacters(in: .whitespaces)
        let words = rest.split(separator: " ").map(String.init)
        // نجرب أول كلمة، وأول كلمتين، وأول ثلاث (أسماء مثل «واتساب للأعمال»)، والأطول يفوز
        for n in stride(from: min(3, words.count), through: 1, by: -1) {
            var cand = words.prefix(n).joined(separator: " ")
            for p in ["و", "ل", "على"] where lookup(cand) == nil && cand.hasPrefix(p) && cand.count > p.count + 2 {
                cand = String(cand.dropFirst(p.count))
            }
            if let e = lookup(cand), !e.bundle.isEmpty { return cand }
        }
        return nil
    }

    /// أي تطبيق من الجدول مذكور في الهدف (بعد فعل أو بأي مكان ككلمة/كلمتين)
    static func namedAppBundle(_ g: String) -> String? {
        if let a = mentionedApp(g), let e = lookup(a) { return e.bundle }
        let words = g.split(separator: " ").map { w -> String in
            var x = String(w)
            for p in ["و", "ل", "ب"] where lookup(x) == nil && x.hasPrefix(p) && x.count > 3 { x = String(x.dropFirst()) }
            return x
        }
        for n in [2, 1] where words.count >= n {
            for i in 0...(words.count - n) {
                let c = words[i..<(i + n)].joined(separator: " ")
                // كلمات عامة ما نعتبرها اسم تطبيق لحالها
                if n == 1, ["قوقل", "جوجل", "google", "x", "اكس"].contains(c.lowercased()) { continue }
                if let e = lookup(c), !e.bundle.isEmpty { return e.bundle }
            }
        }
        return nil
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
            ("سفاري", "com.apple.mobilesafari"),
            ("البريد", "com.apple.mobilemail"),
        ]
        var out = cases.map { c in
            let got = lookup(c.0)?.bundle ?? "nil"
            return "\(got == c.1 ? "✅" : "❌") «\(c.0)» → \(got)"
        }
        // هدف فيه تطبيق ثاني + «ابحث عن»: لازم ما يروح للويب
        let g = "روح تطبيق البريد وأبحث عن رسائل قوقل"
        let b = namedAppBundle(g) ?? "nil"
        out.append("\(b == "com.apple.mobilemail" ? "✅" : "❌") هدف «\(g)» → تطبيق \(b) (بدون اختصار الويب)")
        return out
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
              ["tap", "type", "enter", "swipe", "open", "url", "search", "back", "home", "done"].contains(k) else { return nil }
        return o
    }

    // ───── الشاشة ─────
    private func readScreen() async -> (String, [Element])? {
        let r = await Self.exec(.screen(firstRead ? 8000 : 5000))
        firstRead = false
        Self.searchKey = false; Self.hiddenRows = 0   // مسار OCR ما يعرف الكيبورد ولا الصفوف المخفية
        guard let d = try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any],
              d["ok"] as? Bool == true else {
            slog("agent: ax failed \(r.prefix(300)) — ocr fallback")
            // بديل: نص من صورة الشاشة (Apple Vision) مع إطاراته
            let o = await ocrElements(existing: [])
            if o.count >= 2 {
                // ما نعرف التطبيق اللي قدّام: لو صوت نفسه قدّام نعتبره صوت (عشان ما نلمس واجهته)
                lastFront = UIApplication.shared.applicationState == .active ? (Bundle.main.bundleIdentifier ?? "com.za7ef.sawt") : "?"
                say("قراءة بالصورة (\(o.count) نص)"); return ("؟", Array(o.prefix(45))) }
            say("⚠️ قراءة الشاشة: \(r.prefix(160))"); return nil
        }
        if d["partial"] as? Bool == true { slog("agent: ax partial tree") }
        let app = ((d["app"] as? [String: Any])?["name"] as? String) ?? "؟"
        lastFront = ((d["app"] as? [String: Any])?["bundle"] as? String) ?? ""
        slog("agent: frontmost=\(lastFront.isEmpty ? app : lastFront)")
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
        // مفتاح الإدخال في الكيبورد مكتوب عليه Search/بحث؟ (نفحصه قبل القص لأن الكيبورد يجي آخر الشجرة)
        Self.searchKey = els.contains { $0.kind == "key" && ["search", "بحث", "ابحث"].contains($0.label.lowercased().trimmingCharacters(in: .whitespaces)) }
        els = Self.rank(els, screen: b)
        // مشاركة الشاشة + المعالج (خلفية): ما فيه رؤية للنموذج، فنقرأ النص من الصورة ونضيفه كعناصر قابلة للضغط
        if Self.see == .share, LLMService.onCPU {
            let extra = await ocrElements(existing: els)
            els += extra.prefix(max(0, 75 - els.count))
        }
        return (app, els)
    }

    /// عدد صفوف القوائم اللي انطوت في آخر قراءة
    static var hiddenRows = 0
    /// الكيبورد ظاهر ومفتاح الإدخال فيه «بحث» (الإدخال حينها ما يرسل شي)
    static var searchKey = false

    /// ترتيب العناصر قبل القص: خانات الكتابة/البحث أول، بعدين أشرطة فوق/تحت (تبويبات، أدوات، بحث آيفون ٢٦+)،
    /// بعدين الأزرار، وآخر شي النصوص. صفوف القوائم الطويلة نخلي أول ٨ بس.
    static func rank(_ input: [Element], screen b: CGRect, cap: Int = 60) -> [Element] {
        var els = input.map { e -> Element in
            var e = e
            let t = (e.label + " " + e.value).lowercased()
            if e.kind == "field" || e.kind == "search" || e.kind == "other" || e.kind == "button",
               ["بحث", "ابحث", "search"].contains(where: { t.contains($0) }) && e.frame.height < 80 { e.kind = "search" }
            return e
        }
        func isRow(_ e: Element) -> Bool {
            e.frame.width > b.width * 0.8 && e.frame.height >= 40 && e.frame.height < 160 &&
            e.frame.minY > b.height * 0.15 && e.frame.maxY < b.height * 0.88 && !["field", "search", "switch", "button", "link"].contains(e.kind)
        }
        var rows = 0
        hiddenRows = 0
        els = els.filter { e in
            guard isRow(e) else { return true }
            rows += 1
            if rows > 8 { hiddenRows += 1; return false }
            return true
        }
        func prio(_ e: Element) -> Int {
            if e.kind == "field" || e.kind == "search" { return 0 }
            let bar = e.frame.minY > b.height * 0.85 || e.frame.maxY < b.height * 0.15
            if e.kind == "tabbar" || (bar && ["button", "link", "other", "image"].contains(e.kind)) { return 1 }
            if ["button", "switch", "link"].contains(e.kind) { return 2 }
            return 3
        }
        let picked = els.enumerated().sorted { (prio($0.element), $0.offset) < (prio($1.element), $1.offset) }.prefix(cap)
        // نرجّع الترتيب الأصلي (ترتيب الشاشة) عشان الأرقام منطقية
        let out = picked.sorted { $0.offset < $1.offset }.map { $0.element }
        slog("agent: rank in=\(input.count) rows_hidden=\(hiddenRows) out=\(out.count) search=\(out.filter { $0.kind == "search" }.count) fields=\(out.filter { $0.kind == "field" }.count)")
        return out
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
        if hiddenRows > 0 { lines.append("(+\(hiddenRows) صف ثاني في القائمة — اسحب up عشان تشوفها)") }
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
        case "url": return "افتح الرابط \(a["url"] as? String ?? "")"
        case "search": return "ابحث في الويب «\(a["q"] as? String ?? "")»"
        case "back": return "رجوع"
        case "home": return "الشاشة الرئيسية"
        case "done": return "خلصت"
        default: return k
        }
    }

    /// إنجليزي: بداية الكلمة (send→sending, pay→payments) ؛ عربي: الجذر داخل الكلمة (يرسل/ترسل/إرسال)
    static let riskyEN = ["send", "delete", "remove", "pay", "buy", "purchase", "subscribe", "transfer", "call", "post",
                          "confirm", "order", "checkout", "submit", "share", "reply", "reset", "erase", "install", "uninstall",
                          "logout", "signout", "sign out", "log out", "unsubscribe", "accept", "approve"]
    static let riskyAR = ["رسل", "حذف", "مسح", "دفع", "شراء", "اشتر", "اشترك", "تحويل", "اتصل", "اتصال", "نشر",
                          "تأكيد", "أكد", "اكد", "طلب", "شارك", "مشارك", "رد", "تثبيت", "ثبت", "تسجيل الخروج", "خروج", "إعادة تعيين", "قبول"]

    /// صيغ محددة بس (مو أي بادئة): send/sends/sending/sent… عشان Sender/Shared/Postcards ما تنحسب
    static func inflections(_ w: String) -> Set<String> {
        var f: Set<String> = [w, w + "s", w + "es", w + "ing", w + "ed", w + "d", w + "ment", w + "ments"]
        if w.hasSuffix("e") { let b = String(w.dropLast()); f.insert(b + "ing") }
        // y بعد ساكن: reply → replies / replied
        if w.hasSuffix("y"), w.count >= 3, !"aeiou".contains(w[w.index(w.endIndex, offsetBy: -2)]) {
            let b = String(w.dropLast()); f.insert(b + "ies"); f.insert(b + "ied")
        }
        if let l = w.last, w.count >= 4, !"aeiouy".contains(l) { f.insert(w + String(l) + "ed"); f.insert(w + String(l) + "ing") }
        let irregular: [String: [String]] = ["send": ["sent"], "pay": ["paid"], "buy": ["bought"], "post": ["posted"]]
        irregular[w]?.forEach { f.insert($0) }
        f.remove(w + "d") ; if w.hasSuffix("e") { f.insert(w + "d") }
        return f
    }

    static func hasWord(_ text: String, _ words: [String] = []) -> Bool {
        let low = text.lowercased()
        let toks = low.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for t in toks {
            if t.unicodeScalars.first.map({ $0.value < 0x0600 }) == true {
                if riskyEN.contains(where: { !$0.contains(" ") && Self.inflections($0).contains(t) }) { return true }
            } else {
                // «رد» قصيرة: بس كلمة كاملة (رد/الرد/ورد)، الباقي جذر داخل الكلمة
                if ["رد", "الرد", "ورد"].contains(t) { return true }
                if riskyAR.contains(where: { $0.count >= 3 && !$0.contains(" ") && t.contains($0) }) { return true }
            }
        }
        return (riskyEN + riskyAR).contains { $0.contains(" ") && low.contains($0) }
    }

    static func sensitive(_ a: [String: Any], _ els: [Element]) -> String? {
        let k = a["action"] as? String ?? ""
        if k == "tap", let i = a["id"] as? Int, els.indices.contains(i) {
            let l = els[i].label.lowercased()
            if l.split(separator: " ").count <= 4, Self.hasWord(l) { return "خطوة حساسة (إرسال/حذف/دفع)." }
        }
        if k == "type", els.contains(where: { $0.secure }) { return "فيه خانة كلمة سر على الشاشة." }
        // بحث: مفتاح الكيبورد «Search» ما يرسل، فما نوقف الوكيل ونسأل عن كل بحث
        if k == "enter" { return Self.searchKey ? nil : "زر الإدخال ممكن يرسل." }
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
            // أول: زر رجوع ظاهر في أعلى الشاشة
            let b = UIScreen.main.bounds
            if let e = els.first(where: { ["back", "رجوع", "السابق", "عودة"].contains($0.label.lowercased().trimmingCharacters(in: .whitespaces)) && $0.frame.minY < b.height * 0.2 }) {
                let (x, y) = Self.norm(CGPoint(x: e.frame.midX, y: e.frame.midY))
                return ok(await Self.exec(.tap(x, y)))
            }
            // وإلا سحب من الحافة: اليمين لو اللغة عربية (RTL)، واليسار لو إنجليزي
            let rtl = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
            let (x1, y) = Self.norm(CGPoint(x: rtl ? b.width - 2 : 2, y: b.midY))
            let (x2, _) = Self.norm(CGPoint(x: rtl ? b.width * 0.25 : b.width * 0.75, y: 0))
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
        case "url", "search":
            var u: URL?
            if kind == "search", let q = (a["q"] as? String)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !q.isEmpty {
                u = URL(string: "https://www.google.com/search?q=\(q)")
            } else if let t = a["url"] as? String {
                u = URL(string: t.lowercased().hasPrefix("http") ? t : "https://\(t)")
            }
            guard let u else { return (false, "رابط غير صالح") }
            return await openURL(u)
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
        if Self.agentModel == "qwen" { slog("agent: vision skipped (qwen text-only)"); return nil }
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vision.jpg")   // نفس الملف كل مرة (ما يتكدّس)
        guard let d = out.jpegData(compressionQuality: 0.8), (try? d.write(to: url)) != nil else { return nil }
        slog("agent: vision on (\(mode)) \(Int(size.width))x\(Int(size.height)) \(d.count / 1024)KB els=\(els.count)")
        return url
    }

    /// آخر إطار من البث، وإلا لقطة شاشة
    private func currentFrame() async -> (UIImage, String)? {
        if let d = ScreenShare.shared.latest, let i = UIImage(data: d) { return (i, "broadcast") }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("agent-shot.png")
        let r = await Self.exec(.shot(raw.path))
        defer { try? FileManager.default.removeItem(at: raw) }
        if r.contains("\"ok\":true"), let d = try? Data(contentsOf: raw), let i = UIImage(data: d) { return (i, "screenshot") }
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
        // ما نسجّل النص نفسه (ممكن كلمة سر) — بس الطول؛ والحافظة تتفضّى بعد اللصق
        slog("agent: type via=paste chars=\(t.count)")
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
        (["سفاري", "سافاري", "المتصفح", "safari"], "com.apple.mobilesafari", "Safari"),
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
        if let hit, !hit.bundle.isEmpty, UserDefaults.standard.bool(forKey: "agentBundleLaunch") {
            let r = await Self.exec(.launch(hit.bundle))
            slog("agent: open chosen=\(hit.bundle) via=table ok=\(r.contains("\"ok\":true"))")
            if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 700_000_000); return (true, r) }
            say("⚠️ إطلاق \(hit.bundle): \(r.prefix(120))")
        }
        let q = hit?.en ?? name
        // الافتراضي مثل ١٤٣: البحث (سبوتلايت) باسم التطبيق؛ الإطلاق بالمعرّف بس لتطابق الجدول التام
        let fuzzy = UserDefaults.standard.bool(forKey: "agentFuzzyLaunch")
        let r = fuzzy ? await Self.exec(.launch(q)) : "{\"ok\":false,\"error\":\"fuzzy disabled\"}"
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
        slog("agent: open via spotlight «\(name)»")
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

    /// يفتح رابط: لو صوت قدّام نفتحه مباشرة، وإلا من سبوتلايت (لصق الرابط + إدخال)
    func openURL(_ u: URL) async -> (ok: Bool, info: String) {
        slog("agent: open url \(u.absoluteString)")
        if UIApplication.shared.applicationState == .active, await UIApplication.shared.open(u) {
            try? await Task.sleep(nanoseconds: 1_000_000_000); return (true, "opened")
        }
        _ = await Self.exec(.keys("home"))
        try? await Task.sleep(nanoseconds: 600_000_000)
        let b = UIScreen.main.bounds
        let (x, y1) = Self.norm(CGPoint(x: b.midX, y: b.height * 0.4)), (_, y2) = Self.norm(CGPoint(x: 0, y: b.height * 0.65))
        _ = await Self.exec(.drag(x, y1, x, y2))
        try? await Task.sleep(nanoseconds: 800_000_000)
        _ = await Self.typeText(u.absoluteString.removingPercentEncoding ?? u.absoluteString)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let r = await Self.exec(.keys("return"))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return (r.contains("\"ok\":true"), r)
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
    @AppStorage("agentModel") private var agentModel = "gemma"
    @ObservedObject private var qwenDL = LlamaDownloader.qwen
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
                Picker("نموذج الوكيل", selection: $agentModel) {
                    Text("Gemma 4 E2B").tag("gemma")
                    Text("Qwen3.5-4B").tag("qwen")
                }
                if agentModel == "qwen" {
                    if qwenDL.downloaded {
                        HStack {
                            Text("Qwen3.5-4B جاهز (\(GGUFSpec.qwen.sizeText))").font(.footnote)
                            Spacer()
                            Button("احذف", role: .destructive) { qwenDL.delete() }.font(.footnote)
                        }
                    } else if qwenDL.running {
                        ProgressView(value: qwenDL.progress) { Text("ينزّل Qwen3.5-4B… \(Int(qwenDL.progress * 100))%").font(.footnote) }
                        Button("إلغاء") { qwenDL.cancel() }
                    } else {
                        Button("نزّل Qwen3.5-4B (\(GGUFSpec.qwen.sizeText))") { qwenDL.start() }
                        Text("المتوفر: \(ByteCountFormatter.string(fromByteCount: LlamaModelFile.freeBytes, countStyle: .file))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !qwenDL.message.isEmpty { Text(qwenDL.message).font(.footnote).foregroundStyle(.secondary) }
                    Text("يشتغل على المعالج (حتى بالخلفية)، ورده مقيّد بصيغة الخطوات فما يطلع JSON خربان. أبطأ من Gemma لكن أذكى.").font(.footnote).foregroundStyle(.secondary)
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
        // نشيل التشكيل والترقيم والمسافات الزايدة قبل المقارنة
        let bare = t.lowercased().unicodeScalars.filter { !(0x064B...0x0652).contains($0.value) && $0.value != 0x0640 }
        let toks = String(String.UnicodeScalarView(bare)).components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let s = toks.joined(separator: " ")
        guard !toks.isEmpty, toks.count <= 3 else { return false }
        // كلمة كاملة بس (مو «موقف» ولا «stopwatch»)
        // «خلاص» لحالها ما توقف (خلاص فهمت / طيب خلاص)؛ بس «بس خلاص» كأمر كامل
        let stops: Set<String> = ["وقف", "اوقف", "أوقف", "توقف", "وقفه", "وقفها", "stop"]
        if ["بس خلاص", "stop it", "كفاية", "كفايه", "بس كفاية", "بس كفايه"].contains(s) { return true }
        return toks.contains { stops.contains($0) }
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


/// وقت خلفية مع معالج انتهاء ينهيه فعلاً (بدل معالج فاضي يخلي النظام يقتل التطبيق)
@MainActor
final class BGTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            slog("bg: \(name) expired")
            // لازم ننهيه قبل ما يرجع المعالج (يشتغل على الخيط الرئيسي)
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}
