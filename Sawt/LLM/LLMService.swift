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
    func stream(system: String, history: [Chat.Message], user: String) throws -> AsyncThrowingStream<String, Error> {
        guard let container else { throw SawtError.notReady("النموذج اللغوي") }
        var params = GenerateParameters()
        params.maxTokens = 400
        params.temperature = 0.7
        params.topP = 0.9
        let sys = (loadedID ?? "").contains("Qwen") ? system + "\n/no_think" : system
        let session = ChatSession(container, instructions: sys, history: history, generateParameters: params,
                                  additionalContext: ["enable_thinking": false])
        let upstream = session.streamResponse(to: user)
        return AsyncThrowingStream { cont in
            let task = Task {
                let keepAlive = session
                var inThink = false
                var pendingTag = ""
                do {
                    for try await chunk in upstream {
                        if Task.isCancelled { break }
                        // نشيل أي تفكير داخلي <think>...</think>
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
                        if !visible.isEmpty { cont.yield(visible) }
                    }
                    if !pendingTag.isEmpty, !inThink { cont.yield(pendingTag) }
                    withExtendedLifetime(keepAlive) {}
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
