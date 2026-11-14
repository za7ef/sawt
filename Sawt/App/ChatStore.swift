import Foundation
import MLXLMCommon
import SwiftUI

struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var viaVoice = false
    var date = Date()
    /// انحفظ شي في الذاكرة بعد هذا الرد
    var memorySaved: Bool?
    var attachments: [Attachment]?
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "محادثة جديدة"
    var messages: [Message] = []
    var updated = Date()
}

/// يحفظ المحادثات على الجهاز، ويدير الدردشة الكتابية.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var streamingText = ""
    @Published var isGenerating = false
    @Published var error: String?

    private var genTask: Task<Void, Never>?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("conversations.json")
        // نقل المحادثات من المكان القديم
        let old = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversations.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        return url
    }()

    init() {
        if let list = SafeFile.load([Conversation].self, from: fileURL) {
            conversations = list.sorted { $0.updated > $1.updated }
        }
        currentID = conversations.first?.id
    }

    var current: Conversation? {
        guard let id = currentID else { return nil }
        return conversations.first { $0.id == id }
    }

    func newConversation() {
        stop()
        if let c = current, c.messages.isEmpty { return }
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
        save()
    }

    func select(_ id: UUID) {
        stop()
        currentID = id
    }

    func delete(_ id: UUID) {
        if let c = conversations.first(where: { $0.id == id }) {
            let atts = c.messages.flatMap { $0.attachments ?? [] }
            Task.detached(priority: .utility) { atts.forEach { $0.deleteFiles() } }
        }
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        save()
    }

    private func ensureCurrent() -> Int {
        if let id = currentID, let i = conversations.firstIndex(where: { $0.id == id }) { return i }
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
        return 0
    }

    func append(_ m: Message) {
        let i = ensureCurrent()
        conversations[i].messages.append(m)
        conversations[i].updated = Date()
        if conversations[i].title == "محادثة جديدة", m.role == .user {
            conversations[i].title = String(m.text.prefix(40))
        }
        save()
    }

    /// يستبدل رسائل المحادثة الحالية بنتيجة المكالمة.
    func syncFromCall(_ turns: [Turn]) {
        let i = ensureCurrent()
        // نفس معرّف الدور عشان الرسائل ما تنعاد رسمها كل مرة (معرّفات ثابتة)
        let voiceMsgs = turns.map { t -> Message in
            var m = Message(role: t.role == .user ? .user : .assistant, text: t.text, viaVoice: true)
            m.id = t.id
            return m
        }
        let base = conversations[i].messages.filter { callBaseIDs.contains($0.id) }
        conversations[i].messages = base + Array(voiceMsgs.dropFirst(callSeedCount))
        conversations[i].updated = Date()
        if conversations[i].title == "محادثة جديدة", let first = voiceMsgs.first(where: { $0.role == .user }) {
            conversations[i].title = String(first.text.prefix(40))
        }
        save()
    }

    private var callBaseIDs: Set<UUID> = []
    private var callSeedCount = 0

    /// يجهّز بداية المكالمة من المحادثة الحالية.
    func seedForCall() -> [Turn] {
        let msgs = current?.messages ?? []
        callBaseIDs = Set(msgs.map(\.id))
        callSeedCount = msgs.count
        return msgs.map { Turn(id: $0.id, role: $0.role == .user ? .user : .assistant, text: $0.text) }
    }

    private var saveTask: Task<Void, Never>?

    /// حفظ مؤجّل (نص ثانية) وخارج الخيط الرئيسي، عشان ما نكتب الملف كل شوي.
    func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            SafeFile.write(conversations, to: fileURL)
        }
    }

    // MARK: الدردشة الكتابية

    func send(_ text: String, attachments: [Attachment] = [], onFail: @escaping (String) -> Void = { _ in }) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty, !isGenerating else { return }
        if t.isEmpty { t = attachments.contains { $0.kind == .image } ? "وش تشوف في الصورة؟" : "لخّص لي الملف باختصار." }
        let earlier = (current?.messages ?? []).flatMap { $0.attachments ?? [] }
        // آخر الرسائل بحد أقصى ~6000 حرف (عشان سياق النموذج والذاكرة)
        var budget = 6000
        var recent: [Message] = []
        for m in (current?.messages ?? []).suffix(20).reversed() {
            budget -= m.text.count
            if budget < 0, !recent.isEmpty { break }
            recent.insert(m, at: 0)
        }
        let history = recent.map { m -> Chat.Message in
            let names = (m.attachments ?? []).map { "[مرفق: \($0.name)]" }.joined(separator: " ")
            let body = names.isEmpty ? m.text : names + "\n" + m.text
            return m.role == .user ? Chat.Message.user(body) : Chat.Message.assistant(m.text)
        }
        var userMsg = Message(role: .user, text: t)
        if !attachments.isEmpty { userMsg.attachments = attachments }
        append(userMsg)
        let convID = currentID
        genConv = convID
        latestPartial = ""
        isGenerating = true
        streamingText = ""
        MemoryStore.shared.cancel()
        let system = AppSettings.shared.systemPrompt(chat: true, query: t)
        genID += 1
        let myGen = genID
        genTask = Task {
            var full = ""
            do {
                slog.stage("chat:llm")
                slog("chat: gen start avail=\(RAM.availableMB)MB")
                let (prompt, images) = await Self.buildPrompt(t, attachments: attachments, earlier: earlier)
                let stream = try await LLMService.shared.stream(system: system, history: Array(history), user: prompt,
                                                                maxTokens: 1500, images: images)
                // تحديث الواجهة بحد أقصى ~30 مرة بالثانية بدل كل كلمة
                var lastUI = Date.distantPast
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    full += chunk
                    latestPartial = full
                    if Date().timeIntervalSince(lastUI) > 0.033 { streamingText = full; lastUI = Date() }
                }
                streamingText = full
            } catch {
                self.error = SawtError.friendly(error).localizedDescription
                if full.isEmpty {
                    // ما فيه رد: نشيل رسالتك ونرجعها لخانة الكتابة عشان ما تتكرر
                    if let i = conversations.firstIndex(where: { $0.id == convID }) {
                        conversations[i].messages.removeAll { $0.id == userMsg.id }
                        save()
                    }
                    onFail(t)
                }
            }
            let answer = full.trimmingCharacters(in: .whitespacesAndNewlines)
            // لو انضغط إيقاف، stop() حفظ الجزء بنفسه بالترتيب الصح
            if !answer.isEmpty, genID == myGen {
                // الرد يروح لنفس المحادثة حتى لو تنقّلت لغيرها، ومرة وحدة بس (حتى مع الإيقاف)
                let reply = Message(role: .assistant, text: answer)
                append(reply, to: convID)
                MemoryStore.shared.extractLater(exchanges: [(t, answer)]) { [weak self] in
                    self?.markMemorySaved(reply.id, in: convID)
                }
            }
            if genID == myGen {
                streamingText = ""
                isGenerating = false
            }
            slog.stage("idle")
            slog("chat: gen done \(full.count) chars")
        }
    }

    /// يجهّز نص الرسالة مع المرفقات: الملفات كنص (مقتطفات إذا طويلة)، والصور للنموذج إذا يشوف،
    /// وإلا وصف آلي من Apple Vision.
    static func buildPrompt(_ t: String, attachments: [Attachment], earlier: [Attachment] = []) async -> (String, [URL]) {
        var parts: [String] = []
        // ملفات من رسائل سابقة: نجيب المقاطع الأقرب للسؤال الجديد (بحد أصغر)
        if attachments.isEmpty, let f = earlier.last(where: { $0.kind == .file }) {
            let (ctx, _) = Attachments.context(for: f.fullText, query: t, budget: 2500, requireMatch: true)
            if !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("[مقاطع من الملف المرفق سابقًا: \(f.name)]\n\(ctx)\n[نهاية المقاطع]")
            }
        }
        guard !attachments.isEmpty else { return ((parts + [t]).joined(separator: "\n\n"), []) }
        var images: [URL] = []
        let files = attachments.filter { $0.kind == .file }
        let budget = files.isEmpty ? 0 : max(1500, 5000 / files.count)
        for f in files {
            let (ctx, cut) = Attachments.context(for: f.fullText, query: t, budget: budget)
            if ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("[ملف مرفق: \(f.name) — ما فيه نص مقروء]")
            } else {
                parts.append("[ملف مرفق: \(f.name)\(cut ? " — مقتطفات من ملف طويل" : "")]\n\(ctx)\n[نهاية الملف]")
            }
        }
        let imgs = attachments.filter { $0.kind == .image }
        if !imgs.isEmpty {
            let canSee = await ModelManager.shared.ensureVision()
            if canSee {
                images = Array(imgs.prefix(3).map { $0.imageURL })
            } else {
                for (i, a) in imgs.prefix(3).enumerated() {
                    let d = await Attachments.describe(a)
                    parts.append("[صورة \(i + 1) مرفقة. النموذج الحالي ما يشوف الصور، هذا وصف آلي لها:]\n\(d)")
                }
            }
        }
        parts.append(t)
        return (parts.joined(separator: "\n\n"), images)
    }

    func markMemorySaved(_ id: UUID, in conv: UUID?) {
        guard let ci = conversations.firstIndex(where: { $0.id == conv }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[ci].messages[mi].memorySaved = true
        save()
    }

    private var genID = 0
    private var genConv: UUID?

    /// يوقف التوليد؛ المهمة نفسها تحفظ الجزء اللي انكتب (عشان ما يتكرر الرد).
    private var latestPartial = ""

    /// يحفظ الملف فورًا (لما يروح التطبيق للخلفية).
    func flush() {
        saveTask?.cancel()
        SafeFile.write(conversations, to: fileURL)
    }

    func stop() {
        genTask?.cancel()
        genTask = nil
        if isGenerating {
            let partial = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { append(Message(role: .assistant, text: partial), to: genConv) }
        }
        latestPartial = ""
        genID += 1
        streamingText = ""
        isGenerating = false
    }

    func append(_ m: Message, to conv: UUID?) {
        guard let conv, let i = conversations.firstIndex(where: { $0.id == conv }) else { append(m); return }
        conversations[i].messages.append(m)
        conversations[i].updated = Date()
        save()
    }
}
