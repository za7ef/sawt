import AVFoundation
import Foundation
import SwiftUI

/// إملاء صوتي لخانة الكتابة: يسجّل لين تضغط إيقاف، بعدين يحوّل لنص.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var error: String?
    private var buffer: [Float] = []
    private let lock = NSLock()

    func start() {
        guard !isRecording else { return }
        if let why = AppleSTT.blockedReason { error = why; return }
        Speaker.shared.stop()
        if AudioIO.shared.isRunning {
            if AudioIO.shared.ownedByCall { error = "المايك مشغول بالمكالمة."; return }
            Speaker.shared.stop()
        }
        Task {
            guard await AVAudioApplicationShim.requestRecord() else {
                error = "اسمح للتطبيق يستخدم المايك من الإعدادات."
                return
            }
            lock.lock(); buffer.removeAll(); lock.unlock()
            AudioIO.shared.onMic = { [weak self] s in
                guard let self else { return }
                // حد أقصى دقيقتين (16 ألف عينة بالثانية) عشان الذاكرة ووقت التحويل
                self.lock.lock()
                if self.buffer.count < 16_000 * 120 { self.buffer.append(contentsOf: s) }
                self.lock.unlock()
            }
            do {
                try AudioIO.shared.start()
                isRecording = true
            } catch {
                AudioIO.shared.onMic = nil
                self.error = "ما قدرت أشغّل المايك: \(error.localizedDescription)"
                slog("dictation start failed \(error)")
            }
        }
    }

    func stop(_ done: @escaping (String) -> Void) {
        guard isRecording else { return }
        isRecording = false
        isBusy = true
        AudioIO.shared.onMic = nil
        AudioIO.shared.stop()
        lock.lock(); let audio = buffer; buffer.removeAll(); lock.unlock()
        let l = AppSettings.shared.language
        Task {
            let r = try? await SpeechRecognizer.shared.transcribe(audio, language: l == "auto" ? nil : l)
            isBusy = false
            if let t = r?.text, !t.isEmpty { done(t) }
        }
    }
}

/// مشغّل صوت بس (بدون مايك): وضع .playback عشان القراءة ما تفتح المايك ولا تقطع الصوت بإلغاء الصدى.
final class PlaybackOnly {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    init() { engine.attach(player) }

    /// معدل ثابت عشان ما نعيد تشغيل المحرك بين الأصوات (نبرة 24k، آبل 22.05k...)
    static let rate: Double = 24_000

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        if format == nil {
            let f = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: f)
            format = f
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
    }

    /// إعادة تشكيل خطية بسيطة (كافية للكلام).
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, x.count > 1 else { return x }
        let ratio = from / to
        let n = Int(Double(x.count) / ratio)
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let p = Double(i) * ratio
            let j = Int(p)
            let f = Float(p - Double(j))
            let a = x[min(j, x.count - 1)], b = x[min(j + 1, x.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }

    /// يشغّل ويرجع لما يخلص.
    func play(_ input: [Float], rate: Double) async {
        guard !input.isEmpty else { return }
        do { try prepare() } catch { slog("playback: \(error)"); return }
        let samples = Self.resample(input, from: rate, to: Self.rate)
        guard let f = format, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in c.resume() }
        }
    }

    func stop() {
        player.stop()
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// قراءة رسالة بصوت (زر السماعة تحت الرد).
@MainActor
final class Speaker {
    static let shared = Speaker()
    private var task: Task<Void, Never>?
    private var prep: Task<(samples: [Float], rate: Double), Never>?
    private let out = PlaybackOnly()

    /// يشغّل عينات جاهزة (مثل تجربة صوت نماء).
    func play(samples: [Float], sampleRate: Double) {
        stop()
        guard !AudioIO.shared.ownedByCall, !samples.isEmpty else { return }
        let out = self.out
        task = Task { await out.play(samples, rate: sampleRate) }
    }

    func speak(_ text: String, voice override: VoiceOption? = nil) {
        stop()
        let (parts, rest) = TextCleaner.splitSentences(text + "\n", first: false)
        let sentences = parts + (rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest])
        let voice = override ?? AppSettings.shared.voice
        let rate = AppSettings.shared.speechRate
        guard !AudioIO.shared.ownedByCall else { return }
        let out = self.out
        task = Task {
            // نجهز الجملة الجاية وهذي تشتغل
            var next: Task<(samples: [Float], rate: Double), Never>? = sentences.first.map { s in
                Task { await SpeechSynth.shared.synthesize(s, voice: voice, rate: rate) }
            }
            for i in sentences.indices {
                guard let cur = next else { break }
                self.prep = cur
                let a = await cur.value
                if Task.isCancelled { return }
                next = i + 1 < sentences.count ? Task { await SpeechSynth.shared.synthesize(sentences[i + 1], voice: voice, rate: rate) } : nil
                self.prep = next
                await out.play(a.samples, rate: a.rate)
                if Task.isCancelled { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        prep?.cancel()
        prep = nil
        if !AudioIO.shared.ownedByCall { out.stop() }
    }
}
