import CoreGraphics
import Foundation
import MLX
import MLXNN
import MLXRandom

// «واقعي+»: Z-Image Turbo (Tongyi-MAI، Apache 2.0) بأوزان 4-bit من mflux على MLX، على الجوال بالكامل.
// المرجع: diffusers (ZImageTransformer2DModel وZImagePipeline، Apache 2.0) و turbo-mlx (rinste، MIT).
// مُرمّز النص Qwen3-4B مشترك مع «دقيق» (نفس الأوزان الأصلية)، والذاكرة على مراحل: النص ← المحوّل ← VAE.

enum ZImage {
    static let revision = "f427e257d8e6ffa03edd4d9ac554a05809da456c"
    static let base = "https://huggingface.co/mflux-community/z-image-turbo-mflux-q4/resolve/\(revision)/"
    static let files: [(path: String, mb: Double)] = [
        ("transformer/0.safetensors", 2140),
        ("transformer/1.safetensors", 1324),
        ("vae/0.safetensors", 165),
    ]
    static let steps = 8
    static let size = 512            // مضاعفات 16
    static let hiddenLayer = 35      // hidden_states[-2] من 36 طبقة
    static let shift: Float = 3      // FlowMatchEuler بإزاحة ثابتة
    static let vaeScale: Float = 0.3611
    static let vaeShift: Float = 0.1159
}

final class ZImageTransformer {
    private let w: KleinWeights
    private let dim = 3840, heads = 30, headDim = 128
    private let layers = 30, refiners = 2
    private let axes = [32, 48, 48]
    private let theta: Float = 256

    init(dir: URL) throws {
        var d: [String: MLXArray] = [:]
        for f in ["0.safetensors", "1.safetensors"] {
            let part = try loadArrays(url: dir.appendingPathComponent(f))
            d.merge(part) { a, _ in a }
        }
        guard d["all_x_embedder.2-1.weight"] != nil, d["layers.29.feed_forward.w2.weight"] != nil,
              d["context_refiner.1.attention.to_q.weight"] != nil else { throw KleinError.missing("z-image transformer") }
        w = KleinWeights(d: d, bits: 0, group: 0)   // البتات والمجموعة تنحسب من الأشكال
    }

    // MARK: RoPE (أزواج متجاورة)

    private func ropeTables(_ ids: [Int32]) -> (cos: MLXArray, sin: MLXArray) {
        let pos = MLXArray(ids).reshaped([-1, 3]).asType(.float32)
        var cs: [MLXArray] = [], ss: [MLXArray] = []
        for (a, d) in axes.enumerated() {
            let ex = MLXArray(stride(from: 0, to: d, by: 2).map { Float($0) / Float(d) })
            let inv = 1 / MLX.pow(MLXArray(theta), ex)
            let f = pos[0..., a].expandedDimensions(axis: 1) * inv.expandedDimensions(axis: 0)
            let c = MLX.cos(f).expandedDimensions(axis: -1), s = MLX.sin(f).expandedDimensions(axis: -1)
            cs.append(concatenated([c, c], axis: -1).reshaped([-1, d]))
            ss.append(concatenated([s, s], axis: -1).reshaped([-1, d]))
        }
        return (concatenated(cs, axis: -1), concatenated(ss, axis: -1))
    }

    private func applyRope(_ x: MLXArray, _ r: (cos: MLXArray, sin: MLXArray)) -> MLXArray {
        let s = x.shape
        let xf = x.asType(.float32)
        let pairs = xf.reshaped([s[0], s[1], s[2], s[3] / 2, 2])
        let a = pairs[.ellipsis, 0], b = pairs[.ellipsis, 1]
        let rotated = stacked([-b, a], axis: -1).reshaped(s)
        return (xf * r.cos + rotated * r.sin).asType(x.dtype)
    }

    // MARK: الطبقات

    private func rms(_ x: MLXArray, _ k: String) -> MLXArray { MLXFast.rmsNorm(x, weight: w[k], eps: 1e-5) }

    private func toHeads(_ x: MLXArray) -> MLXArray {
        x.reshaped([x.dim(0), x.dim(1), heads, headDim]).transposed(0, 2, 1, 3)
    }

    private func attention(_ x: MLXArray, _ p: String, _ rope: (cos: MLXArray, sin: MLXArray)) -> MLXArray {
        let q = applyRope(MLXFast.rmsNorm(toHeads(w.lin(x, p + "to_q")), weight: w[p + "norm_q.weight"], eps: 1e-5), rope)
        let k = applyRope(MLXFast.rmsNorm(toHeads(w.lin(x, p + "to_k")), weight: w[p + "norm_k.weight"], eps: 1e-5), rope)
        let v = toHeads(w.lin(x, p + "to_v"))
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                                  scale: 1 / Float(headDim).squareRoot(), mask: nil)
        return w.lin(o.transposed(0, 2, 1, 3).reshaped([x.dim(0), x.dim(1), dim]), p + "to_out.0")
    }

    private func ff(_ x: MLXArray, _ p: String) -> MLXArray {
        w.lin(silu(w.lin(x, p + "w1")) * w.lin(x, p + "w3"), p + "w2")
    }

    /// كتلة Z-Image: تطبيع RMS قبل وبعد، وتعديل (scale + بوابة tanh) لو فيه adaln
    private func block(_ x: MLXArray, _ p: String, _ rope: (cos: MLXArray, sin: MLXArray), adaln: MLXArray?) -> MLXArray {
        var h = x
        if let adaln {
            let m = w.lin(adaln, p + "adaLN_modulation.0").expandedDimensions(axis: 1)   // [1,1,4·dim]
            let scaleMsa = 1 + m[.ellipsis, 0 ..< dim]
            let gateMsa = MLX.tanh(m[.ellipsis, dim ..< (2 * dim)])
            let scaleMlp = 1 + m[.ellipsis, (2 * dim) ..< (3 * dim)]
            let gateMlp = MLX.tanh(m[.ellipsis, (3 * dim)...])
            let a = attention(rms(h, p + "attention_norm1.weight") * scaleMsa, p + "attention.", rope)
            h = h + gateMsa * rms(a, p + "attention_norm2.weight")
            let f = ff(rms(h, p + "ffn_norm1.weight") * scaleMlp, p + "feed_forward.")
            h = h + gateMlp * rms(f, p + "ffn_norm2.weight")
        } else {
            let a = attention(rms(h, p + "attention_norm1.weight"), p + "attention.", rope)
            h = h + rms(a, p + "attention_norm2.weight")
            let f = ff(rms(h, p + "ffn_norm1.weight"), p + "feed_forward.")
            h = h + rms(f, p + "ffn_norm2.weight")
        }
        return h
    }

    /// x: [1, h·w, 64] (رقع 2×2 من 16 قناة)، cap: [1, L, 2560]، sigma من 1 لين 0. يرجع مخرج النموذج [1, h·w, 64]
    func callAsFunction(_ x: MLXArray, cap capIn: MLXArray, sigma: Float, h: Int, w gw: Int) -> MLXArray {
        let dt = DType.bfloat16
        // تضمين الزمن: t = (1 − sigma)·1000، جيبي 256 (cos أول)
        let t = (1 - sigma) * 1000
        let half = 128
        let freqs = MLX.exp(MLXArray((0 ..< half).map { -log(Float(10000)) * Float($0) / Float(half) }))
        let args = (t * freqs).reshaped([1, half])
        let tf = concatenated([MLX.cos(args), MLX.sin(args)], axis: -1).asType(dt)
        let adaln = w.lin(silu(w.lin(tf, "t_embedder.linear1")), "t_embedder.linear2")   // [1, 256]

        var img = w.lin(x.asType(dt), "all_x_embedder.2-1")
        let nImg = img.dim(1)
        var cap = w.lin(MLXFast.rmsNorm(capIn.asType(dt), weight: w["cap_embedder.0.weight"], eps: 1e-5), "cap_embedder.1")
        let nCap = cap.dim(1)
        let capPadded = (nCap + 31) / 32 * 32

        // المواضع: النص (1+i, 0, 0)، والصورة (طول النص المحشو + 1, y, x)
        var capIDs: [Int32] = []
        for i in 0 ..< nCap { capIDs += [Int32(1 + i), 0, 0] }
        var imgIDs: [Int32] = []
        for y in 0 ..< h { for xx in 0 ..< gw { imgIDs += [Int32(capPadded + 1), Int32(y), Int32(xx)] } }
        let ropeImg = ropeTables(imgIDs)
        let ropeCap = ropeTables(capIDs)

        for i in 0 ..< refiners { img = block(img, "noise_refiner.\(i).", ropeImg, adaln: adaln) }
        for i in 0 ..< refiners { cap = block(cap, "context_refiner.\(i).", ropeCap, adaln: nil) }
        eval(img, cap)

        // التسلسل الموحد: [الصورة، النص]
        var u = concatenated([img, cap], axis: 1)
        let rope = (cos: concatenated([ropeImg.cos, ropeCap.cos], axis: 0),
                    sin: concatenated([ropeImg.sin, ropeCap.sin], axis: 0))
        for i in 0 ..< layers {
            u = block(u, "layers.\(i).", rope, adaln: adaln)
            if i % 3 == 2 { eval(u) }
        }

        let scale = 1 + w.lin(silu(adaln), "all_final_layer.2-1.adaLN_modulation.0").expandedDimensions(axis: 1)
        let out = w.lin(MLXFast.layerNorm(u, weight: nil, bias: nil, eps: 1e-6) * scale, "all_final_layer.2-1.linear")
        return out[0..., 0 ..< nImg, 0...].asType(.float32)
    }
}

enum ZImagePipeline {
    static func sigmas(steps: Int) -> [Float] {
        var out: [Float] = (0 ..< steps).map { i in
            let s: Float = steps > 1 ? 1 - Float(i) * (1 - 1 / Float(steps)) / Float(steps - 1) : 1
            return ZImage.shift * s / (1 + (ZImage.shift - 1) * s)
        }
        out.append(0)
        return out
    }

    /// قوة إعادة الرسم من صورة (SDEdit): نسبة الخطوات اللي تنعاد (0.7 = يغيّر كثير ويحافظ على التكوين والألوان)
    static let editStrength: Float = 0.7

    /// source: صورة يعيد رسمها مع الوصف (SDEdit). Z-Image Turbo ما فيه تعديل حقيقي، فيعيد رسم الصورة كلها.
    /// plan: أدوات العارض. مع قناع: داخل القناع يتولّد والباقي يرجع من الأصل كل خطوة. الإزالة وتغيير الحجم
    /// تبدأ من ضجيج كامل داخل القناع (تكملة)، والتعليمة والعلامات SDEdit بقوة editStrength.
    static func generate(dir: URL, prompt: String, seed: UInt64, source: URL? = nil, plan: EditPlan? = nil,
                         onPhase: @escaping (String) -> Void,
                         onStep: @escaping (Int, Int) -> Void) async throws -> CGImage {
        var lh = ZImage.size / 16, lw = ZImage.size / 16   // رقع 2×2 على كامن بدقة 1/8

        // ٠) صورة المصدر: نرمّزها ونرقّعها بنفس ترتيب فك الرقع تحت
        var start: MLXArray?
        var tokMask: MLXArray?
        var edit: EditInputs?
        if let source {
            onPhase("source")
            let e = try EditInputs.prepare(source: source, plan: plan)
            edit = e
            lh = e.h / 16; lw = e.w / 16
            let enc = try VAEEncoder(file: dir.appendingPathComponent("vae/0.safetensors"), pytorchLayout: false)
            let z = (enc.encode(e.canvas) - ZImage.vaeShift) * ZImage.vaeScale   // [1, 2lh, 2lw, 16]
            start = z.reshaped([1, lh, 2, lw, 2, 16]).transposed(0, 1, 3, 2, 4, 5).reshaped([1, lh * lw, 64])
            tokMask = e.tokenMask(cell: 16)
            eval(start!)
            MLX.Memory.clearCache()
            slog("zimage: sdedit \(plan?.kind.rawValue ?? "instruct") \(e.w)x\(e.h) mask=\(tokMask != nil) footprint=\(RAM.footprintMB)MB")
            try Task.checkCancellation()
        }
        let fill = plan?.kind == .remove || plan?.kind == .resize

        // ١) النص (المُرمّز المشترك)
        onPhase("encode")
        var cap: MLXArray
        do {
            let enc = try await QwenTextEncoder(dir: QwenShared.dir, keep: ZImage.hiddenLayer)
            cap = enc.encodeZImage(prompt)
        }
        MLX.Memory.clearCache()
        slog("zimage: text encoded \(cap.shape) footprint=\(RAM.footprintMB)MB")
        try Task.checkCancellation()

        // ٢) إزالة الضجيج
        onPhase("load")
        let noise = MLXRandom.normal([1, lh * lw, 64], key: MLXRandom.key(seed))
        var latents = noise
        do {
            let tr = try ZImageTransformer(dir: dir.appendingPathComponent("transformer"))
            let sig = sigmas(steps: ZImage.steps)
            // SDEdit مثل img2img في diffusers: نتخطى أول الخطوات ونبدأ من الصورة مخلوطة بالضجيج عند sigma البداية
            var first = 0
            if let start, !(fill && tokMask != nil) {
                first = ZImage.steps - min(ZImage.steps, Int(Float(ZImage.steps) * editStrength))
                latents = (1 - sig[first]) * start.asType(latents.dtype) + sig[first] * latents
                eval(latents)
            }
            onStep(0, ZImage.steps - first)
            for i in first ..< ZImage.steps {
                try Task.checkCancellation()
                let out = tr(latents, cap: cap, sigma: sig[i], h: lh, w: lw)
                // السرعة = −مخرج النموذج
                latents = latents - (sig[i + 1] - sig[i]) * out
                if let start, let tokMask {
                    let s = sig[i + 1]
                    let k = (1 - s) * start.asType(latents.dtype) + s * noise.asType(latents.dtype)
                    latents = tokMask * latents + (1 - tokMask) * k
                }
                eval(latents)
                onStep(i + 1 - first, ZImage.steps - first)
            }
        }
        cap = MLXArray(0)
        start = nil
        MLX.Memory.clearCache()
        slog("zimage: denoised footprint=\(RAM.footprintMB)MB")

        // ٣) فك الصورة
        onPhase("decode")
        let pixels: MLXArray
        do {
            let vae = try VAEDecoder(file: dir.appendingPathComponent("vae/0.safetensors"), pytorchLayout: false)
            // فك الرقع: الميزة = (py·2 + px)·16 + c
            var z = latents.reshaped([1, lh, lw, 2, 2, 16]).transposed(0, 1, 3, 2, 4, 5)
                .reshaped([1, lh * 2, lw * 2, 16])
            z = z / ZImage.vaeScale + ZImage.vaeShift
            let raw = vae.decode(z)
            pixels = edit?.composite(raw) ?? raw
            eval(pixels)
        }
        defer { MLX.Memory.clearCache() }
        return try KleinPipeline.toImage(pixels)
    }
}
