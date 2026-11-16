// Sawt: مجدول LCM مكتوب من معادلات الورقة (Luo et al., 2023, "Latent Consistency Models", arXiv:2310.04378)
// ومن إعدادات LCM-LoRA الافتراضية المنشورة. ليس منسوخًا من أي تنفيذ آخر.

import Accelerate
import CoreML

/// مجدول نماذج الاتساق الكامنة (LCM): كل خطوة تقدّر الصورة النظيفة مباشرة
/// ثم تضيف ضجيجًا جديدًا بمستوى الخطوة التالية. يكفيه ٤–٨ خطوات.
@available(iOS 16.2, macOS 13.1, *)
public final class LCMScheduler: Scheduler {
    public let trainStepCount: Int
    public let inferenceStepCount: Int
    public let betas: [Float]
    public let alphas: [Float]
    public let alphasCumProd: [Float]
    public let timeSteps: [Int]

    public private(set) var modelOutputs: [MLShapedArray<Float32>] = []

    /// تكبير الزمن في شروط الحدود (القيمة الافتراضية لـLCM-LoRA)
    let timestepScaling: Float = 10
    /// sigma_data في شروط الحدود
    let sigmaData: Float = 0.5
    private var random: NumPyRandomSource

    /// - Parameters:
    ///   - stepCount: عدد خطوات الاستدلال (٤–٨ عادة)
    ///   - originalSteps: عدد خطوات جدول التقطير الأصلي (٥٠ في LCM)
    ///   - seed: بذرة الضجيج المضاف بين الخطوات
    public init(stepCount: Int, originalSteps: Int = 50, trainStepCount: Int = 1000,
                betaStart: Float = 0.00085, betaEnd: Float = 0.012, seed: UInt32) {
        self.trainStepCount = trainStepCount
        let n = max(1, min(stepCount, originalSteps))
        self.inferenceStepCount = n
        // جدول betas «scaled linear» مثل Stable Diffusion 1.5
        self.betas = linspace(pow(betaStart, 0.5), pow(betaEnd, 0.5), trainStepCount).map { $0 * $0 }
        self.alphas = betas.map { 1 - $0 }
        var cum = alphas
        for i in 1..<cum.count { cum[i] *= cum[i - 1] }
        self.alphasCumProd = cum

        // أزمنة جدول التقطير: k-1, 2k-1, …, T-1 (k = T / originalSteps)، ونختار منها n بتباعد متساوٍ من الأعلى
        let k = trainStepCount / originalSteps
        let origin = (1...originalSteps).map { $0 * k - 1 }
        let reversed = Array(origin.reversed())
        self.timeSteps = (0..<n).map { i in reversed[(i * reversed.count) / n] }
        self.random = NumPyRandomSource(seed: seed &+ 1)
    }

    /// شروط الحدود: c_skip(t) = σ² / ((t·s)² + σ²) ، c_out(t) = t·s / sqrt((t·s)² + σ²)
    private func boundary(_ t: Int) -> (skip: Float, out: Float) {
        let ts = Float(t) * timestepScaling
        let s2 = sigmaData * sigmaData
        return (s2 / (ts * ts + s2), ts / (ts * ts + s2).squareRoot())
    }

    public func step(output: MLShapedArray<Float32>, timeStep t: Int, sample s: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        let idx = timeSteps.firstIndex(of: t) ?? (timeSteps.count - 1)
        let aT = alphasCumProd[t]
        let (cSkip, cOut) = boundary(t)

        // x0 المتوقع من الضجيج المتوقع: (x_t - sqrt(1-ᾱ_t)·ε) / sqrt(ᾱ_t)
        let x0 = weightedSum([Double(1 / aT.squareRoot()), Double(-(1 - aT).squareRoot() / aT.squareRoot())], [s, output])
        // الناتج المتسق: c_out·x0 + c_skip·x_t
        let denoised = weightedSum([Double(cOut), Double(cSkip)], [x0, s])
        modelOutputs.removeAll(keepingCapacity: true)
        modelOutputs.append(denoised)

        // آخر خطوة: الناتج هو الصورة النظيفة
        guard idx + 1 < timeSteps.count else { return denoised }

        // غير ذلك: نعيد إضافة ضجيج بمستوى الخطوة التالية
        let aPrev = alphasCumProd[timeSteps[idx + 1]]
        let noise = MLShapedArray<Float32>(converting: random.normalShapedArray(s.shape, mean: 0, stdev: 1))
        return weightedSum([Double(aPrev.squareRoot()), Double((1 - aPrev).squareRoot())], [denoised, noise])
    }
}
