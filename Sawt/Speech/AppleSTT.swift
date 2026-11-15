import AVFoundation
import Speech

/// تمييز الكلام من آبل على الجهاز. خفيف جدًا على الذاكرة وما يحتاج تنزيل.
enum AppleSTT {
    static func authorize() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    static func recognizer(_ language: String?) -> SFSpeechRecognizer? {
        let id = language == "en" ? "en-US" : "ar-SA"
        return SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    /// المستخدم سمح بإرسال الصوت لآبل إذا الجهاز ما يدعم اللغة محليًا (مقفل افتراضيًا).
    static var serverAllowed: Bool { UserDefaults.standard.bool(forKey: "allowAppleServerSTT") }

    /// رسالة إذا سمع آبل مختار بس ما يقدر يشتغل على الجهاز وما فيه إذن للإنترنت.
    static var blockedReason: String? {
        guard AppSettings.shared.sttID == "apple", !supportsOnDevice, !serverAllowed else { return nil }
        return "جوالك ما يدعم سمع آبل للعربي على الجهاز. من الإعدادات اسمح له يستخدم الإنترنت، أو نزّل Whisper من شاشة النماذج."
    }

    static var supportsOnDevice: Bool { recognizer("ar")?.supportsOnDeviceRecognition ?? false }

    /// يحوّل مقطع صوت 16 كيلوهرتز لنص.
    static func transcribe(_ samples: [Float], language: String?) async throws -> (text: String, language: String) {
        guard let rec = recognizer(language), rec.isAvailable else {
            throw SawtError.failed("تمييز الكلام من آبل مو متاح على جهازك. اختر Whisper من شاشة النماذج.")
        }
        guard rec.supportsOnDeviceRecognition || AppleSTT.serverAllowed else {
            throw SawtError.failed("سمع آبل يحتاج يرسل صوتك لآبل على هالجوال. اسمح له من الإعدادات أو اختر Whisper.")
        }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return ("", language ?? "ar")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.taskHint = .dictation
        req.addsPunctuation = true
        req.append(buf)
        req.endAudio()

        let text: String = try await withCheckedThrowingContinuation { cont in
            // مرة وحدة بس (الرد أو المهلة)، بقفل لأن الاستدعاءات تجي من طوابير مختلفة
            let once = OnceFlag()
            let task = rec.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    if once.take() { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    guard once.take() else { return }
                    // "No speech detected" يعتبر نص فاضي مو خطأ
                    let ns = error as NSError
                    if ns.code == 1110 || ns.code == 203 { cont.resume(returning: "") } else { cont.resume(throwing: error) }
                }
            }
            // مهلة: آبل أحيانًا ما يرجع أبد
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                guard once.take() else { return }
                task.cancel()
                cont.resume(throwing: SawtError.failed("سمع آبل ما رد خلال ٣٠ ثانية."))
            }
        }
        return (text, language ?? "ar")
    }
}

/// علم يُؤخذ مرة وحدة (آمن بين الطوابير)
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// تمييز آبل بالبث: نعطيه الصوت أول بأول وهو يتكلم، فلما يسكت يكون النص شبه جاهز.
final class AppleStream: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var resolved = false
    private var waiter: CheckedContinuation<String, Never>?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    var onPartial: ((String) -> Void)?

    var partial: String { lock.lock(); defer { lock.unlock() }; return latest }

    func start(language: String?) -> Bool {
        guard let rec = AppleSTT.recognizer(language), rec.isAvailable else { return false }
        guard rec.supportsOnDeviceRecognition || AppleSTT.serverAllowed else {
            slog("apple stt: on-device unsupported and server not allowed")
            return false
        }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        r.taskHint = .dictation
        r.addsPunctuation = true
        req = r
        task = rec.recognitionTask(with: r) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock(); self.latest = text; self.lock.unlock()
                self.onPartial?(text)
                if result.isFinal { self.resolve() }
            } else if error != nil {
                self.resolve()
            }
        }
        return true
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty, let fmt,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            if let base = p.baseAddress { ch[0].update(from: base, count: samples.count) }
        }
        req?.append(buf)
    }

    /// ينهي الصوت ويرجع النص النهائي (أو آخر نص جزئي إذا تأخر).
    func finish(timeout: Double = 1.2) async -> String {
        req?.endAudio()
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            lock.lock()
            if resolved { let t = latest; lock.unlock(); c.resume(returning: t); return }
            waiter = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve()
            }
        }
    }

    func cancel() {
        task?.cancel()
        resolve()
    }

    private func resolve() {
        lock.lock()
        resolved = true
        let w = waiter
        waiter = nil
        let t = latest
        lock.unlock()
        w?.resume(returning: t)
    }
}
