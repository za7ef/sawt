import CoreML
import Foundation
import WhisperKit

/// تحويل الكلام إلى نص على الجهاز عن طريق WhisperKit.
actor SpeechRecognizer {
    static let shared = SpeechRecognizer()

    private var pipe: WhisperKit?
    private var loadedID: String?

    var isReady: Bool { pipe != nil }

    /// progress(نسبة التنزيل، هل بدأ التجهيز)
    func load(variant: String, progress: @escaping @Sendable (Double, Bool) -> Void) async throws {
        if loadedID == variant, pipe != nil { return }
        pipe = nil
        let folder = try await WhisperKit.download(variant: variant) { p in
            progress(min(p.fractionCompleted, 0.99), false)
        }
        progress(1, true)
        // المُرمّز الصوتي على كرت الشاشة: تحميله أسرع بكثير من المعالج العصبي اللي يحتاج تجميع طويل أول مرة.
        let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine)
        let cfg = WhisperKitConfig(model: variant, modelFolder: folder.path, computeOptions: compute, verbose: false,
                                   prewarm: false, load: true, download: false)
        pipe = try await WhisperKit(cfg)
        loadedID = variant
    }

    /// يرجع النص واللغة المكتشفة.
    func transcribe(_ audio: [Float], language: String?) async throws -> (text: String, language: String) {
        guard let pipe else { throw SawtError.notReady("نموذج السمع") }
        // ويسبر يحتاج على الأقل ثانية تقريبًا
        var samples = audio
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
        var opts = DecodingOptions(
            task: .transcribe, language: language, temperature: 0,
            temperatureFallbackCount: 2, usePrefillPrompt: language != nil,
            detectLanguage: language == nil, skipSpecialTokens: true,
            withoutTimestamps: true, suppressBlank: true,
            noSpeechThreshold: 0.6)
        opts.chunkingStrategy = ChunkingStrategy.none
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
        let text = results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^\\)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = results.first?.language ?? (language ?? "ar")
        return (Self.filterHallucination(text), lang)
    }

    /// ويسبر أحيانًا يتخيل جمل مشهورة على الصمت.
    private static func filterHallucination(_ t: String) -> String {
        let junk = ["اشتركوا في القناة", "ترجمة نانسي قنقر", "شكرا للمشاهدة", "شكراً للمشاهدة",
                    "Thank you for watching", "Thanks for watching", "Subtitles by", "موسيقى"]
        for j in junk where t.localizedCaseInsensitiveContains(j) && t.count < j.count + 12 { return "" }
        return t
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
