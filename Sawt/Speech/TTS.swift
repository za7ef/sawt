import AVFoundation
import Foundation
import SherpaOnnx

/// محرّك تحويل النص لصوت على الجهاز.
final class SpeechSynth {
    static let shared = SpeechSynth()

    private let queue = DispatchQueue(label: "sawt.tts", qos: .userInitiated)
    private var sherpa: SherpaOnnxOfflineTtsWrapper?
    private var loadedVoice: String?
    private let apple = AppleSynth()

    /// يجهّز الصوت المختار (يحمّل النموذج في الذاكرة).
    func prepare(_ voice: VoiceOption) {
        queue.sync { self.load(voice) }
        // أول استخدام لصوت آبل داخل جلسة المكالمة أحيانًا يعلّق (timeout 10ث) فيضيع أول رد:
        // نسخّنه بجملة قصيرة ما تنسمع، لأنه يُستخدم للإنجليزي وكاحتياط لكل الأصوات
        Task.detached(priority: .utility) {
            let t0 = Date()
            let r = await self.apple.synthesize("هلا", language: "ar-SA", rate: 1.0)
            slog("tts: apple warmup \(Int(Date().timeIntervalSince(t0) * 1000))ms samples=\(r.samples.count)")
        }
    }

    /// احتياط عربي لما يفشل نماء: نبرة (سعودية ثم فصحى) إذا موجودة، وإلا آبل.
    private func arabicFallback(_ clean: String, rate: Double) async -> (samples: [Float], rate: Double) {
        if let v = Catalog.voices.first(where: { $0.id == "nabra-saudi" }) ?? Catalog.voices.first(where: { $0.id == "nabra-msa" }) {
            let r: (samples: [Float], rate: Double) = await withCheckedContinuation { cont in
                queue.async {
                    guard let tts = self.fallbackSherpa(v) else { cont.resume(returning: ([], 24_000)); return }
                    let a = tts.generate(text: clean, sid: 0, speed: Float(rate))
                    cont.resume(returning: (a.samples, Double(a.sampleRate)))
                }
            }
            if !r.samples.isEmpty { return r }
        }
        return await apple.synthesize(clean, language: "ar-SA", rate: rate)
    }

    private var fallback: SherpaOnnxOfflineTtsWrapper?
    private var fallbackID: String?
    /// صوت نبرة احتياطي (على خيط الصوت)، منفصل عن الصوت المختار.
    private func fallbackSherpa(_ v: VoiceOption) -> SherpaOnnxOfflineTtsWrapper? {
        if fallbackID == v.id, let f = fallback { return f }
        guard let root = Catalog.voicesRoot, case .kokoro(let model) = v.kind else { return nil }
        let dir = Catalog.voiceDir(v.folder)
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: dir.appendingPathComponent(model).path,
            voices: dir.appendingPathComponent("voices.bin").path,
            tokens: dir.appendingPathComponent("tokens.txt").path,
            dataDir: root.appendingPathComponent("espeak-ng-data").path)
        var cfg = sherpaOnnxOfflineTtsConfig(model: sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2),
                                             maxNumSentences: 1, silenceScale: 0.2)
        fallback = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        fallbackID = v.id
        slog("tts: fallback voice loaded \(v.id)")
        return fallback
    }

    func unload() {
        queue.async { self.sherpa = nil; self.loadedVoice = nil; self.fallback = nil; self.fallbackID = nil }
        NamaaEngine.shared.unload()
    }

    private func load(_ voice: VoiceOption) {
        if loadedVoice == voice.id { return }
        sherpa = nil
        loadedVoice = voice.id
        guard let root = Catalog.voicesRoot else { return }
        let dir = Catalog.voiceDir(voice.folder)
        let espeak = root.appendingPathComponent("espeak-ng-data").path
        // خيطين بس عشان ما يسخن الجوال ويخلي المعالج للنموذج اللغوي
        let threads = ThermalWatch.isHot ? 1 : 2
        slog("tts load \(voice.id) threads=\(threads)")
        switch voice.kind {
        case .apple:
            return
        case .namaa:
            // نحمّله مع تجهيز المكالمة بدل أول جملة
            NamaaEngine.shared.preload()
            return
        case .piper(let onnx):
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: dir.appendingPathComponent(onnx).path,
                tokens: dir.appendingPathComponent("tokens.txt").path,
                dataDir: espeak, noiseScale: 0.6, noiseScaleW: 0.8, lengthScale: 1.0)
            var cfg = sherpaOnnxOfflineTtsConfig(model: sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: threads),
                                                 maxNumSentences: 1, silenceScale: 0.2)
            sherpa = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        case .kokoro(let model):
            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: dir.appendingPathComponent(model).path,
                voices: dir.appendingPathComponent("voices.bin").path,
                tokens: dir.appendingPathComponent("tokens.txt").path,
                dataDir: espeak)
            var cfg = sherpaOnnxOfflineTtsConfig(model: sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads),
                                                 maxNumSentences: 1, silenceScale: 0.2)
            sherpa = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        }
        slog("tts loaded \(voice.id)")
    }

    /// يحوّل جملة لصوت. يُستدعى من أي خيط ويرجع على خيط خلفي.
    func synthesize(_ text: String, voice: VoiceOption, rate: Double) async -> (samples: [Float], rate: Double) {
        let clean = TextCleaner.forSpeech(text)
        guard !clean.isEmpty else { return ([], 24_000) }
        let arabic = TextCleaner.hasArabic(clean)
        // الأصوات العربية ما تقرأ الإنجليزي زين، فالجمل الإنجليزية تروح لصوت آبل.
        if voice.kind == .apple || !arabic {
            return await apple.synthesize(clean, language: arabic ? "ar-SA" : "en-US", rate: rate)
        }
        if voice.kind == .namaa {
            // إذا الجملة طويلة ونماء بيتأخر فيها كثير، نقولها بنبرة بدل سكتة طويلة
            if CallController.isActive, NamaaEngine.shared.estimatedSeconds(clean) > 8 {
                slog("tts: namaa too slow for \(clean.count) chars → fallback voice")
                return await arabicFallback(clean, rate: rate)
            }
            let s = await NamaaEngine.shared.synthesize(clean, speed: rate)
            if s.isEmpty {
                slog("tts: namaa gave nothing → fallback voice")
                return await arabicFallback(clean, rate: rate)
            }
            return (s, 24_000)
        }
        return await withCheckedContinuation { cont in
            queue.async {
                self.load(voice)
                guard let tts = self.sherpa else {
                    cont.resume(returning: ([], 24_000)); return
                }
                let audio = tts.generate(text: clean, sid: 0, speed: Float(rate))
                cont.resume(returning: (audio.samples, Double(audio.sampleRate)))
            }
        }
    }
}

/// أصوات النظام عن طريق AVSpeechSynthesizer.write عشان تمر على نفس محرك الصوت (وإلغاء الصدى).
final class AppleSynth: NSObject {
    private let synth = AVSpeechSynthesizer()

    static func bestVoice(_ language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let exact = all.filter { $0.language == language }
        let pool = exact.isEmpty ? all : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    func synthesize(_ text: String, language: String, rate: Double) async -> (samples: [Float], rate: Double) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = Self.bestVoice(language)
        utt.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * min(max(rate, 0.6), 1.6))
        utt.prefersAssistiveTechnologySettings = false
        return await withCheckedContinuation { cont in
            var samples: [Float] = []
            var sr: Double = 22_050
            var done = false
            let lock = NSLock()
            // إذا ما رجع النظام خلال 10 ثواني نكمل بدون الجملة بدل ما يعلق
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; slog("apple tts timeout"); cont.resume(returning: (samples, sr)) }
            }
            var lastBuffer = 0
            synth.write(utt) { buffer in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                // في iOS 27 أحيانًا ما يوصل البفر الفاضي اللي يعلن النهاية، فكنا ننتظر 10 ثواني:
                // إذا وقفت البفرات 0.4 ثانية نعتبرها خلصت
                lastBuffer += 1
                let mine = lastBuffer
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    lock.lock(); defer { lock.unlock() }
                    if !done, mine == lastBuffer, !samples.isEmpty {
                        done = true; cont.resume(returning: (samples, sr))
                    }
                }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    cont.resume(returning: (samples, sr))
                    return
                }
                sr = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData {
                    samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
                } else if let i = pcm.int16ChannelData {
                    let p = UnsafeBufferPointer(start: i[0], count: n)
                    samples.append(contentsOf: p.map { Float($0) / 32768 })
                } else if let i = pcm.int32ChannelData {
                    let p = UnsafeBufferPointer(start: i[0], count: n)
                    samples.append(contentsOf: p.map { Float($0) / 2_147_483_648 })
                }
            }
        }
    }
}

