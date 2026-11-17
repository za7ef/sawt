import Foundation
import MLXLMCommon
import SwiftUI

/// ذاكرة طويلة المدى على الجهاز فقط: حقائق قصيرة عن المستخدم يستخرجها النموذج بعد المحادثة.
struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    var updated = Date()
    /// مثبّتة: تنضاف للتعليمات دايمًا وما تنحذف تلقائيًا
    var pinned: Bool?
    var isPinned: Bool { pinned ?? false }
    /// متى انحذفت تلقائيًا (سلة المحذوفات، تنمسح بعد 7 أيام)
    var deletedAt: Date?
    /// الأهمية 1-5 حسب تقدير النموذج (القديمة بدونها = 3)
    var importance: Int?
    var level: Int { importance ?? 3 }
    /// هوية، تفضيلات، ناس، خطط، صحة، شغل، أخرى
    var category: String?
    /// المعلومات المؤقتة تنتهي بعد هالتاريخ
    var expires: Date?
    var isExpired: Bool { (expires ?? .distantFuture) < Date() }
}

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var items: [MemoryItem] = [] {
        didSet { MemoryStore.lock.lock(); MemoryStore.snapshot = items; MemoryStore.lock.unlock() }
    }
    /// نسخة تُقرأ من أي خيط (المكالمة تبني التعليمات خارج الخيط الرئيسي).
    nonisolated(unsafe) private static var snapshot: [MemoryItem] = []
    nonisolated private static let lock = NSLock()
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "memoryOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "memoryOn"); if !enabled { cancel() } }
    }
    @Published var isExtracting = false
    /// اللي حذفه النموذج تلقائيًا: يقدر المستخدم يرجّعها خلال 7 أيام.
    @Published private(set) var trash: [MemoryItem] = []

    static let maxItems = 150
    private var task: Task<Void, Never>?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }()

    private var trashURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("memory-trash.json") }

    private init() {
        if let list = SafeFile.load([MemoryItem].self, from: fileURL) {
            // المؤقتة اللي فات وقتها ما تنحفظ (إلا المثبّتة)
            let live = list.filter { $0.isPinned || !$0.isExpired }
            items = live
            MemoryStore.snapshot = live
            if live.count != list.count { SafeFile.write(live, to: fileURL) }
        }
        let week = Date().addingTimeInterval(-7 * 86_400)
        trash = (SafeFile.load([MemoryItem].self, from: trashURL) ?? []).filter { ($0.deletedAt ?? .distantPast) > week }
    }

    private func save() {
        SafeFile.write(items, to: fileURL)
        SafeFile.write(trash, to: trashURL)
    }

    func restore(_ id: UUID) {
        guard let i = trash.firstIndex(where: { $0.id == id }) else { return }
        var m = trash.remove(at: i)
        m.deletedAt = nil
        items.insert(m, at: 0)
        save()
    }

    func emptyTrash() { trash = []; save() }

    /// الحذف التلقائي ما يصير إلا إذا المستخدم قال صراحة إن المعلومة غلط أو طلب ينساها.
    static func hasForgetCue(_ s: String) -> Bool { ForgetCues.matches(s) }

    // MARK: تعديل يدوي

    func update(_ id: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if t.isEmpty { items.remove(at: i) } else { items[i].text = t; items[i].updated = Date() }
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = !items[i].isPinned
        save()
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var m = MemoryItem(text: t)
        m.importance = 4   // أضافها بنفسه
        items.insert(m, at: 0)
        save()
    }

    func delete(_ ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        cancel()
        items = []
        trash = []
        save()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isExtracting = false
    }

    // MARK: الاسترجاع

    /// أسطر قصيرة تنضاف لتعليمات النظام: الأقرب للرسالة + الأحدث، بحد أقصى.
    nonisolated static func promptBlock(for query: String, limit: Int = 6) -> String {
        let on = UserDefaults.standard.object(forKey: "memoryOn") as? Bool ?? true
        lock.lock(); let items = snapshot; lock.unlock()
        guard on, !items.isEmpty else { return "" }
        let q = Self.tokens(query)
        let qg = Self.trigrams(query)
        let live = items.filter { $0.isPinned || !$0.isExpired }
        // المثبّتة + الأهم جدًا (5) تنضاف دايمًا
        let always = live.filter { $0.isPinned || $0.level >= 5 }
            .sorted { ($0.isPinned ? 1 : 0, $0.level) > ($1.isPinned ? 1 : 0, $1.level) }
        let pinned = always.prefix(limit).map { $0.text }
        let alwaysIDs = Set(always.prefix(limit).map { $0.id })
        var scored: [(MemoryItem, Double)] = live.filter { !alwaysIDs.contains($0.id) }.map { item in
            let overlap = Double(q.intersection(Self.tokens(item.text)).count)
            let tri = Self.jaccard(qg, Self.trigrams(item.text))
            let age = Date().timeIntervalSince(item.updated) / 86_400
            let rel = overlap * 2 + tri * 3
            // الأهمية ترفع الترتيب، بس ما تجيب شي ما له علاقة أبدًا
            return (item, rel * (0.7 + 0.15 * Double(item.level)) + Double(item.level - 3) * 0.3 + max(0, 1 - age / 30) * 0.5)
        }
        scored.sort { $0.1 > $1.1 }
        var picked = pinned + scored.prefix(max(0, limit - pinned.count)).map { $0.0.text }
        var chars = 0
        picked = picked.filter { chars += $0.count; return chars <= 600 }
        guard !picked.isEmpty else { return "" }
        return "معلومات تعرفها عن المستخدم من محادثات سابقة (استخدمها إذا تفيد، ولا تذكرها بدون داعي):\n"
            + picked.map { "- " + $0 }.joined(separator: "\n")
    }

    nonisolated static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        let map: [String: String] = ["أ": "ا", "إ": "ا", "آ": "ا", "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي"]
        for (a, b) in map { t = t.replacingOccurrences(of: a, with: b) }
        t = t.unicodeScalars.filter { !(0x064B ... 0x0652).contains($0.value) }.map(String.init).joined()
        return t
    }

    nonisolated static let stop: Set<String> = ["في", "من", "على", "الى", "عن", "مع", "هو", "هي", "انا", "انت", "و", "او", "يا",
                                    "the", "a", "an", "is", "are", "to", "of", "and", "in", "my", "i", "you", "ما", "لا", "اللي"]

    nonisolated static func tokens(_ s: String) -> Set<String> {
        let words = normalize(s).components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out = Set<String>()
        for var w in words where !w.isEmpty {
            // حروف ملتصقة شائعة: و/ف/ب/ل/ك + ال (والقهوة → قهوه)
            if w.count > 4, let f = w.first, "وفبلك".contains(f) {
                let rest = String(w.dropFirst())
                if rest.hasPrefix("ال") { w = rest }
            }
            if w.hasPrefix("ال"), w.count > 3 { w = String(w.dropFirst(2)) }
            if w.hasPrefix("لل"), w.count > 4 { w = String(w.dropFirst(2)) }
            if w.count < 2 || stop.contains(w) { continue }
            out.insert(w)
        }
        return out
    }

    /// ثلاثيات الحروف: تلقط الكلمات بتصريفات مختلفة (يشتغل/شغله/الشغل).
    nonisolated static func trigrams(_ s: String) -> Set<String> {
        var out = Set<String>()
        for w in tokens(s) {
            let c = Array(w)
            if c.count < 3 { out.insert(w); continue }
            for i in 0 ... (c.count - 3) { out.insert(String(c[i ..< i + 3])) }
        }
        return out
    }

    nonisolated static func jaccard(_ x: Set<String>, _ y: Set<String>) -> Double {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        max(jaccard(tokens(a), tokens(b)), jaccard(trigrams(a), trigrams(b)) * 0.9)
    }

    // MARK: الاستخراج

    /// يُستدعى بعد انتهاء الرد. يستنى شوي ويشتغل بس إذا النموذج فاضي.
    /// `onSaved` يتنادى إذا انحفظ شي جديد.
    func extractLater(exchanges: [(user: String, assistant: String)], onSaved: (() -> Void)? = nil) {
        guard enabled, !exchanges.isEmpty else { return }
        let joined = exchanges.map { $0.user }.joined()
        guard joined.count >= 8 else { return }
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            // لا نزاحم الدردشة أو المكالمة
            // ولا نشتغل والتطبيق بالخلفية (iOS ما يسمح بكرت الشاشة هناك)
            while ChatStore.shared.isGenerating || CallController.isActive
                    || UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
            isExtracting = true
            let mine = task
            // نرجّعها false بس لو ما بدأ استخراج أحدث بعدنا
            defer { if task == mine || task == nil { isExtracting = false } }
            let added = await run(exchanges)
            if Task.isCancelled { return }
            if added > 0 { onSaved?() }
        }
    }

    private func run(_ exchanges: [(user: String, assistant: String)]) async -> Int {
        guard await LLMService.shared.isReady else { return 0 }
        // نعطي النموذج المعروف مرقّم عشان يقدر يعدّل أو يحذف
        let query = exchanges.map { $0.user }.joined(separator: " ")
        let qg = Self.trigrams(query)
        let relevant = Array(items.sorted { Self.jaccard(qg, Self.trigrams($0.text)) > Self.jaccard(qg, Self.trigrams($1.text)) }.prefix(25))
        let known = relevant.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        let convo = exchanges.suffix(6).map {
            "المستخدم: \($0.user.prefix(400))\nالمساعد: \($0.assistant.prefix(200))"
        }.joined(separator: "\n")
        let today = { () -> String in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let system = """
        مهمتك تقرر وش يستاهل ينحفظ عن المستخدم من كلامه هو فقط (مو كلام المساعد)، وكم أهميته.
        لا تحفظ: السوالف والتحيات، الأسئلة العامة أو اللي مرة وحدة، المزاج اللحظي، أي شي يقدر ينعرف من السؤال نفسه.
        احفظ: هويته وأهله وناسه، تفضيلاته الثابتة، شغله، أهدافه وخططه، صحته، وأي شي قال "تذكر".

        الأهمية:
        5 = أساسي دايم (اسمه، أهله، حساسية أو مرض، شي قال تذكره)
        4 = مهم ويتكرر (شغله، مدينته، هدف كبير، تفضيل قوي)
        3 = مفيد (هواية، تفضيل عادي، خطة قريبة)
        2 = بسيط أو عابر
        1 = تافه
        المدة: دائم، أو مؤقت، أو تاريخ انتهاء بصيغة YYYY-MM-DD للخطط والمواعيد (اليوم \(today)).
        الفئة وحدة من: هوية، تفضيلات، ناس، خطط، صحة، شغل، أخرى.

        اكتب كل عملية في سطر، بجملة قصيرة جدًا بلغة المستخدم:
        + أهمية | فئة | مدة | الحقيقة
        ~ رقم | أهمية | الصيغة الجديدة   (إذا كلامه يحدّث حقيقة معروفة: عدّلها بدل ما تضيف سطر جديد)
        x رقم   (إذا قال إن حقيقة معروفة غلط أو طلب ينساها)
        إذا ما فيه شي يستاهل، اكتب: لا شيء

        أمثلة:
        المستخدم: هلا كيفك → لا شيء
        المستخدم: وش عاصمة اليابان؟ → لا شيء
        المستخدم: والله تعبان اليوم → لا شيء
        المستخدم: بنتي بيان عمرها ثلاث شهور → + 5 | ناس | دائم | عنده بنت اسمها بيان (انولدت تقريبًا قبل ثلاث شهور)
        المستخدم: عندي موعد أسنان يوم الخميس الجاي → + 3 | صحة | <تاريخ الخميس> | عنده موعد أسنان الخميس
        المستخدم: تذكر إني ما آكل بصل → + 5 | تفضيلات | دائم | ما ياكل بصل
        المستخدم: نقلت شغلي للرياض (والمعروف 2. يشتغل في جدة) → ~ 2 | 4 | صار يشتغل في الرياض
        """
        let user = """
        المعروف حاليًا:
        \(known.isEmpty ? "(فاضي)" : known)

        المحادثة:
        \(convo)
        """
        var out = ""
        do {
            let s = try await LLMService.shared.stream(system: system, history: [], user: user, maxTokens: 220)
            for try await c in s {
                if Task.isCancelled { return 0 }
                out += c
            }
        } catch {
            slog("memory: extract failed \(error)")
            return 0
        }
        var ops: [MemoryLine] = []
        for raw in out.components(separatedBy: .newlines) {
            if let op = MemoryLine.parse(raw) { ops.append(op) }
            if ops.count == 6 { break }
        }
        var added = 0, skipped = 0
        let mayForget = exchanges.contains { Self.hasForgetCue($0.user) }
        let remember = exchanges.contains { MemoryLine.hasRememberCue($0.user) }
        for op in ops {
            switch op {
            case .add(let l, var imp, let cat, let exp):
                if remember { imp = max(imp, 4) }
                // الأقل من 3 ما ينحفظ إلا إذا طلب يتذكره
                guard imp >= 3 else { skipped += 1; continue }
                if let i = items.firstIndex(where: { Self.similarity($0.text, l) >= 0.5 }) {
                    // نفس الحقيقة: نحدّثها بدل سطر جديد
                    guard !items[i].isPinned else { continue }
                    if items[i].text != l || items[i].level < imp {
                        items[i].text = l; items[i].updated = Date()
                        items[i].importance = max(items[i].level, imp)
                        items[i].category = cat; items[i].expires = exp
                        added += 1
                    }
                } else {
                    var m = MemoryItem(text: l)
                    m.importance = imp; m.category = cat; m.expires = exp
                    items.insert(m, at: 0)
                    added += 1
                }
            case .update(let n, let l, let imp):
                guard n >= 1, n <= relevant.count,
                      let i = items.firstIndex(where: { $0.id == relevant[n - 1].id }), !items[i].isPinned else { continue }
                items[i].text = l; items[i].updated = Date()
                if let imp { items[i].importance = imp }
                added += 1
            case .delete(let n):
                guard n >= 1, n <= relevant.count,
                      let i = items.firstIndex(where: { $0.id == relevant[n - 1].id }), !items[i].isPinned else { continue }
                guard mayForget else { slog("memory: delete ignored (no cue)"); continue }
                var m = items.remove(at: i)
                m.deletedAt = Date()
                trash.insert(m, at: 0)
                if trash.count > 50 { trash.removeLast(trash.count - 50) }
                added += 1
            }
        }
        if skipped > 0 { slog("memory: skipped \(skipped) low-importance") }
        items.removeAll { !$0.isPinned && $0.isExpired }
        let lines = ops   // للسجل تحت
        if items.count > Self.maxItems {
            // المثبّتة ما تنحذف
            let pins = items.filter { $0.isPinned }
            // نشيل الأقل أهمية ثم الأقدم
            let rest = items.filter { !$0.isPinned }.sorted { ($0.level, $0.updated) > ($1.level, $1.updated) }.prefix(max(0, Self.maxItems - pins.count))
            items = pins + rest
        }
        if added > 0 { save() }
        slog("memory: extracted \(lines.count) saved \(added) total \(items.count)")
        return added
    }
}

/// صفحة الذاكرة في الإعدادات.
struct MemoryView: View {
    @ObservedObject var store = MemoryStore.shared
    @State private var editing: MemoryItem?
    @State private var draft = ""
    @State private var adding = false
    @State private var confirmAll = false

    var body: some View {
        List {
            Section {
                Toggle("تفعيل الذاكرة", isOn: $store.enabled)
            } footer: {
                Text("يحفظ معلومات مهمة عنك من المحادثات ليتذكرها لاحقًا. كل شيء محفوظ على جهازك فقط.")
            }
            Section {
                if store.items.isEmpty {
                    Text("لا يوجد شيء محفوظ بعد").foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    Button {
                        draft = item.text; editing = item
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).foregroundStyle(.primary)
                                MemoryMeta(item: item)
                            }
                            if item.isPinned {
                                Spacer()
                                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { store.togglePin(item.id) } label: {
                            Label(item.isPinned ? L("إلغاء التثبيت") : L("تثبيت"), systemImage: item.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                }
                .onDelete { idx in store.delete(idx.map { store.items[$0].id }) }
                Button { draft = ""; adding = true } label: { Label("أضف معلومة", systemImage: "plus") }
            } header: {
                Text(L("المحفوظ (%@)", String(store.items.count)))
            } footer: {
                Text("اسحب أي معلومة لتثبيتها: المعلومات المثبّتة تُضاف إلى التعليمات دائمًا ولا تتغير تلقائيًا.")
            }
            if !store.trash.isEmpty {
                Section {
                    ForEach(store.trash) { item in
                        HStack {
                            Text(item.text).foregroundStyle(.secondary)
                            Spacer()
                            Button("استعادة") { store.restore(item.id) }.buttonStyle(.borderless)
                        }
                    }
                    Button("أفرغ السلة", role: .destructive) { store.emptyTrash() }
                } header: {
                    Text("حُذفت تلقائيًا")
                } footer: {
                    Text("عندما تقول إن معلومة خاطئة أو تطلب نسيانها، تُنقل إلى هنا ويمكنك استعادتها خلال ٧ أيام.")
                }
            }
            if !store.items.isEmpty {
                Section {
                    Button("حذف كل الذاكرة", role: .destructive) { confirmAll = true }
                }
            }
        }
        .navigationTitle("الذاكرة")
        .alert("تعديل", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("المعلومة", text: $draft)
            Button("حفظ") { if let e = editing { store.update(e.id, text: draft) }; editing = nil }
            Button("حذف", role: .destructive) { if let e = editing { store.delete([e.id]) }; editing = nil }
            Button("إلغاء", role: .cancel) { editing = nil }
        }
        .alert("أضف معلومة", isPresented: $adding) {
            TextField("مثلًا: أفضّل الردود القصيرة", text: $draft)
            Button("حفظ") { store.add(draft) }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("حذف كل الذاكرة؟", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) { store.deleteAll() }
        }
    }
}

/// سطر صغير تحت المعلومة: الأهمية (نقاط) والفئة، ومتى تنتهي إذا مؤقتة.
struct MemoryMeta: View {
    let item: MemoryItem
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { i in
                    Circle().frame(width: 4, height: 4).opacity(i <= item.level ? 0.9 : 0.2)
                }
            }
            .accessibilityLabel(L("الأهمية %@ من 5", String(item.level)))
            if let c = item.category { Text(L(c)) }
            if let e = item.expires {
                Text(L("حتى %@", e.formatted(.dateTime.day().month(.abbreviated).locale(AppLang.locale))))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
