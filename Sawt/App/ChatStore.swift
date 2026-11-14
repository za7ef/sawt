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
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Conversation].self, from: data) {
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
        let voiceMsgs = turns.map { Message(role: $0.role == .user ? .user : .assistant, text: $0.text, viaVoice: true) }
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
        return msgs.map { Turn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
    }

    private var saveTask: Task<Void, Never>?

    /// حفظ مؤجّل (نص ثانية) وخارج الخيط الرئيسي، عشان ما نكتب الملف كل شوي.
    func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            let list = conversations
            let url = fileURL
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(list) {
                    try? data.write(to: url, options: [.atomic, .completeFileProtection])
                }
            }.value
        }
    }

    // MARK: الدردشة الكتابية

    func send(_ text: String, attachments: [Attachment] = [], onFail: @escaping (String) -> Void = { _ in }) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty, !isGenerating else { return }
        if t.isEmpty { t = attachments.contains { $0.kind == .image } ? "وش تشوف في الصورة؟" : "لخّص لي الملف باختصار." }
        let history = (current?.messages ?? []).suffix(20).map { m -> Chat.Message in
            let names = (m.attachments ?? []).map { "[مرفق: \($0.name)]" }.joined(separator: " ")
            let body = names.isEmpty ? m.text : names + "\n" + m.text
            return m.role == .user ? Chat.Message.user(body) : Chat.Message.assistant(m.text)
        }
        var userMsg = Message(role: .user, text: t)
        if !attachments.isEmpty { userMsg.attachments = attachments }
        append(userMsg)
        isGenerating = true
        streamingText = ""
        MemoryStore.shared.cancel()
        let system = AppSettings.shared.systemPrompt(chat: true, query: t)
        genTask = Task {
            var full = ""
            do {
                slog.stage("chat:llm")
                slog("chat: gen start avail=\(RAM.availableMB)MB")
                let (prompt, images) = await Self.buildPrompt(t, attachments: attachments)
                let stream = try await LLMService.shared.stream(system: system, history: Array(history), user: prompt,
                                                                maxTokens: 1500, images: images)
                // تحديث الواجهة بحد أقصى ~30 مرة بالثانية بدل كل كلمة
                var lastUI = Date.distantPast
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    full += chunk
                    if Date().timeIntervalSince(lastUI) > 0.033 { streamingText = full; lastUI = Date() }
                }
                streamingText = full
            } catch {
                self.error = SawtError.friendly(error).localizedDescription
                if full.isEmpty {
                    // ما فيه رد: نشيل رسالتك ونرجعها لخانة الكتابة عشان ما تتكرر
                    if let i = conversations.firstIndex(where: { $0.id == currentID }) {
                        conversations[i].messages.removeAll { $0.id == userMsg.id }
                        save()
                    }
                    onFail(t)
                }
            }
            let answer = full.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                let reply = Message(role: .assistant, text: answer)
                append(reply)
                let convID = currentID
                MemoryStore.shared.extractLater(exchanges: [(t, answer)]) { [weak self] in
                    self?.markMemorySaved(reply.id, in: convID)
                }
            }
            streamingText = ""
            isGenerating = false
            slog.stage("idle")
            slog("chat: gen done \(full.count) chars")
        }
    }

    /// يجهّز نص الرسالة مع المرفقات: الملفات كنص (مقتطفات إذا طويلة)، والصور للنموذج إذا يشوف،
    /// وإلا وصف آلي من Apple Vision.
    static func buildPrompt(_ t: String, attachments: [Attachment]) async -> (String, [URL]) {
        guard !attachments.isEmpty else { return (t, []) }
        var parts: [String] = []
        var images: [URL] = []
        let files = attachments.filter { $0.kind == .file }
        let budget = files.isEmpty ? 0 : max(1500, 5000 / files.count)
        for f in files {
            let (ctx, cut) = Attachments.context(for: f.text ?? "", query: t, budget: budget)
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

    func stop() {
        genTask?.cancel()
        genTask = nil
        if isGenerating {
            let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { append(Message(role: .assistant, text: partial)) }
        }
        streamingText = ""
        isGenerating = false
    }
}
