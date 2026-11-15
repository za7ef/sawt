import Foundation
import MLXLMCommon

/// نموذج سحابي للدردشة (اختياري): يتفعّل من صفحة النماذج ← «النماذج السحابية»
/// المفاتيح نفسها حقت الوكيل (سلسلة المفاتيح). النماذج المحلية تبقى الاحتياط.
enum CloudLLM {
    /// داخل مكالمة؟ (CallController يحطها) — السحابي في المكالمة بس لو فعّلته
    @TaskLocal static var inCall = false

    static var consent: Bool { UserDefaults.standard.bool(forKey: "cloudConsent") }
    static var useInCalls: Bool { UserDefaults.standard.bool(forKey: "cloudCalls") }

    /// المزوّد المفعّل للدردشة (لو له مفتاح وتمت الموافقة)
    static var active: CloudProvider? {
        guard let r = UserDefaults.standard.string(forKey: "cloudActive"), !r.isEmpty,
              let p = CloudProvider(rawValue: r), p.hasKey, consent else { return nil }
        return p
    }

    /// يُستخدم للرد الحين؟ (ما يمشي لو فيه إجبار للمعالج مثل اختبار المعالج)
    static func forThisReply(forcedDevice: String?) -> CloudProvider? {
        guard forcedDevice == nil, let p = active else { return nil }
        if inCall && !useInCalls { return nil }
        return p
    }

    static func setActive(_ p: CloudProvider?) {
        UserDefaults.standard.set(p?.rawValue ?? "", forKey: "cloudActive")
        slog("llm: cloud active → \(p?.rawValue ?? "off")")
    }

    private static func mime(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "png": "image/png"
        case "heic": "image/heic"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }

    /// تدفق الرد (SSE) من المزوّد
    static func stream(_ p: CloudProvider, system: String, history: [Chat.Message], user: String,
                       maxTokens: Int, images: [URL]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let req = try request(p, system: system, history: history, user: user, maxTokens: maxTokens, images: images)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 20_000 { break } }
                        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                        // جيميناي في البث يرجع الخطأ أحيانًا كمصفوفة
                        let j = json ?? ((try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]])?.first
                        throw CloudAgent.Failure(message: CloudAgent.errorText(p, code: code, json: j))
                    }
                    var any = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                        if let e = j["error"] as? [String: Any] {
                            throw CloudAgent.Failure(message: "\(p.short): \((e["message"] as? String ?? "خطأ").prefix(160))")
                        }
                        let piece = delta(p, j)
                        if !piece.isEmpty { any = true; cont.yield(piece) }
                    }
                    if !any && !Task.isCancelled { throw CloudAgent.Failure(message: "\(p.short) ما رجّع رد") }
                    cont.finish()
                } catch is CancellationError {
                    cont.finish()
                } catch let f as CloudAgent.Failure {
                    slog("llm: cloud error \(p.rawValue)")
                    cont.finish(throwing: f)
                } catch {
                    let ns = error as NSError
                    slog("llm: cloud net error \(p.rawValue) \(ns.code)")
                    if ns.code == NSURLErrorCancelled { cont.finish(); return }
                    let msg: String
                    switch ns.code {
                    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: msg = "ما فيه إنترنت — النموذج السحابي يحتاج اتصال"
                    case NSURLErrorTimedOut: msg = "\(p.short) ما رد بالوقت"
                    default: msg = "تعذّر الاتصال بـ\(p.short)"
                    }
                    cont.finish(throwing: CloudAgent.Failure(message: msg))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func delta(_ p: CloudProvider, _ j: [String: Any]) -> String {
        switch p {
        case .openai, .openrouter:
            let ch = (j["choices"] as? [[String: Any]])?.first
            return ((ch?["delta"] as? [String: Any])?["content"] as? String) ?? ""
        case .anthropic:
            guard (j["type"] as? String) == "content_block_delta", let d = j["delta"] as? [String: Any],
                  (d["type"] as? String) == "text_delta" else { return "" }
            return d["text"] as? String ?? ""
        case .gemini, .geminiPaid:
            let cand = (j["candidates"] as? [[String: Any]])?.first
            let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
    }

    private static func request(_ p: CloudProvider, system: String, history: [Chat.Message], user: String,
                                maxTokens: Int, images: [URL]) throws -> URLRequest {
        guard let key = p.key else { throw CloudAgent.Failure(message: "ما فيه مفتاح لـ\(p.short) — حطه في صفحة النماذج ← السحابية") }
        // السجل: مستخدم/مساعد بالتناوب
        let hist = LLMService.strictAlternation(history + [.user(user)])
        let imgs: [(String, String)] = images.compactMap { u in
            guard let d = try? Data(contentsOf: u), d.count < 8_000_000 else { return nil }
            return (mime(u), d.base64EncodedString())
        }
        let tokens = max(maxTokens, 1024)   // النماذج السحابية تفكر داخليًا وتحتاج مساحة
        var req: URLRequest
        var body: [String: Any]
        switch p {
        case .openai, .openrouter:
            let or = p == .openrouter
            req = URLRequest(url: URL(string: or ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if or { req.setValue("Sawt", forHTTPHeaderField: "X-Title") }
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            for m in hist { msgs.append(["role": m.role == .assistant ? "assistant" : "user", "content": m.content]) }
            var content: [[String: Any]] = [["type": "text", "text": user]]
            for (mt, b) in imgs { content.append(["type": "image_url", "image_url": ["url": "data:\(mt);base64,\(b)"]]) }
            msgs.append(["role": "user", "content": content])
            body = ["model": p.model, "messages": msgs, "stream": true]
            body[or ? "max_tokens" : "max_completion_tokens"] = or ? tokens : tokens * 3
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var msgs: [[String: Any]] = hist.map { ["role": $0.role == .assistant ? "assistant" : "user", "content": $0.content] }
            var content: [[String: Any]] = imgs.map { ["type": "image", "source": ["type": "base64", "media_type": $0.0, "data": $0.1]] }
            content.append(["type": "text", "text": user])
            msgs.append(["role": "user", "content": content])
            body = ["model": p.model, "max_tokens": tokens * 2, "system": system, "messages": msgs, "stream": true]
        case .gemini, .geminiPaid:
            let m = p.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):streamGenerateContent?alt=sse")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var contents: [[String: Any]] = hist.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] }
            var parts: [[String: Any]] = [["text": user]]
            for (mt, b) in imgs { parts.append(["inlineData": ["mimeType": mt, "data": b]]) }
            contents.append(["role": "user", "parts": parts])
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": contents,
                    "generationConfig": ["maxOutputTokens": tokens * 4]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}
