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
    /// الخط الزمني للمهمة (يطلع في فقاعة المحادثة)
    @Published var timeline: [AgentStepRec] = []
    /// تفاصيل قبل ما تبدأ الخطوة (رد النموذج يجي قبل وصف الخطوة)
    private var pendingDetails: [String] = []
    /// سبب آخر فشل قراءة بالطريقة المختارة (يطلع للمستخدم بدل الرجوع لطريقة ثانية)
    private var lastReadError = ""

    private var task: Task<Void, Never>?
    private var lastFront = "" { didSet { Self.frontNow = lastFront } }
    private var overflowed = false
    private var confirmToken: UUID?
    private var firstRead = true
    private var isSelf: Bool { lastFront == Bundle.main.bundleIdentifier || lastFront.hasPrefix("com.za7ef.sawt") }
    private var activity: Activity<AgentActivityAttributes>?
    private(set) var stepNo = 0
    private var obs: NSObjectProtocol?

    private init() {
        // وضع الأتمتة وقف وسط المهمة (أزرار الصوت أو انتهى التفويض): نوقف المهمة، وما نرجّعه لحالنا
        _ = NotificationCenter.default.addObserver(forName: Notification.Name("sawt.automationEnded"), object: nil, queue: .main) { note in
            let why = note.object as? String ?? ""
            Task { @MainActor in PhoneAgent.shared.automationEnded(why) }
        }
        obs = NotificationCenter.default.addObserver(forName: Notification.Name("sawt.stopAgent"), object: nil, queue: .main) { _ in
            Task { @MainActor in PhoneAgent.shared.stop() }
        }
        for (name, yes) in [("sawt.confirmYes", true), ("sawt.confirmNo", false)] {
            _ = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in PhoneAgent.shared.answerFromOutside(yes) }
            }
        }
        AgentNotify.setup()
    }

    /// موافقة/رفض من الإشعار أو الجزيرة: بس لو فيه سؤال ينتظر
    func answerFromOutside(_ yes: Bool) {
        guard confirmCont != nil else { return }
        say(yes ? L("✅ موافق") : L("✋ رفض"))
        AgentNotify.clearConfirm()
        answer(yes)
        if running { surface(yes ? L("تمت الموافقة، جارٍ الإكمال") : L("رُفضت الخطوة")) }
    }

    /// يحدّث النشاط المباشر والإشعار الثابت بالخطوة الحالية
    private func surface(_ step: String, waiting: Bool = false) {
        let st = AgentActivityAttributes.ContentState(step: step, n: stepNo, waiting: waiting, phase: "step", task: String(goal.prefix(60)))
        RunnerActivity.show(st, goal: goal)
        AgentNotify.progress(goal: goal, step: step)
    }

    /// مرحلة «يفكّر» في الجزيرة (قبل طلب النموذج)
    private func surfaceThinking() {
        RunnerActivity.show(.init(step: L("يختار الخطوة التالية"), n: stepNo, waiting: false, phase: "thinking", task: String(goal.prefix(60))), goal: goal)
    }

    private func unsurface() {
        activity = nil
        if Runner.isOn {
            // المشغّل يبقى: «خلص» شوي، بعدين جاهز، وبعد دقيقة نايم
            RunnerActivity.show(.init(step: String(lastResult.prefix(80)), n: stepNo, waiting: false, phase: "done", task: nil), goal: goal)
            RunnerActivity.idle(after: 4)
        } else {
            RunnerActivity.end()
        }
        AgentNotify.clear()
    }
    private var confirmCont: CheckedContinuation<Bool, Never>?
    /// الحد الأقصى للخطوات (١٠/٢٠/٣٠) من الإعدادات
    var maxSteps: Int { let v = UserDefaults.standard.integer(forKey: "agentMaxSteps"); return [10, 20, 30].contains(v) ? v : 10 }
    /// فقاعة الحالة في المحادثة لما ينطلق من «/جوال»
    var chatTarget: (conv: UUID?, msg: UUID)?

    // ───── الخط الزمني ─────
    /// يحوّل سطر السجل لحالة خطوة (بدون ما نغيّر نصوص السجل نفسها)
    private func track(_ s: String) {
        func addDetail(_ d: String) {
            if let i = timeline.indices.last { timeline[i].details.append(d) } else { pendingDetails.append(d) }
        }
        func begin(_ title: String, _ state: AgentStepRec.State = .running) {
            if let i = timeline.indices.last, timeline[i].state == .running { timeline[i].state = .done }
            timeline.append(AgentStepRec(title: title, state: state, details: pendingDetails))
            pendingDetails = []
        }
        func fail(_ d: String) {
            if let i = timeline.indices.last, timeline[i].state == .running || timeline[i].state == .ask {
                timeline[i].state = .failed
                timeline[i].details.append(d)
            } else {
                begin(d, .failed)
            }
        }
        if s.hasPrefix(L("الهدف:")) || s.hasPrefix(L("⏹️ توقّف")) || s.hasPrefix(L("✅ موافق")) || s.hasPrefix(L("✋ رفض")) { return }
        // «3. 🤖 يضغط على …» = خطوة جديدة
        if let r = s.range(of: ". 🤖 "), s[s.startIndex..<r.lowerBound].allSatisfy(\.isNumber) {
            begin(String(s[r.upperBound...]))
            return
        }
        if s.hasPrefix("🔎") { begin(L("جارٍ التحقق من الشاشة")); return }
        if s.hasPrefix("❓") {
            if let i = timeline.indices.last, timeline[i].state == .running {
                timeline[i].state = .ask
                timeline[i].details.append(String(s.dropFirst(2)))
            } else {
                begin(L("بانتظار موافقتك"), .ask)
                addDetail(String(s.dropFirst(2)))
            }
            return
        }
        if s.hasPrefix("⚠️") || s.hasPrefix("✗") || s.hasPrefix(L("رُفضت — توقّف الوكيل")) || s.hasPrefix("⏹️") {
            fail(s.replacingOccurrences(of: "⚠️ ", with: "").replacingOccurrences(of: "✗ ", with: ""))
            return
        }
        // أسطر التجهيز (الطريقة، المشغّل، الشاشة الرئيسية…)
        if timeline.isEmpty { begin(L("جارٍ تجهيز التحكم بالجهاز")) }
        addDetail(s.hasPrefix("✓ ") ? String(s.dropFirst(2)) : s)
    }

    private func updateBubble(final: Bool = false) {
        guard let t = chatTarget else { return }
        let tl = timeline
        ChatStore.shared.editMessage(t.msg, in: t.conv, persist: false) { $0.agentSteps = tl }
        // فقاعة الإقرار تعرض الخطوات؛ والنتيجة تنزل كرد عادي مستقل
        var lines = [L("حسنًا، جارٍ تنفيذ المهمة…")]
        let steps = log.dropFirst().suffix(final ? 12 : 6).map { "• " + $0.text }
        if !steps.isEmpty { lines.append(""); lines += steps }
        if !final { lines.append(L("(يمكنك إيقافه من الإشعار أو من الجزيرة الديناميكية)")) }
        ChatStore.shared.updateText(t.msg, in: t.conv, lines.joined(separator: "\n"), save: final)
        if final {
            let res = lastResult.replacingOccurrences(of: "✅ ", with: "")
            var m = Message(role: .assistant, text: lastResult.hasPrefix("✅") ? L("تم: %@", res) : L("لم تكتمل المهمة: %@", res))
            if !agentModelName.isEmpty { m.model = L("الوكيل · %@", agentModelName) }
            ChatStore.shared.append(m, to: t.conv)
            chatTarget = nil
        }
    }

    // ───── التشغيل والإيقاف ─────
    /// يرجع سبب الرفض لو ما بدأ (nil = بدأ)
    @discardableResult
    func start(_ goal: String) -> String? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        var why: String?
        AgentNotify.setup()   // لو الإشعارات انمسحت/ما انضبطت أول مرة
        if g.isEmpty { why = L("الهدف فارغ") }
        else if running { why = L("الوكيل يعمل على مهمة أخرى — قل «توقف» أولًا") }
        else if ImageGenerator.busy { why = L("Sowtly ينشئ صورة الآن — انتظر حتى ينتهي أو أوقفه") }
        else if !(PhoneControl.available && PhoneControl.hasPairing) { why = L("التحكم بالجهاز غير جاهز (الاقتران/الأداة)") }
        else if Self.blockedByGPU { why = L("لا يعمل الوكيل على معالج الرسوميات (يمنعه iOS في الخلفية) — غيّر النموذج إلى نموذج للمعالج أو نموذج سحابي") }
        else if let s = Self.cpuSpecForStep(), !s.isDownloaded { why = L("نموذج المعالج (%@) غير محمَّل — حمِّله من صفحة النماذج ← المعالج", Self.cpuSpecForStep()?.name ?? "") }
        if why == nil, Self.pick.hasPrefix("cloud:") {
            if Self.cloud == nil { why = L("لا يوجد مفتاح للخدمة السحابية المختارة — أضفه في «مفاتيح الخدمات»") }
            else if !UserDefaults.standard.bool(forKey: "cloudConsent") { why = L("يجب أن توافق على تنبيه الخصوصية للوكيل السحابي أولًا") }
            // زر الإنترنت في خانة الكتابة = البحث في الويب؛ الوكيل السحابي (مثل الدردشة السحابية) بوابته الموافقة + المفتاح
        }
        if let why {
            slog("agent: start refused: \(why)")
            // لو شغّال ما نلمس فقاعة المهمة الحالية
            if !running, let t = chatTarget { ChatStore.shared.updateText(t.msg, in: t.conv, L("🤖 لم أبدأ: %@", why), save: true); chatTarget = nil }
            return why
        }
        runID &+= 1
        // التطبيقات اللي تذكرها المهمة: مرشّحين لمعرفة التطبيق اللي قدّام بدون عميل الوصول
        let gn = Self.normName(g)
        XCTBackend.taskCandidates = Self.apps.filter { e in
            e.names.contains { let n = Self.normName($0); return n.count >= 3 && gn.contains(n) } || (Self.normName(e.en).count >= 3 && gn.contains(Self.normName(e.en)))
        }.map { $0.bundle }.filter { !$0.isEmpty }
        XCTBackend.recentOpened = []
        self.goal = g; log = []; lastResult = ""; running = true; stepNo = 0; firstRead = true
        timeline = []; pendingDetails = []
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // يبقى صاحي لما نطلع لتطبيقات ثانية (هنا مو داخل الحلقة عشان ما يسبق finish)
        HostPairing.shared.keepAlive(true)
        say(L("الهدف: %@", g))
        surface(L("جارٍ البدء…"))
        // ننتظر المهمة القديمة تخلص تنظيفها (الجلسة) قبل نبدأ
        let old = task
        let id = runID
        task = Task { await old?.value; await self.loop(id) }
        return nil
    }

    func stop() {
        task?.cancel()
        answer(false)
        if running { say(L("⏹️ توقّف")) }
        else if Runner.isOn { RunnerActivity.idle(after: 0) } else { RunnerActivity.end() }
        finish(L("توقّف بناءً على طلبك"))
    }

    /// وضع الأتمتة انطفى وسط المهمة: غالبًا هو وقفه بأزرار الصوت
    func automationEnded(_ why: String) {
        guard running else { return }
        slog("agent: automation ended mid-task: \(why)")
        task?.cancel()
        answer(false)
        say(L("⏹️ توقّف وضع الأتمتة (أزرار الصوت؟) — %@", why))
        XCTBackend.automationWanted = false
        finish(L("أوقفتَ المهمة: انطفأ وضع الأتمتة أثناء التنفيذ. أرسل المهمة من جديد إن أردت الإكمال"))
    }

    func answer(_ yes: Bool) {
        if confirmCont != nil, let i = timeline.indices.last, timeline[i].state == .ask {
            timeline[i].state = yes ? .running : .failed
            timeline[i].details.append(yes ? L("تمت الموافقة") : L("رُفضت"))
        }
        if running, confirmCont != nil { updateBubble() }
        confirm = nil
        confirmCont?.resume(returning: yes); confirmCont = nil
    }

    /// رقم المهمة الحالية: الحلقة القديمة (بعد وقف وبدء مهمة جديدة بسرعة) ما تنهي الجديدة ولا تطفّي أتمتتها
    private var runID = 0

    /// إنهاء من داخل الحلقة: بس لو هي لسا المهمة الحالية (الحلقة القديمة بعد وقف+بدء سريع ما تنهي الجديدة)
    private func finishLoop(_ id: Int, _ r: String) {
        guard id == runID else { slog("agent: finish ignored from old loop: \(r.prefix(80))"); return }
        finish(r)
    }

    private func finish(_ r: String) {
        guard running else { return }
        running = false; lastResult = r
        // اللي ما كمل يصير ✗: الشغالة/المنتظرة فاشلة، واللي ما وصلناه متخطّى
        let ok = r.hasPrefix("✅")
        for k in timeline.indices {
            switch timeline[k].state {
            case .running, .ask: timeline[k].state = ok ? .done : .failed
            case .pending: timeline[k].state = .skipped
            default: break
            }
        }
        updateBubble(final: true)
        unsurface()
        AgentNotify.done(r)
        HostPairing.shared.keepAlive(false)
        let id = runID
        if Self.see == .xct || XCTBackend.automationWanted || XCTBackend.automationEnabled {
            Task { @MainActor in if self.runID == id && !self.running { await XCTBackend.endTask() } }
        }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("agent-vision.jpg"))
        slog("agent: finish \(r)")
    }

    /// من داخل الحلقة: بس لو هي المهمة الحالية
    private func sayLoop(_ id: Int, _ s: String) { if id == runID { say(s) } }

    private func say(_ s: String) {
        log.append(Step(text: s)); slog("agent: \(s.prefix(300))")
        track(s)
        if running { surface(s); updateBubble() }
    }

    // ───── الحلقة ─────
    private func loop(_ myID: Int) async {
        if Task.isCancelled { return }
        if Self.see == .share { ScreenShare.shared.start() }
        let bg = BGTask("agent")
        defer { bg.end() }
        // أي خروج من الحلقة (فشل، إلغاء، رجوع مبكر بدون finish): نطفّي وضع الأتمتة
        defer { if Self.see == .xct { Task { @MainActor in if self.runID == myID && !self.running { await XCTBackend.endTask() } } } }
        // الطريقة المختارة بس، بدون رجوع لطريقة ثانية. XCTest: نشغّل وضع الأتمتة تلقائيًا وننتظره
        if Self.see == .xct {
            if SawtXCTPhoneLocked() {
                sayLoop(myID, L("✗ الجهاز مقفل"))
                finishLoop(myID, L("توقّف: الجهاز مقفل — افتح القفل وأرسل المهمة مرة أخرى")); return
            }
            if !XCTBackend.runnerReady || !Runner.isOn { sayLoop(myID, L("الطريقة: XCTest — جارٍ تشغيل المشغّل… (أدخل رمز الجهاز إن طُلب)")) }
            if let e = await Runner.set(true) {
                sayLoop(myID, L("✗ لم يعمل XCTest: %@", String(e.prefix(200))))
                finishLoop(myID, L("توقّف: لم يعمل المشغّل — %@", String(e.prefix(160)))); return
            }
            if let e = await XCTBackend.beginTask() {
                sayLoop(myID, "✗ \(e.prefix(200))")
                if XCTBackend.sessionDead {
                    finishLoop(myID, L("توقّف: %@ — سيعيد Sowtly التشغيل ويُعيد تشغيل المشغّل تلقائيًا، ثم أرسل المهمة مرة أخرى", String(e.prefix(120))))
                    Runner.relaunch(title: L("أعاد Sowtly التشغيل ليتمكّن من قراءة الشاشة"), body: L("افتح Sowtly وسيعمل المشغّل تلقائيًا، ثم أرسل المهمة مرة أخرى"), turnOnNext: true)
                    return
                }
                finishLoop(myID, L("توقّف: %@", String(e.prefix(160)))); return
            }
            sayLoop(myID, L("✓ الطريقة: XCTest — %@؛ وضع الأتمتة مفعّل", XCTBackend.sessionState))
        } else {
            sayLoop(myID, L("الطريقة: %@", Self.see.title))
        }
        if Task.isCancelled { return }
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
                if Self.see == .xct && fails >= 2 {
                    sayLoop(myID, "✗ \(lastReadError)")
                    finishLoop(myID, L("توقّف: %@", lastReadError)); return
                }
                if fails >= 3 { finishLoop(myID, L("تعذّرت قراءة الشاشة")); return }
                try? await Task.sleep(nanoseconds: 800_000_000); continue
            }
            fails = 0
            n += 1
            stepNo = n
            var (app, els) = scr
            if isSelf {
                // ما نلمس واجهة صوت نفسها أبدًا: نطلع للرئيسية ونعيد القراءة
                sayLoop(myID, L("Sowtly في الواجهة — جارٍ الانتقال إلى الشاشة الرئيسية"))
                let hr = await Self.exec(.keys("home"))
                // الانتقال ياخذ وقت: نعيد القراءة لين ثانيتين ونص بدل ما نحكم من أول قراءة
                var s2: (String, [Element])?
                for i in 0..<5 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    if let r = await readScreen(), !isSelf { s2 = r; slog("agent: left sawt after \((i + 1) * 500)ms"); break }
                }
                guard let s2 else {
                    finishLoop(myID, L("تعذّر الخروج من Sowtly (الشاشة الرئيسية: %1$@؛ القراءة: %2$@)", String(hr.prefix(80)), lastReadError.isEmpty ? L("ما زال Sowtly في الواجهة") : lastReadError)); return
                }
                (app, els) = s2
            }
            let axMs = Int(Date().timeIntervalSince(tAX) * 1000)
            surfaceThinking()
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
                    let prevHidden = Self.hiddenRows
                    els = Self.rank(els, screen: UIScreen.main.bounds, cap: limit)
                    // rank يصفّر ويعد الصفوف اللي انطوت هالمرة بس؛ نضيف اللي انطوت قبل (العناصر المقصوصة الثانية مو صفوف)
                    Self.hiddenRows = prevHidden + Self.hiddenRows
                    screenText = Self.describe(app: app, els)
                    user = user.components(separatedBy: "الشاشة الحالية:\n")[0] + "الشاشة الحالية:\n" + screenText
                    userQ = user
                    slog("agent: context overflow — retry with \(limit) elements")
                    continue
                }
                attempt += 1
                action = Self.parse(raw)
                if action != nil { break }
                if raw.isEmpty, Self.cpuSpecForStep() != nil || Self.cloud != nil { break }   // خطأ تحميل/ذاكرة على المعالج: ما نعيد
            }
            if Task.isCancelled { return }
            let llmMs = Int(Date().timeIntervalSince(tLLM) * 1000)
            slog("agent: raw step=\(n) «\(raw.prefix(300))»")
            log.append(Step(text: L("🤖 النموذج (%1$@ms%2$@): %3$@", String(llmMs), img == nil ? "" : L("، مع صورة"), String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))))
            pendingDetails.append(L("رد النموذج (%1$@ms): %2$@", String(llmMs), String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))))
            guard action?["action"] is String else {
                sayLoop(myID, L("⚠️ رد غير مفهوم: %@", String(raw.prefix(120)))); finishLoop(myID, L("لم يُرجع النموذج خطوة صالحة")); return
            }
            let acts = Self.actions(raw)
            var actMs = 0
            var screenChanged = false
            for action in acts {
                guard let kind = action["action"] as? String else { continue }
                // بعد لمس/فتح/رجوع الشاشة تغيّرت: أرقام العناصر قديمة، نوقف الدفعة ونقرأ من جديد
                if screenChanged, kind == "tap" || kind == "done" || kind == "longpress" || action["id"] != nil {
                    slog("agent: batch stopped (stale ids after screen change)"); break
                }
                if kind == "tap" || kind == "longpress" || action["id"] != nil, !((action["id"] as? Int).map { els.indices.contains($0) } ?? false) {
                    sayLoop(myID, L("⚠️ رقم عنصر غير موجود: %@", "\(action["id"] ?? "؟")"))
                    history.append("رقم غلط \(action["id"] ?? "؟") — اختر رقم من القائمة"); lastFailed = true; break
                }
                let desc = Self.describeAction(action, els)
                sayLoop(myID, "\(n). 🤖 \(desc)")
                if kind == "done" {
                    let sum = (action["summary"] as? String) ?? L("تم")
                    // لازم نتأكد من الشاشة: أول done نعيد القراءة ونسأله يتحقق
                    // done أول خطوة بالرد = النموذج شاف الشاشة الحالية نفسها (ما صار شي بعد القراءة): ما نحتاج قراءة+تفكير زيادة
                    let freshScreen = !screenChanged && actMs == 0 && !lastFailed
                    if !verifying && n < maxSteps && !freshScreen {
                        verifying = true
                        sayLoop(myID, L("🔎 جارٍ التحقق من الشاشة قبل إعلان الانتهاء"))
                        history.append("قال خلص (\(sum)) — يتحقق")
                        break
                    }
                    finishLoop(myID, "✅ \(sum)"); return
                }
                verifying = false
                if let why = Self.sensitive(action, els) {
                    let ok = await askConfirm(L("%1$@\n%2$@\nهل أكمل؟", why, desc))
                    if Task.isCancelled { return }
                    if !ok { sayLoop(myID, L("رُفضت — توقّف الوكيل")); finishLoop(myID, L("أُلغيت المهمة قبل خطوة حساسة")); return }
                }
                let tA = Date()
                let r = await perform(kind, action, els)
                actMs += Int(Date().timeIntervalSince(tA) * 1000)
                history.append(desc + (r.ok ? "" : " (فشل: \(r.info.prefix(60)))"))
                lastFailed = !r.ok
                if !r.ok { sayLoop(myID, "⚠️ \(r.info.prefix(160))"); break }
                if Task.isCancelled { return }
                if ["tap", "longpress", "open", "back", "home", "swipe", "url", "search", "enter"].contains(kind) || (kind == "type" && action["id"] != nil) {
                    screenChanged = true
                    if acts.count > 1 { try? await Task.sleep(nanoseconds: 400_000_000) }
                }
            }
            slog("agent: timing step=\(n) ax=\(axMs)ms llm=\(llmMs)ms action=\(actMs)ms els=\(els.count) acts=\(acts.count)")
            let timing = L("⏱ قراءة %1$@ ث · تفكير %2$@ ث · تنفيذ %3$@ ث (%4$@ عنصر%5$@)",
                           String(format: "%.1f", Double(axMs) / 1000), String(format: "%.1f", Double(llmMs) / 1000),
                           String(format: "%.1f", Double(actMs) / 1000), String(els.count),
                           LLMService.onCPU ? L("، المعالج") : "")
            log.append(Step(text: timing))
            if let i = timeline.indices.last { timeline[i].details.append(timing) }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        finishLoop(myID, L("بلغتُ الحد الأقصى (%@ خطوات) قبل الانتهاء", String(maxSteps)))
    }

    private func askConfirm(_ q: String) async -> Bool {
        say("❓ \(q)")
        confirm = q
        surface(L("بانتظار تأكيدك: %@", String(q.prefix(70))), waiting: true)
        AgentNotify.agentConfirm(q)
        // بدون رد خلال دقيقتين = لا
        let token = UUID(); confirmToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.confirmToken == token, self.confirmCont != nil else { return }
            self.say(L("⏱️ لم يصل رد — اعتُبرت الإجابة «لا»")); self.answer(false)
        }
        return await withCheckedContinuation { c in confirmCont = c }
    }

    // ───── النموذج ─────
    static let system = """
    أنت وكيل يتحكم بجوال iPhone نيابة عن المستخدم. كل مرة تشوف وصف الشاشة كقائمة عناصر مرقّمة، وتختار خطوة وحدة بس.
    رد بسطر JSON واحد فقط بدون أي كلام ثاني، بأحد هذي الأشكال:
    {"action":"tap","id":N}   (N = رقم العنصر المطلوب من القائمة بالضبط، مو مثال)
    {"action":"type","text":"النص"}   (يكتب في الخانة المفتوحة)
    {"action":"type","id":N,"text":"النص"}   (يضغط الخانة N ويكتب فيها بخطوة وحدة)
    {"action":"longpress","id":N}     (ضغط مطوّل على العنصر، مثل قائمة الخيارات)
    {"action":"wait","s":2}           (ينتظر ١-٣ ثواني لو الشاشة لسا تحمّل)
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

    /// GBNF: يجبر الرد يكون خطوة JSON وحدة أو {"actions":[…]} حتى ٣
    static let grammar = #"""
    root ::= act | multi
    multi ::= "{\"actions\":[" act ("," act)? ("," act)? "]}"
    act ::= tap | type | typeat | longpress | wait | simple | swipe | open | url | search | done
    typeat ::= "{\"action\":\"type\",\"id\":" [0-9] [0-9]? ",\"text\":" str "}"
    longpress ::= "{\"action\":\"longpress\",\"id\":" [0-9] [0-9]? "}"
    wait ::= "{\"action\":\"wait\",\"s\":" [1-3] "}"
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

    /// اختيار شاشة الوكيل: "" = نفس صفحة النماذج حسب الجهاز، "cpu:<id>" نموذج معالج، "gpu:<repo>" نموذج كرت شاشة
    static var pick: String { UserDefaults.standard.string(forKey: "agentModelPick") ?? "" }
    /// نموذج المعالج اللي يشتغل للوكيل الحين (nil = كرت الشاشة)
    /// مزوّد سحابي مختار للوكيل (لو فيه مفتاح)
    static var cloud: CloudProvider? {
        let p = pick
        // «تلقائي» يتبع صفحة النماذج: لو فيه نموذج سحابي مفعّل للدردشة، الوكيل يستخدمه
        if p.isEmpty { return CloudLLM.active }
        guard p.hasPrefix("cloud:"), let c = CloudProvider(rawValue: String(p.dropFirst(6))), c.hasKey else { return nil }
        return c
    }
    /// نموذج محلي على كرت الشاشة: أثناء المهمة صوت بالخلفية وiOS يمنع كرت الشاشة هناك، فما نبدأ (بدون تحويل تلقائي)
    static var blockedByGPU: Bool {
        let p = pick
        if cloud != nil || p.hasPrefix("cloud:") { return false }
        return ComputeMode.current == "gpu" || p.hasPrefix("gpu:")
    }

    static func cpuSpecForStep() -> GGUFSpec? {
        let p = pick
        if cloud != nil { return nil }
        if p.hasPrefix("cloud:") { return LLMService.onCPU ? GGUFSpec.active : nil }
        if p.hasPrefix("cpu:"), let s = GGUFSpec.all.first(where: { "cpu:" + $0.id == p }), s.isDownloaded { return s }
        if p.hasPrefix("gpu:") { return nil }   // ممنوع من البداية (blockedByGPU)، بدون تبديل صامت للمعالج
        return LLMService.onCPU ? GGUFSpec.active : nil
    }

    /// اسم النموذج اللي اختار آخر خطوة (يظهر فوق نتيجة المهمة)
    private var agentModelName = ""

    private func ask(_ user: String, image: URL? = nil) async -> String {
        let t0 = Date()
        var model = "gpu-mlx"
        defer { slog("agent: model=\(model) \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        // سحابي (اختياري، بمفتاح المستخدم): النص + الصورة يروحون لخوادم المزوّد
        if let c = Self.cloud {
            model = "cloud-\(c.rawValue):\(c.model)\(image == nil ? "" : "+img")"
            agentModelName = LLMService.prettyModel(c.model)
            do { return try await CloudAgent.ask(c, system: Self.system, user: user, image: image) }
            catch {
                slog("agent: cloud error \(c.rawValue)")   // بدون تفاصيل ممكن فيها بيانات
                say("⚠️ \(error)")
                return ""
            }
        }
        // على المعالج: نموذج المعالج المختار من صفحة النماذج (llama.cpp) مع قيود الصيغة
        if let spec = Self.cpuSpecForStep() {
            model = "\(spec.id)-cpu+gbnf"
            agentModelName = spec.name
            guard spec.isDownloaded else { say(L("⚠️ %@ غير محمَّل — حمِّله من صفحة النماذج ← المعالج", spec.name)); return "" }
            do { return try await LlamaEngine.of(spec).complete(system: Self.system, user: user, maxTokens: 256, grammar: Self.grammar) }
            catch {
                slog("agent: cpu error \(error)")
                if "\(error)".contains("أطول من سياق") { overflowed = true; return "" }
                say("⚠️ \(spec.name): \(error)")
                return ""
            }
        }
        // على كرت الشاشة: نموذج MLX المختار، بدون قيود، تحليل صارم
        var out = ""
        do {
            let st = try await LLMService.shared.stream(system: Self.system, history: [], user: user, maxTokens: 256,
                                                        images: image.map { [$0] } ?? [])
            agentModelName = LLMService.shared.lastModelName
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
        return ["tap", "type", "longpress", "wait", "enter", "swipe", "open", "url", "search", "back", "home", "done"].contains(k)
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

    /// المخطط الحقيقي للرابط (tel/sms/mailto/…)، أو nil لو نطاق مجرد أو host:port (google.com، localhost:3000، example.com:8080)
    static func urlScheme(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) else { return nil }
        let rest = t[r.upperBound...]
        let head = String(t[r].dropLast()).lowercased()
        // host:port = اسم فيه نقطة أو localhost، وبعده أرقام (tel:0501234567 يبقى مخطط tel)
        if head.contains(".") || head == "localhost",
           rest.range(of: "^[0-9]+([/?#]|$)", options: .regularExpression) != nil { return nil }
        return head
    }

    /// نفس القاعدة اللي يستخدمها التأكيد: بدون مخطط = https
    static func webURL(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return URL(string: urlScheme(t) == nil ? "https://\(t)" : t)
    }

    static func firstJSONArray(_ s: String) -> String {
        guard let a = s.firstIndex(of: "[") else { return "[]" }
        var depth = 0
        var inStr = false, esc = false
        for i in s[a...].indices {
            let c = s[i]
            if inStr {
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                continue
            }
            if c == "\"" { inStr = true; continue }
            if c == "[" { depth += 1 }
            if c == "]" { depth -= 1; if depth == 0 { return String(s[a...i]) } }
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
        var inStr = false, esc = false
        for i in s[a...].indices {
            let c = s[i]
            // الأقواس داخل النصوص ما تنحسب
            if inStr {
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                continue
            }
            if c == "\"" { inStr = true; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        guard let end else { return nil }
        let j = String(s[a...end])
        guard let o = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any] else { return nil }
        if let arr = o["actions"] as? [[String: Any]], let f = arr.first(where: { valid($0) }) { return f }
        guard let k = o["action"] as? String,
              ["tap", "type", "longpress", "wait", "enter", "swipe", "open", "url", "search", "back", "home", "done"].contains(k) else { return nil }
        return o
    }

    // ───── الشاشة ─────
    private func readScreen() async -> (String, [Element])? {
        lastReadError = ""
        if Self.see == .xct {
            let b = UIScreen.main.bounds
            if let s = await XCTBackend.readFront(screen: b.size) {
                Self.searchKey = false; Self.hiddenRows = 0
                lastFront = s.bundle
                slog("agent: frontmost=\(s.bundle) via=xct \(s.ms)ms raw=\(s.raw)")
                if s.isSelf { return (s.name, []) }
                var els = s.nodes.map { Element(kind: $0.kind, label: $0.label, value: $0.value, frame: $0.frame, secure: $0.secure) }
                els = els.filter { $0.frame.intersects(b) }
                Self.searchKey = Self.detectSearchKey(els, screen: b)
                // على المعالج (التطبيق بالخلفية) كل رمز في الطلب يكلّف: قائمة أقصر
                els = Self.rank(els, screen: b, cap: LLMService.onCPU ? 35 : 60)
                return (s.name, els)
            }
            slog("agent: xct read failed: \(XCTBackend.lastAXError)")
            lastReadError = L("فشلت قراءة XCTest: %@", String(XCTBackend.lastAXError.prefix(160)))
            return nil
        }
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
                say(L("قراءة من الصورة (%@ نص)", String(o.count))); return ("؟", Array(o.prefix(45))) }
            say(L("⚠️ قراءة الشاشة: %@", String(r.prefix(160)))); return nil
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
        Self.searchKey = Self.detectSearchKey(els, screen: b)
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
    static let safeEnterLabels: Set<String> = ["search", "بحث", "ابحث", "البحث", "go", "انتقال", "اذهب", "الذهاب", "ذهاب", "done", "تم", "next", "التالي"]
    static let browsers: Set<String> = ["com.apple.mobilesafari", "com.google.chrome.ios", "org.mozilla.ios.Firefox", "com.microsoft.msedge", "com.brave.ios.browser", "com.duckduckgo.mobile.ios"]

    /// مفتاح الإدخال في الكيبورد مكتوب عليه بحث/انتقال/تم؟ (زر أو مفتاح في النص السفلي، قبل القص لأن الكيبورد يجي آخر الشجرة)
    static func detectSearchKey(_ els: [Element], screen b: CGRect) -> Bool {
        let bottom = els.filter { ($0.kind == "key" || $0.kind == "button") && $0.frame.minY > b.height * 0.5 }
        let hit = bottom.contains { e in
            [e.label, e.value].contains { safeEnterLabels.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }
        }
        if !hit, els.contains(where: { $0.kind == "key" }) {
            // للتشخيص: أسماء آخر أزرار الكيبورد (مفتاح الإدخال عادة يمين تحت)
            let tail = bottom.suffix(4).map { "\($0.kind):\($0.label)" }.joined(separator: "، ")
            slog("agent: keyboard return key not recognized; bottom: \(tail)")
        }
        return hit
    }

    /// الإدخال آمن؟ مفتاح بحث/انتقال، أو متصفح (شريط العنوان/البحث)، أو خانة بحث فيها النص اللي كتبناه
    static var frontNow = ""
    static func enterIsSafe(_ els: [Element]) -> Bool {
        if searchKey { return true }
        if browsers.contains(frontNow) { return true }
        return els.contains { $0.kind == "search" && !$0.value.isEmpty }
    }

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
            if (bar && ["button", "link", "other", "image"].contains(e.kind)) { return 1 }
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
            let lc = LLMService.onCPU ? 24 : 30, vc = LLMService.onCPU ? 16 : 20
            if !e.label.isEmpty { l += " \"\(e.label.prefix(lc))\"" }
            if !e.value.isEmpty && e.value != e.label { l += " = \"\(e.value.prefix(vc))\"" }
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
        case "type": return "اكتب «\((a["text"] as? String ?? "").prefix(60))»" + ((a["id"] as? Int).map { " في [\($0)]" } ?? "")
        case "longpress":
            let i = (a["id"] as? Int) ?? -1
            return "ضغط مطوّل [\(i)] \(els.indices.contains(i) ? els[i].label : "؟")"
        case "wait": return "انتظار \((a["s"] as? Int) ?? 1) ث"
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

    /// إنجليزي: صيغ محددة للكلمة (send→sending, pay→payments)؛ عربي: الجذر داخل الكلمة بعد توحيد الهمزات
    /// (يرسل/ترسل/ارسل)، والمصدر «ارسال» ككلمة كاملة بس عشان «رسالة» ما تنحسب
    static let riskyEN = ["send", "delete", "remove", "pay", "buy", "purchase", "subscribe", "transfer", "call", "post",
                          "confirm", "order", "checkout", "submit", "share", "reply", "reset", "erase", "install", "uninstall",
                          "logout", "signout", "sign out", "log out", "unsubscribe", "accept", "approve"]
    static let riskyAR = ["رسل", "حذف", "مسح", "دفع", "شراء", "اشتر", "اشترك", "تحويل", "اتصل", "اتصال", "نشر",
                          "تاكيد", "اكد", "طلب", "شارك", "مشارك", "رد", "تثبيت", "ثبت", "تسجيل الخروج", "خروج", "اعادة تعيين", "قبول"]

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
        // نوحّد الهمزات والتشكيل: «إرسال/أرسل/ارسال» كلها تصير «ارسال/ارسل»
        let low = String(String.UnicodeScalarView(text.lowercased().unicodeScalars.compactMap { u -> Unicode.Scalar? in
            if (0x064B...0x0652).contains(u.value) || u.value == 0x0640 { return nil }
            if [0x0623, 0x0625, 0x0622].contains(u.value) { return Unicode.Scalar(0x0627) }
            return u
        }))
        let toks = low.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        for t in toks {
            if t.unicodeScalars.first.map({ $0.value < 0x0600 }) == true {
                if riskyEN.contains(where: { !$0.contains(" ") && Self.inflections($0).contains(t) }) { return true }
            } else {
                // «رد» قصيرة: بس كلمة كاملة (رد/الرد/ورد)، الباقي جذر داخل الكلمة
                if ["رد", "الرد", "ورد"].contains(t) { return true }
                // المصدر «إرسال» كلمة كاملة بس (مو «رسالة»)
                for base in ["ارسال", "الارسال", "وارسال", "للارسال", "بارسال"] {
                    if t == base { return true }
                    // مع ضمير: ارساله/ارسالها/ارسالهم/ارسالك/ارسالكم/ارسالنا
                    if t.hasPrefix(base), ["ه", "ها", "هم", "هما", "هن", "ك", "كم", "كي", "نا"].contains(String(t.dropFirst(base.count))) { return true }
                }
                if riskyAR.contains(where: { $0.count >= 3 && !$0.contains(" ") && t.contains($0) }) { return true }
            }
        }
        return (riskyEN + riskyAR).contains { $0.contains(" ") && low.contains($0) }
    }

    static func sensitive(_ a: [String: Any], _ els: [Element]) -> String? {
        let k = a["action"] as? String ?? ""
        if k == "tap" || k == "longpress", let i = a["id"] as? Int, els.indices.contains(i) {
            // الاسم أو القيمة (بعض الأزرار اسمها فاضي والنص في القيمة)
            for l in [els[i].label, els[i].value] where !l.isEmpty {
                if l.split(separator: " ").count <= 4, Self.hasWord(l) { return L("خطوة حساسة (إرسال/حذف/دفع).") }
            }
        }
        if k == "type", let i = a["id"] as? Int, els.indices.contains(i), els[i].secure { return L("الكتابة في خانة كلمة مرور.") }
        if k == "type", els.contains(where: { $0.secure }) { return L("توجد خانة كلمة مرور على الشاشة.") }
        // روابط تتصل/ترسل مباشرة (tel/sms/mailto/facetime…) مو تصفح
        if k == "url", let u = a["url"] as? String, Self.urlScheme(u).map({ $0 != "http" && $0 != "https" }) ?? false {
            return L("الرابط يفتح اتصالًا أو رسالة أو تطبيقًا مباشرة.")
        }
        // بحث: مفتاح الكيبورد «Search» ما يرسل، فما نوقف الوكيل ونسأل عن كل بحث
        if k == "enter" { return enterIsSafe(els) ? nil : L("زر الإدخال قد يُرسل.") }
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
            // مع رقم عنصر: نضغطه أول (خطوة وحدة بدل ثنتين)
            if let i = a["id"] as? Int {
                guard els.indices.contains(i) else { return (false, "رقم عنصر غلط") }
                let f = els[i].frame
                let (x, y) = Self.norm(CGPoint(x: f.midX, y: f.midY))
                let r = ok(await Self.exec(.tap(x, y)))
                if !r.0 { return r }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return ok(await Self.typeText(t))
        case "longpress":
            guard let i = a["id"] as? Int, els.indices.contains(i) else { return (false, "رقم عنصر غلط") }
            guard Self.see == .xct else { return (false, "الضغط المطوّل يحتاج طريقة XCTest") }
            let f = els[i].frame
            return ok(await XCTBackend.longPress(CGPoint(x: f.midX, y: f.midY)))
        case "wait":
            let sec = min(3, max(1, (a["s"] as? Int) ?? 1))
            try? await Task.sleep(nanoseconds: UInt64(sec) * 1_000_000_000)
            return (true, "waited \(sec)s")
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
                // https بس للنطاق المجرد (example.com)؛ tel:/sms:/mailto: وغيرها تبقى كما هي (وتمر على التأكيد)
                u = Self.webURL(t)
            }
            guard let u else { return (false, "رابط غير صالح") }
            return await openURL(u)
        default:
            return (false, "خطوة غير معروفة")
        }
    }

    // ───── النظر ─────
    /// طريقة رؤية الشاشة: قراءة النصوص (الافتراضي) أو مشاركة الشاشة (صورة + أرقام العناصر)
    enum See: String, CaseIterable { case ax, share, xct
        var title: String {
            switch self {
            case .ax: return L("قراءة النصوص")
            case .share: return L("مشاركة الشاشة")
            case .xct: return L("XCTest (بدون بث)")
            }
        }
    }
    static var see: See {
        get { See(rawValue: UserDefaults.standard.string(forKey: "agentSee") ?? "") ?? .ax }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agentSee") }
    }

    /// صورة الشاشة مصغّرة مع أرقام العناصر مرسومة عليها: من البث لو شغّال، وإلا لقطة من خدمة الأدوات
    private func visionImage(_ els: [Element], lastFailed: Bool) async -> URL? {
        let cloud = Self.cloud != nil
        // السحابي يشوف الصور دائمًا (لقطة لو البث طافي)؛ المحلي بس في وضع مشاركة الشاشة
        guard cloud || Self.see == .share else { return nil }
        // XCTest: النص يكفي غالبًا؛ الصورة بس لو آخر خطوة فشلت أو ما فيه عناصر، أو لو الخيار «صورة كل خطوة» شغّال
        if Self.see == .xct && !UserDefaults.standard.bool(forKey: "agentAlwaysShot") && !lastFailed && !els.isEmpty {
            slog("agent: vision skipped (xct text enough)"); return nil
        }
        if !cloud, Self.cpuSpecForStep() != nil { slog("agent: vision skipped (cpu/llama.cpp, no mmproj) — text only"); return nil }
        if !cloud { guard await ModelManager.shared.ensureVision() else { slog("agent: vision unavailable"); return nil } }
        guard let fr = await currentFrame() else { return nil }
        let (img, src) = fr
        let mode = src
        let w: CGFloat = cloud ? 768 : 448
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
        slog("agent: type via=\(see == .xct ? "xct" : "paste") chars=\(t.count)")
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
        if let hit, !hit.bundle.isEmpty, UserDefaults.standard.bool(forKey: "agentBundleLaunch") || PhoneAgent.see == .xct {
            let r = await Self.exec(.launch(hit.bundle))
            slog("agent: open chosen=\(hit.bundle) via=table ok=\(r.contains("\"ok\":true"))")
            if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 700_000_000); return (true, r) }
            say(L("⚠️ إطلاق %1$@: %2$@", hit.bundle, String(r.prefix(120))))
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
            let ok = await askConfirm(L("وجدتُ أكثر من تطبيق باسم «%1$@»: %2$@.\nهل أفتح «%3$@»؟", name, names.joined(separator: "، "), names[0]))
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
        // XCTest: نفتح الرابط مباشرة (XCUIDevice.system openURL) بخطوة وحدة؛ لو مو مدعوم نكمل بسبوتلايت (كله عبر XCTest)
        if Self.see == .xct {
            let r = await XCTBackend.openURL(u)
            if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 1_000_000_000); return (true, r) }
            slog("agent: xct openURL failed, spotlight via xct: \(r.prefix(160))")
        }
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
        // XCTest مختار: اللمس والسحب والهوم وفتح التطبيق بالمعرّف عن طريقه فقط، ونتيجته ترجع كما هي (بدون رجوع لـsawtctl).
        // الكتابة والإدخال كذلك عن طريق XCTest (typeText، والإدخال = "\n").
        if see == .xct, let r = await XCTBackend.handle(op, screen: UIScreen.main.bounds.size) { return r }
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
                case "agent.yes": PhoneAgent.shared.answerFromOutside(true)
                case "agent.no": PhoneAgent.shared.answerFromOutside(false)
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
        let stop = UNNotificationAction(identifier: "agent.stop", title: L("إيقاف"), options: [.destructive])
        // بدون .foreground: الرد يوصل للتطبيق وهو بالخلفية بدون ما يفتح
        let yes = UNNotificationAction(identifier: "agent.yes", title: L("موافق"), options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let no = UNNotificationAction(identifier: "agent.no", title: L("رفض"), options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "agent.run", actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "agent.confirm", actions: [yes, no, stop], intentIdentifiers: []),
        ])
    }

    static func progress(goal: String, step: String) {
        let c = UNMutableNotificationContent()
        c.title = L("الوكيل يعمل: %@", String(goal.prefix(50)))
        c.body = step
        c.categoryIdentifier = "agent.run"
        c.interruptionLevel = .passive
        c.threadIdentifier = "agent"
        // نفس المعرّف = يستبدل نفسه (إشعار واحد ثابت)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-progress", content: c, trigger: nil))
    }

    static func agentConfirm(_ q: String) {
        let c = UNMutableNotificationContent()
        c.title = L("Sowtly يحتاج تأكيدك")
        c.body = q
        c.sound = .default
        c.categoryIdentifier = "agent.confirm"
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-confirm", content: c, trigger: nil))
    }

    static func done(_ r: String) {
        clear()
        let c = UNMutableNotificationContent()
        c.title = L("انتهى الوكيل")
        c.body = r
        c.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-done", content: c, trigger: nil))
    }

    static func clearConfirm() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agent-confirm"])
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
    @State private var refusal: String?
    @State private var starting = false
    @FocusState private var goalFocused: Bool
    @State private var see = PhoneAgent.see
    @AppStorage("agentMaxSteps") private var maxSteps = 10
    @State private var testOut = ""
    @State private var xctOut = ""
    @State private var xctRunning = false
    @State private var xctWaiting = false
    @State private var xctChecks = XCTestProbe.localChecks()
    @State private var tapOut = ""
    @State private var tapRunning = false
    @State private var tapHits = 0
    @State private var targetFrame = CGRect.zero
    @AppStorage("xctAutomation") private var xctAuto = false
    @AppStorage("phoneIntentAuto") private var intentAuto = true
    @AppStorage("runnerCleanRelaunch") private var cleanRelaunch = true
    @State private var autoStatus = XCTBackend.sessionState
    @State private var autoBusy = false
    @State private var shareLive = false
    @AppStorage("agentModelPick") private var agentPick = ""
    @State private var keysVersion = 0
    @State private var askConsent = false
    @State private var pendingPick = ""
    @ObservedObject private var models = ModelManager.shared

    /// لمسة «ابدأ»: اهتزاز خفيف فورًا + «جاري البدء…»، نقفل الكيبورد، وبعدين نبدأ (والسبب يطلع لو ما بدأ)
    private func tapStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        slog("agent: ui start tapped")
        starting = true
        refusal = nil
        goalFocused = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)   // نخلي الكيبورد ينزل والواجهة تتحدث
            let r = agent.start(goal)
            starting = false
            refusal = r
            if let r { UINotificationFeedbackGenerator().notificationOccurred(.error); slog("agent: ui refusal shown \(r.prefix(80))") }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("ماذا تريد أن أفعل؟ مثال: افتح الملاحظات واكتب مرحبًا", text: $goal, axis: .vertical)
                    .focused($goalFocused)
                if agent.running {
                    Button(role: .destructive) { agent.stop() } label: {
                        Label("إيقاف", systemImage: "stop.circle.fill").font(.title3.bold()).frame(maxWidth: .infinity)
                    }
                } else {
                    Button(action: tapStart) {
                        HStack(spacing: 8) {
                            if starting { ProgressView().controlSize(.small) }
                            Text(starting ? L("جارٍ البدء…") : L("ابدأ")).font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    // زر مستقل (مو صف الفورم): يستجيب من أول لمسة حتى والكيبورد مفتوح
                    .buttonStyle(.borderedProminent)
                    .disabled(starting || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let r = refusal, !agent.running {
                    Label(L("لم يبدأ: %@", r), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Picker("نموذج الوكيل", selection: $agentPick) {
                    Text("مثل صفحة النماذج (تلقائي)").tag("")
                    Section("على الجهاز") {
                        ForEach(GGUFSpec.all.filter { $0.isDownloaded }) { Text(L("المعالج: %@", "\($0.name)")).tag("cpu:" + $0.id) }
                        ForEach(Catalog.llms.filter { models.downloaded.contains($0.id) }) { Text(L("معالج الرسوميات: %@", "\($0.title)")).tag("gpu:" + $0.id) }
                    }
                    let free = CloudProvider.free.filter { keysVersion >= 0 && $0.hasKey }
                    if !free.isEmpty {
                        Section("سحابي مجاني") { ForEach(free) { Text("\($0.short): \($0.model)").tag("cloud:" + $0.rawValue) } }
                    }
                    let paid = CloudProvider.paid.filter { keysVersion >= 0 && $0.hasKey }
                    if !paid.isEmpty {
                        Section("سحابي مدفوع") { ForEach(paid) { Text("\($0.short): \($0.model)").tag("cloud:" + $0.rawValue) } }
                    }
                }
                .onChange(of: agentPick) { old, v in
                    if v.hasPrefix("cloud:"), !UserDefaults.standard.bool(forKey: "cloudConsent") { pendingPick = old; askConsent = true }
                }
                Text(agentPick.isEmpty
                     ? L("يستخدم ما اخترته في صفحة النماذج: معالج الرسوميات والتطبيق في الواجهة، والمعالج في الخلفية، أو النموذج السحابي إن كان مفعّلًا.")
                     : agentPick.hasPrefix("cloud:") ? L("سحابي: يُرسَل نص الشاشة وصورتها في كل خطوة إلى خوادم الخدمة. يعمل في الخلفية لكنه يحتاج إلى الإنترنت.")
                     : (agentPick.hasPrefix("gpu:") ? L("إذا كان التطبيق في الخلفية (المعالج فقط) يعود إلى نموذج المعالج المختار.") : L("يعمل على المعالج حتى والتطبيق في الواجهة.")))
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("مفاتيح الخدمات") { CloudKeysView(onChange: { keysVersion += 1 }) }
                Picker("الحد الأقصى للخطوات", selection: $maxSteps) {
                    ForEach([10, 20, 30], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("طريقة رؤية الشاشة", selection: $see) {
                    ForEach(PhoneAgent.See.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: see) { _, v in PhoneAgent.see = v; if v == .share { ScreenShare.shared.start() } }
                if see == .share {
                    HStack {
                        Text(shareLive ? L("البث يعمل 🔴") : L("اضغط الزر ثم «بدء البث»"))
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
                Text("«XCTest»: يقرأ شجرة التطبيق الظاهر ويلمس عبر أدوات الاختبار دون بث (يحتاج إلى LocalDevVPN، وقد يطلب رمز الجهاز في المرة الأولى). إذا فشل يعود إلى الطريقة العادية تلقائيًا.\n«مشاركة الشاشة»: يرسل صورة الشاشة مع أرقام العناصر إلى نموذج الرؤية (إذا كان البث متوقفًا يلتقط صورة). الصورة تعمل على معالج الرسوميات فقط؛ وعلى المعالج نص فقط.\nيقرأ الشاشة ويختار خطوة واحدة في كل مرة (الحد حسب الإعداد). أي إرسال أو حذف أو دفع أو كلمة مرور يوقفه ويسألك. يمكنك إيقافه في أي وقت.")
            }
            if let q = agent.confirm {
                Section("يحتاج إلى تأكيد") {
                    Text(q)
                    HStack {
                        Button("متابعة") { agent.answer(true) }.buttonStyle(.borderedProminent)
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
            Section {
                Button {
                    guard !xctRunning else { return }
                    xctRunning = true
                    xctWaiting = false
                    xctOut = ""
                    slog("xct: probe tapped")
                    Task { @MainActor in
                        let cfg = await XCTestProbe.connectionConfig()
                        let lines = await XCTestProbe.run(cfg: cfg,
                                                          onChecks: { c in Task { @MainActor in xctChecks = c } },
                                                          onWaiting: { Task { @MainActor in xctWaiting = true } })
                        xctOut = lines.joined(separator: "\n")
                        xctWaiting = false
                        xctRunning = false
                    }
                } label: {
                    HStack {
                        Text(xctRunning ? L("جارٍ الاختبار…") : L("اختبار XCTest (تجريبي)"))
                        if xctRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(xctRunning)
                // قائمة الشروط: تتحدّث لحالها مع كل اختبار
                ForEach(xctChecks) { c in
                    HStack(alignment: .top) {
                        Text(c.ok == nil ? "○" : (c.ok! ? "✓" : "✗"))
                            .foregroundStyle(c.ok == nil ? Color.secondary : (c.ok! ? Color.green : Color.red))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            if !c.note.isEmpty { Text(c.note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
                if xctWaiting { Text("دورك: أدخل رمز الجهاز إن طلبه iOS").foregroundStyle(.orange) }
                if !xctOut.isEmpty { Text(xctOut).font(.footnote.monospaced()).textSelection(.enabled) }
                // وضع الأتمتة: جلسة XCTest دائمة تنبني من جديد لحالها لو انقطعت
                Toggle(isOn: Binding(get: { xctAuto }, set: { on in
                    autoBusy = true
                    Task { @MainActor in
                        let e = await Runner.set(on)
                        autoStatus = e.map { "✗ " + String($0.prefix(120)) } ?? XCTBackend.sessionState
                        autoBusy = false
                    }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("المشغّل (وضع الأتمتة مع المهام)")
                        Text(autoBusy ? L("جارٍ التجهيز… (أدخل رمز الجهاز إن طُلب)") : autoStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(autoBusy)
                .task {
                    // يحدّث الحالة كل ثانيتين، ويرجّع الجلسة لو المفتاح شغّال من قبل
                    await Runner.resume()
                    while !Task.isCancelled {
                        if !autoBusy { autoStatus = XCTBackend.sessionState }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
                Toggle(isOn: $cleanRelaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("إعادة تشغيل نظيفة عند الإيقاف")
                        Text("عند إيقاف المشغّل يُغلق Sowtly ويرسل إليك إشعارًا؛ ويبدأ التشغيل التالي بجلسة جديدة تقرأ الشاشة")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $intentAuto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("يفهم المهام من المحادثة تلقائيًا")
                        Text(intentAuto ? L("عندما يعمل المشغّل: الأوامر مثل «افتح الملاحظات» تصبح مهمة، والدردشة والأسئلة تبقى محادثة") : L("المهام فقط عبر «/جوال …»"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("صورة الشاشة في كل خطوة (أبطأ)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "agentAlwaysShot") },
                    set: { UserDefaults.standard.set($0, forKey: "agentAlwaysShot") }))
                Toggle("قراءة الشاشة بلقطة XCUIApplication (المجرّبة)", isOn: Binding(
                    get: { (UserDefaults.standard.string(forKey: "xctReader") ?? "app") != "ax" },
                    set: { UserDefaults.standard.set($0 ? "app" : "ax", forKey: "xctReader") }))
                // اختبار الضغط: XCTest يلمس الهدف هذا، ولو العدّاد زاد يعني اللمس وصل فعلًا
                Button(L("🎯 هدف الضغط: %@", String(tapHits))) { tapHits += 1 }
                    .buttonStyle(.bordered)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { targetFrame = $0 }
                Button {
                    guard !tapRunning, targetFrame != .zero else { return }
                    tapRunning = true
                    tapOut = ""
                    slog("xct: tap test tapped")
                    Task { @MainActor in
                        let before = tapHits
                        tapOut = L("… الاتصال: بدأ")
                        let cfg = await XCTestProbe.connectionConfig()
                        let target = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                        // كل سطر يطلع أول ما تبدأ الخطوة وأول ما تخلص، فلو علّقت نعرف وين
                        let ok = await XCTBackend.tapTest(
                            cfg: cfg, target: target, screen: UIScreen.main.bounds.size,
                            onLine: { l in Task { @MainActor in tapOut += (tapOut.isEmpty ? "" : "\n") + l } },
                            onChecks: { c in Task { @MainActor in xctChecks = c } })
                        if ok {
                            // اللمسة توصل للواجهة بعد شوي: ننتظر ونشيك العدّاد
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            let hit = tapHits > before
                            let l = "\(hit ? "✓" : "✗") target: " + (hit ? L("تم الضغط على الهدف (%1$@ → %2$@)", String(before), String(tapHits)) : L("لم يتغيّر العدّاد"))
                            slog("xct: tapTest \(l)")
                            tapOut += "\n" + l
                        }
                        tapRunning = false
                    }
                } label: {
                    // بدون مؤشر دوّار: الحركة المستمرة تخلي XCTest ينتظر هدوء التطبيق
                    Text(tapRunning ? L("جارٍ اختبار الضغط… (السجل أدناه)") : L("اختبار الضغط"))
                }
                .disabled(tapRunning || xctRunning)
                if !tapOut.isEmpty {
                    Text(tapOut).font(.footnote.monospaced()).textSelection(.enabled)
                    Button("نسخ السجل") { UIPasteboard.general.string = tapOut }
                }
            } footer: {
                Text("«اختبار الضغط»: يجهّز الجلسة، ويقيس سرعة قراءة الشاشة، ويجعل XCTest يلمس زر «هدف الضغط»؛ إذا زاد العدّاد فاللمس يعمل.\nيجرّب طريقة التحكم الجديدة: يطلب من testmanagerd عبر الاتصال المحلي تفويض Sowtly لاختبار الواجهة، ثم يحمّل أدوات الاختبار ويقرأ الشاشة الرئيسية. قد يطلب iOS رمز الجهاز لتفعيل الأتمتة.")
            }
            if !agent.log.isEmpty {
                Section("الخطوات") {
                    ForEach(agent.log) { s in Text(s.text).font(.footnote) }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("الوكيل (تجريبي)")
        .alert("الوكيل السحابي", isPresented: $askConsent) {
            Button("أوافق", role: .destructive) { UserDefaults.standard.set(true, forKey: "cloudConsent") }
            Button("إلغاء", role: .cancel) { agentPick = pendingPick }
        } message: {
            Text("عند اختيار نموذج سحابي، يُرسَل نص الشاشة (أسماء الأزرار والعناصر) وصورة الشاشة في كل خطوة إلى خوادم الخدمة التي اخترتها، وفق سياسة خصوصيتها. لا تستخدمه على شاشات تحتوي على معلومات حساسة. يظهر هذا التنبيه مرة واحدة.")
        }
    }
}

/// مفاتيح الخدمات السحابية للوكيل (نفس مفاتيح صفحة النماذج)
struct CloudKeysView: View {
    var onChange: () -> Void
    var body: some View {
        Form { CloudSections(showActivate: false, onChange: onChange) }
            .navigationTitle("مفاتيح الخدمات")
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
        // نفي بس لو أداة النفي قبل فعل المضارع مباشرة: «لا توقف»/«ما توقف»/«don't stop». «لا، وقف» = وقف
        for i in toks.indices.dropFirst() where ["لا", "ما"].contains(toks[i - 1]) && toks[i].hasPrefix("ت") && toks[i].contains("وقف") { return false }
        if [" dont stop", " don t stop", " do not stop", " never stop", " not stop"].contains(where: { (" " + s).contains($0) }) { return false }
        // كلمة كاملة بس (مو «موقف» ولا «stopwatch»)
        // «خلاص» لحالها ما توقف (خلاص فهمت / طيب خلاص)؛ بس «بس خلاص» كأمر كامل
        let stops: Set<String> = ["وقف", "اوقف", "أوقف", "توقف", "وقفه", "وقفها", "stop"]
        if ["بس خلاص", "stop it", "كفاية", "كفايه", "بس كفاية", "بس كفايه"].contains(s) { return true }
        return toks.contains { stops.contains($0) }
    }
    static let chatPrefixes = ["/جوال", "/agent", "جوال:", "نفذ على الجوال", "نفّذ على الجوال"]
    // «على الجوال» لحالها كانت تشتغل مع أسئلة عادية («على الجوال وش أحسن…»)؛ لازم فعل أمر
    static let voicePrefixes = ["نفذ على الجوال", "نفّذ على الجوال", "سو على الجوال", "سوّ على الجوال", "يا صوت نفذ", "يا صوت نفّذ", "do on the phone", "on the phone do"]
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


/// مشغّل الأتمتة (مثل زر Poki): مصدر واحد للحالة (xctAutomation) يستخدمه زر الشريط الجانبي ومفتاح صفحة الوكيل.
/// التشغيل يجهّز جلسة XCTest ويخلي التطبيق صاحي في الخلفية بس، بدون تفعيل وضع الأتمتة؛
/// وضع الأتمتة (التعتيم والعلامة) يتفعّل لما تبدأ مهمة وينطفي لما تخلص.
@MainActor
enum Runner {
    private static var alive = false
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "xctAutomation") }

    /// يشغّل أو يطفّي. يرجع سبب الفشل لو ما اشتغل
    @discardableResult
    static func set(_ on: Bool) async -> String? {
        UserDefaults.standard.set(on, forKey: "xctAutomation")
        RunnerActivity.observe()
        if on {
            // تشغيل واحد بالمرة (الزر وفتح التطبيق وبداية المهمة ممكن يطلبونه سوا)
            if starting {
                while starting { try? await Task.sleep(nanoseconds: 200_000_000) }
                return XCTBackend.runnerReady ? nil : L("لم يعمل المشغّل")
            }
            starting = true
            defer { starting = false }
            PhoneAgent.see = .xct
            // جلسة هذا التشغيل تسكّرت/ماتت: القراءة ما ترجع إلا بعملية جديدة (مثل Poki)، فنعيد التشغيل ويرجع المشغّل لحاله
            if XCTBackend.sessionDead {
                relaunch(title: L("أعاد Sowtly التشغيل ليتمكّن من قراءة الشاشة"), body: L("افتح Sowtly وسيعمل المشغّل تلقائيًا"), turnOnNext: true)
                return L("أُغلقت الجلسة في هذا التشغيل؛ سيعيد Sowtly التشغيل ويُعيد تشغيل المشغّل تلقائيًا")
            }
            if !alive { alive = true; HostPairing.shared.keepAlive(true) }
            let busy = PhoneAgent.shared.running
            if !busy && !XCTBackend.runnerReady { RunnerActivity.show(RunnerActivity.state("prep", L("جارٍ تجهيز جلسة XCTest")), goal: L("المشغّل")) }
            let e = await XCTBackend.startAutomation()
            if !busy {
                if let e { RunnerActivity.show(RunnerActivity.state("sleep", L("لم يعمل: %@", String(e.prefix(60)))), goal: L("المشغّل")) }
                else { RunnerActivity.idle(after: 0) }
            }
            return e
        } else {
            RunnerActivity.end()
            if alive { alive = false; HostPairing.shared.keepAlive(false) }
            if PhoneAgent.shared.running { PhoneAgent.shared.stop() }
            await XCTBackend.disableAutomation()
            XCTBackend.stopAutomation()
            if cleanRelaunch {
                relaunch(title: L("توقّف المشغّل"), body: L("افتح Sowtly لتشغيل المشغّل مرة أخرى"), turnOnNext: false)
            }
            return nil
        }
    }

    /// إعادة تشغيل نظيفة عند الإيقاف (افتراضيًا شغّالة)
    static var cleanRelaunch: Bool { UserDefaults.standard.object(forKey: "runnerCleanRelaunch") as? Bool ?? true }
    private static var relaunching = false
    private static var starting = false

    /// مثل Poki: حالة XCTest داخل العملية (sharedSession والجهاز المحلي وعميل الوصول) تبقى مربوطة بالجلسة القديمة،
    /// والطريق المضمون لجلسة تقرأ الشاشة هو عملية جديدة. نرسل إشعار يرجّعه، نروح للرئيسية، ونطلع.
    static func relaunch(title: String, body: String, turnOnNext: Bool) {
        guard !relaunching else { return }
        relaunching = true
        UserDefaults.standard.set(turnOnNext, forKey: "runnerWantsOn")
        if turnOnNext { UserDefaults.standard.set(true, forKey: "xctAutomation") }
        slog("runner: relaunch (\(title)) turnOnNext=\(turnOnNext)")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sawt.relaunch", content: c, trigger: nil)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                UserDefaults.standard.synchronize()
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            }
        }
    }

    /// عند فتح التطبيق: لو كان شغّال نرجّعه
    static func resume() async {
        if UserDefaults.standard.bool(forKey: "runnerWantsOn") {
            UserDefaults.standard.set(false, forKey: "runnerWantsOn")
            slog("runner: turning on after relaunch")
            await set(true); return
        }
        if isOn && !XCTBackend.runnerReady { await set(true) }
        else if isOn && !alive {
            alive = true; HostPairing.shared.keepAlive(true)
            RunnerActivity.observe()
            if !PhoneAgent.shared.running { RunnerActivity.idle(after: 0) }
        }
    }

    /// نص الحالة القصير للزر
    static var stateText: String {
        if !isOn { return L("متوقف") }
        if PhoneAgent.shared.running { return L("يعمل: الخطوة %@", String(PhoneAgent.shared.stepNo)) }
        return XCTBackend.runnerReady ? L("يعمل (في وضع السكون)") : L("جارٍ التجهيز…")
    }
}

/// زر تشغيل المشغّل (مثل زر Poki): برتقالي «متوقف» / أخضر «شغّال»
struct RunnerPill: View {
    @AppStorage("xctAutomation") private var on = false
    @State private var busy = false
    @State private var text = Runner.stateText
    @State private var error: String?
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            pill
            HStack(spacing: 6) {
                Text(on ? L("جاهز لتنفيذ مهام الجهاز") : L("شغّله لأتمكّن من التحكم بالجهاز وتنفيذ المهام"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ما هو المشغّل؟")
            }
            .padding(.horizontal, 6)
        }
        .sheet(isPresented: $showInfo) { RunnerInfoSheet() }
    }

    private var pill: some View {
        Button {
            guard !busy else { return }
            busy = true
            let target = !on
            Task { @MainActor in
                error = await Runner.set(target).map { String($0.prefix(140)) }
                busy = false
                text = Runner.stateText
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: busy ? "hourglass" : "power")
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ? L("جارٍ التجهيز… (أدخل رمز الجهاز إن طُلب)") : text).font(.subheadline.bold())
                    if let error, !busy { Text("✗ " + error).font(.caption2).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Text("المشغّل").font(.caption).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(on ? Color.green : Color.orange))
        }
        .buttonStyle(.plain)
        .task {
            await Runner.resume()
            while !Task.isCancelled {
                if !busy { text = Runner.stateText }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}


/// شرح قصير للمشغّل
struct RunnerInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    item("power", L("ما هو المشغّل؟"),
                         L("هو ما يتيح لـSowtly رؤية الشاشة والضغط والكتابة نيابةً عنك في أي تطبيق."))
                    item("bolt.horizontal", L("لماذا يجب أن يعمل؟"),
                         L("يتم التحكم عبر جلسة XCTest (أداة الاختبار من Apple). يفتح المشغّل هذه الجلسة ويبقيها جاهزة، ومن دونها لا أستطيع لمس الجهاز."))
                    item("network", L("ماذا يحتاج؟"),
                         L("أن يكون LocalDevVPN متصلًا، وأن تكون صورة المطوّر (DDI) محمّلة عبر StikDebug. إذا كان أحدهما متوقفًا فلن يعمل المشغّل."))
                    item("sun.min", L("أثناء المهمة"),
                         L("تُعتم الشاشة وتظهر علامة أثناء المهمة، وهذا من النظام. اترك الجهاز ولا تلمس الشاشة حتى أنتهي."))
                    item("stop.circle", L("كيف أوقفه؟"),
                         L("أوقفه بزر الإيقاف في الجزيرة الديناميكية، أو بضغطة طويلة على زرَّي الصوت معًا. ويمكنك أيضًا كتابة «توقف» في المحادثة."))
                }
                .padding(20)
            }
            .navigationTitle("المشغّل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("حسنًا") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .environment(\.layoutDirection, AppLang.layout)
    }

    private func item(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// النشاط المباشر حق المشغّل (الجزيرة الديناميكية): نايم / جاهز / يجهّز / يفكّر / الخطوة N / خلص
@MainActor
enum RunnerActivity {
    private static var current: Activity<AgentActivityAttributes>?
    private static var idleTask: Task<Void, Never>?
    private static var observing = false

    static func state(_ phase: String, _ step: String) -> AgentActivityAttributes.ContentState {
        .init(step: step, n: 0, waiting: false, phase: phase, task: nil)
    }

    static func show(_ st: AgentActivityAttributes.ContentState, goal: String) {
        idleTask?.cancel(); idleTask = nil
        // نشاط انتهى (من النظام أو المستخدم) ما نحدّثه: نبدأ واحد جديد
        if let a = current, a.activityState != .active && a.activityState != .stale { current = nil }
        if current == nil { current = Activity<AgentActivityAttributes>.activities.first { $0.activityState == .active } }
        if let a = current {
            Task { await a.update(ActivityContent(state: st, staleDate: nil)) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            current = try? Activity.request(attributes: AgentActivityAttributes(goal: String(goal.prefix(60))),
                                            content: ActivityContent(state: st, staleDate: nil))
            slog("runner: activity \(current == nil ? "failed" : "started")")
        }
    }

    /// جاهز، وبعد دقيقة بدون مهمة: نايم
    static func idle(after seconds: Double) {
        let wait = UInt64(max(0, seconds) * 1_000_000_000)
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            guard !Task.isCancelled, Runner.isOn, !PhoneAgent.shared.running else { return }
            show(state("ready", L("أرسل مهمة في المحادثة")), goal: L("المشغّل"))
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, Runner.isOn, !PhoneAgent.shared.running else { return }
            show(state("sleep", L("يستيقظ عند إرسال مهمة")), goal: L("المشغّل"))
        }
    }

    static func end() {
        idleTask?.cancel(); idleTask = nil
        let a = current; current = nil
        Task {
            await a?.end(nil, dismissalPolicy: .immediate)
            for x in Activity<AgentActivityAttributes>.activities { await x.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// زر «إطفاء» في الجزيرة يطفّي المشغّل
    static func observe() {
        if observing { return }
        observing = true
        NotificationCenter.default.addObserver(forName: Notification.Name("sawt.stopRunner"), object: nil, queue: .main) { _ in
            Task { @MainActor in await Runner.set(false) }
        }
    }
}
