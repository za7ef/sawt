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

    func save() {
        let list = conversations
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: الدردشة الكتابية

    func send(_ text: String, onFail: @escaping (String) -> Void = { _ in }) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isGenerating else { return }
        let history = (current?.messages ?? []).suffix(20).map {
            $0.role == .user ? Chat.Message.user($0.text) : Chat.Message.assistant($0.text)
        }
        let userMsg = Message(role: .user, text: t)
        append(userMsg)
        isGenerating = true
        streamingText = ""
        let system = AppSettings.shared.persona.replacingOccurrences(
            of: "تتكلم معه في مكالمة صوتية مباشرة.", with: "تكلمه في دردشة كتابية.")
        genTask = Task {
            var full = ""
            do {
                let stream = try await LLMService.shared.stream(system: system, history: Array(history), user: t, maxTokens: 1500)
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    full += chunk
                    streamingText = full
                }
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
            if !answer.isEmpty { append(Message(role: .assistant, text: answer)) }
            streamingText = ""
            isGenerating = false
        }
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
