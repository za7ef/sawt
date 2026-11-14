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
    }

    func unload() {
        queue.async { self.sherpa = nil; self.loadedVoice = nil }
    }

    private func load(_ voice: VoiceOption) {
        if loadedVoice == voice.id { return }
        sherpa = nil
        loadedVoice = voice.id
        guard let root = Catalog.voicesRoot else { return }
        let dir = root.appendingPathComponent(voice.folder)
        let espeak = root.appendingPathComponent("espeak-ng-data").path
        // خيطين بس عشان ما يسخن الجوال ويخلي المعالج للنموذج اللغوي
        let threads = ThermalWatch.isHot ? 1 : 2
        slog("tts load \(voice.id) threads=\(threads)")
        switch voice.kind {
        case .apple:
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
            synth.write(utt) { buffer in
                guard !done else { return }
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

enum TextCleaner {
    static func hasArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
    }

    /// يشيل التنسيق والرموز اللي ما تنقال.
    static func forSpeech(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#`>|~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        t = String(t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)) })
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// يفصل النص المتدفق لجمل جاهزة للنطق. يرجع (جمل كاملة، الباقي).
    static func splitSentences(_ buffer: String, first: Bool) -> ([String], String) {
        var out: [String] = []
        var current = ""
        let enders: Set<Character> = [".", "!", "?", "؟", "؛", "\n", "…"]
        let soft: Set<Character> = ["،", ",", ":"]
        for ch in buffer {
            current.append(ch)
            let words = current.split(separator: " ").count
            if enders.contains(ch), current.trimmingCharacters(in: .whitespaces).count > 1 {
                out.append(current); current = ""
            } else if soft.contains(ch), words >= ((first && out.isEmpty) ? 3 : 8) {
                // أول جملة نقطعها بدري عشان يبدأ يتكلم بسرعة
                out.append(current); current = ""
            }
        }
        return (out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, current)
    }
}
