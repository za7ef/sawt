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
    private var starting = false

    func start() {
        // «starting» يمنع تشغيلين قبل ما يصير isRecording صح
        guard !isRecording, !starting, !isBusy else { return }
        if let why = AppleSTT.blockedReason { error = why; return }
        Speaker.shared.stop()
        if AudioIO.shared.isRunning {
            if AudioIO.shared.ownedByCall { error = "المايك مشغول بالمكالمة."; return }
            Speaker.shared.stop()
        }
        starting = true
        Task {
            defer { starting = false }
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
            defer { isBusy = false }
            do {
                let r = try await SpeechRecognizer.shared.transcribe(audio, language: l == "auto" ? nil : l)
                if !r.text.isEmpty { done(r.text) } else { error = "ما سمعت شي واضح، جرّب مرة ثانية." }
            } catch {
                slog("dictation transcribe failed \(error)")
                self.error = "ما قدرت أحوّل الصوت لنص: \(error.localizedDescription)"
            }
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

    /// يجدول بدون انتظار (ورا البفرات اللي قبله مباشرة). يرجع مهمة تخلص لما ينتهي تشغيله.
    func schedule(_ input: [Float], rate: Double) -> Task<Void, Never>? {
        guard !input.isEmpty else { return nil }
        do { try prepare() } catch { slog("playback: \(error)"); return nil }
        let samples = Self.resample(input, from: rate, to: Self.rate)
        guard let f = format, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var cont: CheckedContinuation<Void, Never>?
        let lock = NSLock()
        var done = false
        let t = Task {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if done { lock.unlock(); c.resume() } else { cont = c; lock.unlock() }
            }
        }
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
            lock.lock(); done = true; let c = cont; cont = nil; lock.unlock()
            c?.resume()
        }
        return t
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
        if voice.isAudar {
            task = Task { await Self.speakStreaming(sentences, voice: voice, rate: rate, out: out) }
            return
        }
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

    /// أودار: التوليد يمشي قدّام بدون ما ينتظر التشغيل (كل الجمل ورا بعض)، والصوت يطلع على دفعات.
    /// الجمل القصيرة تنضم لبعض (لين ~160 حرف) عشان ما تصير سكتة بين كل فاصلة وفاصلة.
    private static func speakStreaming(_ sentences: [String], voice: VoiceOption, rate: Double, out: PlaybackOnly) async {
        var merged: [String] = []
        for s in sentences {
            if let l = merged.last, l.count + s.count < 160, merged.count > 1 || l.count >= 40 {
                merged[merged.count - 1] = l + " " + s
            } else if let l = merged.last, merged.count == 1, l.count < 40 {
                // أول قطعة قصيرة: نضم لها اللي بعدها بس لين ~60 حرف (البداية تبقى سريعة)
                if l.count + s.count < 60 { merged[0] = l + " " + s } else { merged.append(s) }
            } else {
                merged.append(s)
            }
        }
        var cont: AsyncStream<[Float]>.Continuation!
        let chunks = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { cont = $0 }
        let start = Date()
        let gen = Task.detached(priority: .userInitiated) { [cont] in
            for s in merged {
                if Task.isCancelled { break }
                await SpeechSynth.shared.synthesizeStream(s, voice: voice, rate: rate) { samples, _ in cont!.yield(samples) }
            }
            cont!.finish()
        }
        // كل دفعة تنجدول فورًا ورا اللي قبلها (بدون فراغ بين البفرات)؛ ننتظر آخر وحدة بس
        var playEnd = Date.distantPast
        var last: Task<Void, Never>?
        var gaps = 0
        for await c in chunks {
            if Task.isCancelled { break }
            let now = Date()
            if playEnd == .distantPast {
                slog("speak: audar first audio \(Int(now.timeIntervalSince(start) * 1000))ms")
            } else if now > playEnd.addingTimeInterval(0.05) {
                gaps += 1
                slog("speak: audar gap \(Int(now.timeIntervalSince(playEnd) * 1000))ms (الصوت خلص قبل الدفعة)")
            }
            playEnd = max(playEnd, now).addingTimeInterval(Double(c.count) / 24_000)
            last = out.schedule(c, rate: 24_000)
        }
        if !Task.isCancelled { await last?.value }
        gen.cancel()
        slog("speak: audar done gaps=\(gaps)")
    }

    func stop() {
        task?.cancel()
        task = nil
        prep?.cancel()
        prep = nil
        if !AudioIO.shared.ownedByCall { out.stop() }
    }
}
