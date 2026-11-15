import SwiftUI
import UIKit
import UserNotifications

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
    private var confirmCont: CheckedContinuation<Bool, Never>?
    let maxSteps = 10

    // ───── التشغيل والإيقاف ─────
    func start(_ goal: String) {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !running else { return }
        guard PhoneControl.available, PhoneControl.hasPairing else {
            lastResult = "التحكم بالجوال مو جاهز (اقتران/الأداة)"; return
        }
        self.goal = g; log = []; lastResult = ""; running = true
        say("الهدف: \(g)")
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
        running = false; lastResult = r
        HostPairing.shared.keepAlive(false)
        slog("agent: finish \(r)")
    }

    private func say(_ s: String) {
        log.append(Step(text: s)); slog("agent: \(s.prefix(300))")
    }

    // ───── الحلقة ─────
    private func loop() async {
        // يبقى صاحي لما نطلع لتطبيقات ثانية
        HostPairing.shared.keepAlive(true)
        let bg = UIApplication.shared.beginBackgroundTask(withName: "agent") { }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        if await shortcut() { return }
        if Task.isCancelled { return }
        var history: [String] = []
        var fails = 0
        for n in 1...maxSteps {
            if Task.isCancelled { return }
            guard let scr = await readScreen() else {
                fails += 1
                if fails >= 2 { finish("ما قدرت أقرأ الشاشة"); return }
                try? await Task.sleep(nanoseconds: 800_000_000); continue
            }
            let (app, els) = scr
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
            for attempt in 0..<2 {
                raw = await ask(user + (attempt == 1 ? "\n\nردك السابق ما كان JSON صالح. رد بسطر JSON واحد فقط." : ""))
                action = Self.parse(raw)
                if action != nil { break }
            }
            if Task.isCancelled { return }
            guard let action, let kind = action["action"] as? String else {
                say("⚠️ رد غير مفهوم: \(raw.prefix(120))"); finish("النموذج ما رد بخطوة صالحة"); return
            }
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
            let r = await perform(kind, action, els)
            history.append(desc + (r.ok ? "" : " (فشل: \(r.info.prefix(60)))"))
            if !r.ok { say("⚠️ \(r.info.prefix(160))") }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        finish("وصلت الحد (\(maxSteps) خطوات) قبل ما أخلص")
    }

    private func askConfirm(_ q: String) async -> Bool {
        say("❓ \(q)")
        confirm = q
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
    في open اكتب اسم التطبيق بالإنجليزي إذا تعرفه (Notes, Settings, WhatsApp...).
    قواعد: لا تخترع أرقام عناصر غير موجودة. لو الهدف تحقق قل done. لو انحسبت نفس الخطوة مرتين بدون تغيير جرّب شي ثاني.
    """

    private func ask(_ user: String) async -> String {
        var out = ""
        do {
            let st = try await LLMService.shared.stream(system: Self.system, history: [], user: user, maxTokens: 80)
            for try await c in st {
                out += c
                if out.contains("}") , Self.parse(out) != nil { break }
            }
        } catch { slog("agent: llm error \(error)") }
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
        guard let o = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any],
              let k = o["action"] as? String,
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
        return (app, Array(els.prefix(70)))
    }

    static func describe(app: String, _ els: [Element]) -> String {
        var lines = ["التطبيق: \(app)"]
        for (i, e) in els.enumerated() {
            var l = "[\(i)] \(e.kind)"
            if !e.label.isEmpty { l += " \"\(e.label.prefix(60))\"" }
            if !e.value.isEmpty && e.value != e.label { l += " = \"\(e.value.prefix(40))\"" }
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
        case "open":
            let app = (a["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { return (false, "اسم التطبيق فاضي") }
            return await openApp(app)
        default:
            return (false, "خطوة غير معروفة")
        }
    }

    /// الإنجليزي حرف حرف؛ أي شي ثاني (عربي/رموز) دايمًا عن طريق الحافظة + Cmd+V
    static func typeText(_ t: String) async -> String {
        let ascii = t.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value < 127 }
        let hex = t.unicodeScalars.prefix(24).map { String(format: "%04X", $0.value) }.joined(separator: " ")
        slog("agent: type via=\(ascii ? "keys" : "paste") text=«\(t)» u=[\(hex)]")
        return await exec(.keys(ascii ? t : "paste:" + t))
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
        (["قوقل ماب", "خرائط قوقل", "google maps"], "com.google.Maps", "Google Maps"),
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

    static func lookup(_ name: String) -> (bundle: String, en: String)? {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "تطبيق ", with: "").replacingOccurrences(of: "برنامج ", with: "")
        for e in apps where e.names.contains(where: { n == $0 }) { return (e.bundle, e.en) }
        for e in apps where e.names.contains(where: { $0.count >= 3 && (n.contains($0) || $0.contains(n)) }) { return (e.bundle, e.en) }
        return nil
    }

    /// جدول → إطلاق بالمعرّف؛ بعدها مطابقة من التطبيقات المثبتة؛ آخر شي البحث بالاسم الإنجليزي
    func openApp(_ name: String) async -> (ok: Bool, info: String) {
        let hit = Self.lookup(name)
        slog("agent: open «\(name)» → \(hit?.bundle ?? "?")")
        if let hit, !hit.bundle.isEmpty {
            let r = await Self.exec(.launch(hit.bundle))
            if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 1_200_000_000); return (true, r) }
            say("⚠️ إطلاق \(hit.bundle): \(r.prefix(120))")
        }
        let q = hit?.en ?? name
        let r = await Self.exec(.launch(q))
        if r.contains("\"ok\":true") { try? await Task.sleep(nanoseconds: 1_200_000_000); return (true, r) }
        say("⚠️ مطابقة الاسم: \(r.prefix(120))")
        // آخر حل: البحث — بالإنجليزي بس
        guard q.unicodeScalars.allSatisfy({ $0.isASCII }) else { return (false, "ما عرفت التطبيق «\(name)»") }
        _ = await Self.exec(.keys("home"))
        try? await Task.sleep(nanoseconds: 700_000_000)
        let b = UIScreen.main.bounds
        let (x, y1) = Self.norm(CGPoint(x: b.midX, y: b.height * 0.4)), (_, y2) = Self.norm(CGPoint(x: 0, y: b.height * 0.65))
        _ = await Self.exec(.drag(x, y1, x, y2))
        try? await Task.sleep(nanoseconds: 900_000_000)
        _ = await Self.typeText(q)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let r2 = await Self.exec(.keys("return"))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
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
        let r = await PhoneControl.run(op, host: h, rpPort: port, rpHost: PhoneControl.lastRPHost)
        if !r.contains("\"ok\":true") { cachedPort = 0 }
        return r
    }
    private static var cachedPort: UInt16 = 0
}

/// إشعار تأكيد لما التطبيق بالخلفية
enum AgentNotify {
    static func agentConfirm(_ q: String) {
        let c = UNMutableNotificationContent()
        c.title = "صوت يحتاج تأكيدك"
        c.body = q
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-confirm", content: c, trigger: nil))
    }
}

struct PhoneAgentView: View {
    @ObservedObject var agent = PhoneAgent.shared
    @State private var goal = ""

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
            } footer: {
                Text("يقرأ الشاشة ويختار خطوة وحدة كل مرة (١٠ خطوات كحد أقصى). أي إرسال أو حذف أو دفع أو كلمة سر يوقف ويسألك. تقدر توقفه بأي وقت.")
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
