import Foundation
import SherpaOnnx

/// كاشف الكلام (Silero) يشتغل على إطارات 16 كيلوهرتز.
/// إذا ما توفر النموذج، يرجع لكاشف بسيط يعتمد على مستوى الصوت.
final class VoiceDetector {
    private var silero: SherpaOnnxVoiceActivityDetectorWrapper?
    private var pending: [Float] = []
    private let window = 512
    private var noiseFloor: Float = -60

    init() {
        guard let root = Catalog.voicesRoot else { return }
        let path = root.appendingPathComponent("silero_vad.onnx").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let sileroCfg = sherpaOnnxSileroVadModelConfig(
            model: path, threshold: 0.5, minSilenceDuration: 0.08,
            minSpeechDuration: 0.06, windowSize: window, maxSpeechDuration: 30)
        var cfg = sherpaOnnxVadModelConfig(sileroVad: sileroCfg, sampleRate: 16000, numThreads: 1)
        silero = SherpaOnnxVoiceActivityDetectorWrapper(config: &cfg, buffer_size_in_seconds: 30)
    }

    var usesNeuralModel: Bool { silero != nil }

    /// يرجع حالة الكلام لكل نافذة 32 ملي ثانية مع مستوى الصوت بالديسيبل.
    func process(_ samples: [Float]) -> [(speech: Bool, db: Float)] {
        pending.append(contentsOf: samples)
        var out: [(Bool, Float)] = []
        while pending.count >= window {
            let frame = Array(pending.prefix(window))
            pending.removeFirst(window)
            let db = AudioIO.rmsDB(frame)
            var speech: Bool
            if let vad = silero {
                vad.acceptWaveform(samples: frame)
                speech = vad.isSpeechDetected()
                while !vad.isEmpty() { vad.pop() }
            } else {
                speech = db > noiseFloor + 14
            }
            if !speech {
                noiseFloor = noiseFloor * 0.97 + db * 0.03
            }
            // تجاهل الهمس البعيد جدًا
            if db < -58 { speech = false }
            out.append((speech, db))
        }
        return out
    }

    func reset() {
        pending.removeAll()
        silero?.reset()
    }
}
