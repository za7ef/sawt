import Foundation
import MLXLMCommon
import SwiftUI

/// ذاكرة طويلة المدى على الجهاز فقط: حقائق قصيرة عن المستخدم يستخرجها النموذج بعد المحادثة.
struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var created = Date()
    var updated = Date()
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

    static let maxItems = 150
    private var task: Task<Void, Never>?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }()

    private init() {
        if let list = SafeFile.load([MemoryItem].self, from: fileURL) {
            items = list
            MemoryStore.snapshot = list
        }
    }

    private func save() {
        SafeFile.write(items, to: fileURL)
    }

    // MARK: تعديل يدوي

    func update(_ id: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if t.isEmpty { items.remove(at: i) } else { items[i].text = t; items[i].updated = Date() }
        save()
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.insert(MemoryItem(text: t), at: 0)
        save()
    }

    func delete(_ ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        cancel()
        items = []
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
        var scored: [(MemoryItem, Double)] = items.map { item in
            let t = Self.tokens(item.text)
            let overlap = Double(q.intersection(t).count)
            let age = Date().timeIntervalSince(item.updated) / 86_400
            return (item, overlap * 2 + max(0, 1 - age / 30) * 0.5)
        }
        scored.sort { $0.1 > $1.1 }
        var picked = scored.prefix(limit).map { $0.0.text }
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

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
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
            defer { isExtracting = false }
            let added = await run(exchanges)
            if Task.isCancelled { return }
            if added > 0 { onSaved?() }
        }
    }

    private func run(_ exchanges: [(user: String, assistant: String)]) async -> Int {
        guard await LLMService.shared.isReady else { return 0 }
        let known = items.prefix(40).map { "- " + $0.text }.joined(separator: "\n")
        let convo = exchanges.suffix(6).map {
            "المستخدم: \($0.user.prefix(400))\nالمساعد: \($0.assistant.prefix(200))"
        }.joined(separator: "\n")
        let system = """
        مهمتك استخراج حقائق دائمة ومهمة عن المستخدم من كلامه هو فقط: تفضيلاته، أشخاص في حياته، شغله، خططه المستمرة، أشياء طلب تذكرها.
        لا تستخرج أسئلة عامة أو معلومات مؤقتة أو كلام المساعد.
        اكتب كل حقيقة في سطر يبدأ بـ "- " بجملة قصيرة جدًا بلغة المستخدم (مثل: - يحب القهوة بدون سكر).
        إذا الحقيقة تعدّل شي معروف، اكتبها بصيغتها الجديدة.
        إذا ما فيه شي جديد يستاهل، اكتب: لا شيء
        """
        let user = """
        المعروف حاليًا:
        \(known.isEmpty ? "(فاضي)" : known)

        المحادثة:
        \(convo)
        """
        var out = ""
        do {
            let s = try await LLMService.shared.stream(system: system, history: [], user: user, maxTokens: 120)
            for try await c in s {
                if Task.isCancelled { return 0 }
                out += c
            }
        } catch {
            slog("memory: extract failed \(error)")
            return 0
        }
        var lines: [String] = []
        for raw in out.components(separatedBy: .newlines) {
            let trimmed: String = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("•") else { continue }
            let body: String = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let n: Int = body.count
            if n < 4 || n > 140 || body.contains("لا شيء") { continue }
            lines.append(body)
            if lines.count == 4 { break }
        }
        var added = 0
        for l in lines {
            if let i = items.firstIndex(where: { Self.similarity($0.text, l) >= 0.5 }) {
                if items[i].text != l { items[i].text = l; items[i].updated = Date(); added += 1 }
            } else {
                items.insert(MemoryItem(text: l), at: 0)
                added += 1
            }
        }
        if items.count > Self.maxItems { items = Array(items.sorted { $0.updated > $1.updated }.prefix(Self.maxItems)) }
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
                Toggle("الذاكرة شغالة", isOn: $store.enabled)
            } footer: {
                Text("يحفظ معلومات مهمة عنك من المحادثات عشان يتذكرها بعدين. كل شي محفوظ على جوالك بس.")
            }
            Section {
                if store.items.isEmpty {
                    Text("ما فيه شي محفوظ للحين").foregroundStyle(.secondary)
                }
                ForEach(store.items) { item in
                    Button {
                        draft = item.text; editing = item
                    } label: {
                        Text(item.text).foregroundStyle(.primary)
                    }
                }
                .onDelete { idx in store.delete(idx.map { store.items[$0].id }) }
                Button { draft = ""; adding = true } label: { Label("أضف معلومة", systemImage: "plus") }
            } header: {
                Text("المحفوظ (\(store.items.count))")
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
        .confirmationDialog("تحذف كل الذاكرة؟", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) { store.deleteAll() }
        }
    }
}
