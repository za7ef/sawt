import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// النموذج اللغوي المحلي (MLX).
actor LLMService {
    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedID: String?
    /// جلسة المكالمة: نحتفظ فيها بين الأدوار عشان ما نعيد معالجة التعليمات والمحادثة كل مرة (كاش KV).
    private var callSession: ChatSession?

    func resetCallSession() { callSession = nil }
    private func keepCallSession(_ s: ChatSession?) { callSession = s }

    var isReady: Bool { container != nil }

    func unload() {
        container = nil
        loadedID = nil
        warmedID = nil
        callSession = nil
        MLX.Memory.clearCache()
    }

    private var warmedID: String?

    /// تسخين: نولّد كلمة وحدة عشان أول رد في المكالمة يكون أسرع (تجهيز كرت الشاشة والكاش).
    func warmup(system: String) async {
        guard let id = loadedID, warmedID != id else { return }
        warmedID = id
        let t0 = Date()
        do {
            let s = try stream(system: system, history: [], user: "هلا", maxTokens: 1)
            for try await _ in s {}
            slog("llm: warmup \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch {
            slog("llm: warmup failed \(error)")
        }
    }

    /// يُستدعى لما النظام يحذّر من الذاكرة.
    func trim() { MLX.Memory.clearCache() }

    func load(_ option: LLMOption, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedID == option.id, container != nil { return }
        container = nil
        MLX.Memory.clearCache()
        // كاش صغير لكرت الشاشة عشان ما تتكدس الذاكرة بين الردود
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        slog("llm: loading \(option.id)")
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
    func stream(system: String, history: [Chat.Message], user: String, maxTokens: Int = 400, reuse: Bool = false) throws -> AsyncThrowingStream<String, Error> {
        guard let container else { throw SawtError.notReady("النموذج اللغوي") }
        var params = GenerateParameters()
        params.maxTokens = ThermalWatch.isHot ? min(200, maxTokens) : maxTokens
        params.maxKVSize = 4096
        params.temperature = 0.7
        params.topP = 0.9
        // وضع التفكير موجود بس في عائلة Qwen3 (ومنها Qwen3.5)، مو Qwen2.5
        let isQwen3 = (loadedID ?? "").lowercased().contains("qwen3")
        let sys = isQwen3 ? system + "\n/no_think" : system
        let ctx: [String: any Sendable]? = isQwen3 ? ["enable_thinking": false] : nil

        // المحاولة الأولى: رسالة نظام عادية. الثانية: بدون رسالة نظام وبتناوب صارم.
        var attempts: [() -> (ChatSession, String)] = [
            {
                (ChatSession(container, instructions: sys, history: history, generateParameters: params,
                             additionalContext: ctx), user)
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
                return (ChatSession(container, instructions: nil, history: hist, generateParameters: params,
                                    additionalContext: ctx), first)
            },
        ]

        if reuse, let existing = callSession {
            existing.generateParameters = params
            attempts.insert({ (existing, user) }, at: 0)
            slog("llm: reusing call session (kv cache)")
        }
        callSession = nil   // ترجع بس إذا خلص الدور بنجاح

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
                        // نحتفظ بالجلسة بس إذا الرد كمل (لو انقطع، كاشها مو مضمون)
                        if reuse, !Task.isCancelled { self.keepCallSession(session) }
                        MLX.Memory.clearCache()
                        cont.finish()
                        return
                    } catch {
                        lastError = error
                        if yielded || Task.isCancelled || i == attempts.count - 1 { break }
                    }
                }
                MLX.Memory.clearCache()
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
