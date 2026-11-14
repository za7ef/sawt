import AVFoundation
import Accelerate

/// محرك الصوت: مايك مفتوح دائمًا مع إلغاء الصدى من العتاد، ومشغّل في نفس المحرك
/// عشان النظام يعرف وش يطلع من السماعة ويشيله من صوت المايك.
final class AudioIO {
    static let shared = AudioIO()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// صيغة التشغيل الثابتة. أي صوت بمعدل مختلف يتحوّل لها.
    let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
    let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                  channels: 1, interleaved: false)!

    /// يُستدعى على خيط الصوت بإطارات 16 كيلوهرتز أحادية.
    var onMic: (([Float]) -> Void)?

    private(set) var isRunning = false
    private var micConverter: AVAudioConverter?
    private var playConverters: [Double: AVAudioConverter] = [:]
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0

    /// مستويات للرسوم المتحركة (0...1).
    private(set) var micLevel: Float = 0
    private(set) var outLevel: Float = 0

    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return pending > 0 }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let input = engine.inputNode
        // إلغاء الصدى وتقليل الضجيج من العتاد. هذا اللي يخلي المايك يظل مفتوح والذكاء يتكلم.
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = true
        input.isVoiceProcessingBypassed = false
        if #available(iOS 17.0, *) {
            var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
            ducking.enableAdvancedDucking = false
            ducking.duckingLevel = .min
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let inFormat = input.outputFormat(forBus: 0)
        let conv = AVAudioConverter(from: inFormat, to: micFormat)
        conv?.downmix = true
        micConverter = conv

        input.installTap(onBus: 0, bufferSize: 512, format: inFormat) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        player.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.outLevel = Self.level(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        stopPlayback()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        micLevel = 0
        outLevel = 0
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let conv = micConverter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        micLevel = Self.level(out)
        onMic?(samples)
    }

    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }

    static func rmsDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return 20 * log10(max(rms, 1e-7))
    }

    // MARK: التشغيل

    /// يجدول مقطع صوت. `onDone` يُستدعى بعد ما يخلص تشغيله فعليًا.
    func enqueue(samples: [Float], sampleRate: Double, onDone: (() -> Void)? = nil) {
        guard isRunning, !samples.isEmpty else { onDone?(); return }
        guard let buffer = makeBuffer(samples: samples, sampleRate: sampleRate) else { onDone?(); return }
        lock.lock()
        pending += 1
        let gen = generation
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if gen == self.generation { self.pending = max(0, self.pending - 1) }
            self.lock.unlock()
            if gen == self.generation { onDone?() }
        }
        if !player.isPlaying { player.play() }
    }

    /// يقطع أي كلام شغال فورًا (للمقاطعة).
    func stopPlayback() {
        lock.lock()
        generation += 1
        pending = 0
        lock.unlock()
        player.stop()
        if isRunning { player.play() }
        outLevel = 0
    }

    private func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let src = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            src.floatChannelData![0].update(from: p.baseAddress!, count: samples.count)
        }
        if sampleRate == playFormat.sampleRate { return src }
        let conv: AVAudioConverter
        if let c = playConverters[sampleRate] {
            conv = c
            conv.reset()
        } else {
            guard let c = AVAudioConverter(from: srcFormat, to: playFormat) else { return nil }
            playConverters[sampleRate] = c
            conv = c
        }
        let cap = AVAudioFrameCount(Double(samples.count) * playFormat.sampleRate / sampleRate + 256)
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return err == nil ? out : nil
    }
}
