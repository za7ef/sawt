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
            let ascii = t.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 }
            return ok(await Self.exec(.keys(ascii ? t : "paste:" + t)))
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
            let app = a["app"] as? String ?? ""
            guard !app.isEmpty else { return (false, "اسم التطبيق فاضي") }
            // الشاشة الرئيسية → سحب لتحت (بحث) → نكتب الاسم → إدخال
            var r = await Self.exec(.keys("home"))
            guard r.contains("\"ok\":true") else { return (false, r) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let b = UIScreen.main.bounds
            let (x, y1) = Self.norm(CGPoint(x: b.midX, y: b.height * 0.4)), (_, y2) = Self.norm(CGPoint(x: 0, y: b.height * 0.65))
            r = await Self.exec(.drag(x, y1, x, y2))
            try? await Task.sleep(nanoseconds: 900_000_000)
            let ascii = app.unicodeScalars.allSatisfy { $0.isASCII }
            r = await Self.exec(.keys(ascii ? app : "paste:" + app))
            try? await Task.sleep(nanoseconds: 900_000_000)
            r = await Self.exec(.keys("return"))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return ok(r)
        default:
            return (false, "خطوة غير معروفة")
        }
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
