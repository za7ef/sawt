import Foundation

/// تحويل الكلام إلى نص عن طريق سمع آبل (التعرّف على الكلام في iOS). ما فيه نماذج تنزل.
actor SpeechRecognizer {
    static let shared = SpeechRecognizer()

    private var ready = false

    var isReady: Bool { ready }

    func unload() { ready = false }

    func load() async throws {
        if ready { return }
        guard await AppleSTT.authorize() else {
            throw SawtError.failed("اسمح لتطبيق صوت بالتعرّف على الكلام من الإعدادات.")
        }
        ready = true
        slog("stt apple ready, onDevice=\(AppleSTT.supportsOnDevice)")
    }

    /// يرجع النص واللغة المكتشفة.
    func transcribe(_ audio: [Float], language: String?) async throws -> (text: String, language: String) {
        guard ready else { throw SawtError.notReady("سمع آبل") }
        return try await AppleSTT.transcribe(audio, language: language)
    }
}

enum SawtError: LocalizedError {
    case notReady(String)
    case failed(String)
    case timeout(String)
    var errorDescription: String? {
        switch self {
        case .notReady(let w): return "\(w) مو جاهز. نزّله من شاشة النماذج."
        case .failed(let m): return m
        case .timeout(let w): return "\(w) طوّل بزيادة وما اشتغل. جرّب مرة ثانية أو اختر نموذج أصغر."
        }
    }

    /// يحوّل أخطاء المكتبات لرسالة مفهومة.
    static func friendly(_ error: Error?) -> SawtError {
        guard let error else { return .failed("صار خطأ غير معروف.") }
        if let e = error as? SawtError { return e }
        if let c = error as? CloudAgent.Failure { return .failed(c.message) }
        let d = String(describing: error)
        if d.contains("Template") || d.contains("Jinja") {
            return .failed("هذا النموذج ما يتوافق مع طريقة المحادثة في التطبيق. جرّب Qwen3 4B.")
        }
        if d.lowercased().contains("memory") {
            return .failed("الذاكرة ما تكفي لهذا النموذج. اختر نموذج أصغر.")
        }
        return .failed("ما قدر النموذج يرد. (\(error.localizedDescription))")
    }
}
