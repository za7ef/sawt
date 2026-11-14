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

    static var supportsOnDevice: Bool { recognizer("ar")?.supportsOnDeviceRecognition ?? false }

    /// يحوّل مقطع صوت 16 كيلوهرتز لنص.
    static func transcribe(_ samples: [Float], language: String?) async throws -> (text: String, language: String) {
        guard let rec = recognizer(language), rec.isAvailable else {
            throw SawtError.failed("تمييز الكلام من آبل مو متاح على جهازك. اختر Whisper من شاشة النماذج.")
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
            var done = false
            let task = rec.recognitionTask(with: req) { result, error in
                if done { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    done = true
                    // "No speech detected" يعتبر نص فاضي مو خطأ
                    let ns = error as NSError
                    if ns.code == 1110 || ns.code == 203 { cont.resume(returning: "") } else { cont.resume(throwing: error) }
                }
            }
            _ = task
        }
        return (text, language ?? "ar")
    }
}
