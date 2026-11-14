import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// النموذج اللغوي المحلي (MLX).
actor LLMService {
    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedID: String?

    var isReady: Bool { container != nil }

    func unload() { container = nil; loadedID = nil }

    func load(_ option: LLMOption, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedID == option.id, container != nil { return }
        container = nil
        let cfg = option.configuration
        let c = try await #huggingFaceLoadModelContainer(configuration: cfg, progressHandler: { p in
            progress(p.fractionCompleted)
        })
        container = c
        loadedID = option.id
        progress(1)
    }

    /// يرجع تدفق نص الرد. السجل يحتوي الرسائل السابقة بدون الرسالة الحالية.
    /// إذا رفض قالب المحادثة (بعض النماذج ما تقبل رسالة النظام)، نعيد المحاولة بدمج التعليمات في رسالة المستخدم.
    func stream(system: String, history: [Chat.Message], user: String) throws -> AsyncThrowingStream<String, Error> {
        guard let container else { throw SawtError.notReady("النموذج اللغوي") }
        var params = GenerateParameters()
        params.maxTokens = 400
        params.temperature = 0.7
        params.topP = 0.9
        let isQwen = (loadedID ?? "").lowercased().contains("qwen")
        let sys = isQwen ? system + "\n/no_think" : system

        // المحاولة الأولى: رسالة نظام عادية. الثانية: بدون رسالة نظام وبتناوب صارم.
        let attempts: [() -> (ChatSession, String)] = [
            {
                (ChatSession(container, instructions: sys, history: history, generateParameters: params,
                             additionalContext: isQwen ? ["enable_thinking": false] : nil), user)
            },
            {
                let merged = Self.strictAlternation(history)
                let first = merged.isEmpty
                    ? "تعليمات: \(sys)\n\n\(user)"
                    : user
                var hist = merged
                if !hist.isEmpty, case .user = hist[0].role {
                    hist[0] = .user("تعليمات: \(sys)\n\n" + hist[0].content)
                }
                return (ChatSession(container, instructions: nil, history: hist, generateParameters: params), first)
            },
        ]

        return AsyncThrowingStream { cont in
            let task = Task {
                var lastError: Error?
                for (i, make) in attempts.enumerated() {
                    let (session, prompt) = make()
                    var yielded = false
                    var inThink = false
                    var pendingTag = ""
                    do {
                        for try await chunk in session.streamResponse(to: prompt) {
                            if Task.isCancelled { break }
                            var text = pendingTag + chunk
                            pendingTag = ""
                            var visible = ""
                            while !text.isEmpty {
                                if inThink {
                                    if let r = text.range(of: "</think>") {
                                        text = String(text[r.upperBound...]); inThink = false
                                    } else { text = ""; break }
                                } else if let r = text.range(of: "<think>") {
                                    visible += text[..<r.lowerBound]
                                    text = String(text[r.upperBound...]); inThink = true
                                } else if let lt = text.lastIndex(of: "<"), text[lt...].count < 8 {
                                    visible += text[..<lt]; pendingTag = String(text[lt...]); text = ""
                                } else {
                                    visible += text; text = ""
                                }
                            }
                            if !visible.isEmpty { yielded = true; cont.yield(visible) }
                        }
                        if !pendingTag.isEmpty, !inThink { cont.yield(pendingTag) }
                        withExtendedLifetime(session) {}
                        cont.finish()
                        return
                    } catch {
                        lastError = error
                        if yielded || Task.isCancelled || i == attempts.count - 1 { break }
                    }
                }
                cont.finish(throwing: SawtError.friendly(lastError))
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// يدمج الرسائل المتتالية من نفس الطرف ويبدأ بالمستخدم.
    static func strictAlternation(_ msgs: [Chat.Message]) -> [Chat.Message] {
        var out: [Chat.Message] = []
        for m in msgs {
            switch m.role {
            case .user, .assistant:
                if let last = out.last, last.role == m.role {
                    out[out.count - 1] = last.role == .user ? .user(last.content + "\n" + m.content)
                                                           : .assistant(last.content + "\n" + m.content)
                } else {
                    out.append(m)
                }
            default: continue
            }
        }
        if let f = out.first, f.role == .assistant { out.removeFirst() }
        if let l = out.last, l.role == .user { out.removeLast() }
        return out
    }
}
