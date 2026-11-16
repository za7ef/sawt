import Foundation
import MLX
import MLXNN

/// مفكك NeuCodec (Neuphonic، رخصة Apache-2.0) على MLX: يحوّل رموز الصوت (50 رمز/ث، كتاب رموز واحد 65536)
/// إلى صوت 24kHz. منفذ خاص بنا بنفس حساب نسخة transformers (NeuCodecModel.decode):
/// FSQ → project_out → fc → conv(k7) → 2 ResNet → 12 طبقة انتباه ثنائي الاتجاه → 2 ResNet → LayerNorm → رأس ISTFT.
/// الأوزان: ملف float16 فيه المفكك بس، مستخرج من neuphonic/neucodec (التحويل الوحيد: أوزان الالتفاف بتخطيط MLX).
final class NeuCodecDecoder {
    static let sampleRate = 24_000
    static let hop = 480
    static let nFFT = 1920
    private static let dim = 1024
    private static let heads = 16
    private static let headDim = 64

    private let w: [String: MLXArray]
    private let ropeCos: MLXArray
    private let ropeSin: MLXArray
    private let window: MLXArray

    init(file: URL) throws {
        let raw = try loadArrays(url: file)
        guard raw["acoustic_decoder.head.linear.weight"] != nil, raw["quantizer.project_out.weight"] != nil,
              raw["acoustic_decoder.layers.11.mlp.fc2.weight"] != nil else {
            throw SawtError.failed("ملف مفكك الصوت ناقص")
        }
        w = raw
        // RoPE في NeuCodec: المواضع هي أرقام الرؤوس (0…15) مو الزمن، بأسلوب rotate_half (θ=10000)
        let half = Self.headDim / 2
        var c = [Float](), s = [Float]()
        for h in 0 ..< Self.heads {
            var row = [Float](repeating: 0, count: Self.headDim)
            for i in 0 ..< half {
                row[i] = Float(h) / pow(10_000, Float(2 * i) / Float(Self.headDim))
                row[i + half] = row[i]
            }
            c += row.map { Foundation.cos($0) }
            s += row.map { Foundation.sin($0) }
        }
        ropeCos = MLXArray(c, [1, Self.heads, 1, Self.headDim])
        ropeSin = MLXArray(s, [1, Self.heads, 1, Self.headDim])
        window = MLXArray((0 ..< Self.nFFT).map { Float(0.5 * (1 - Foundation.cos(2 * Double.pi * Double($0) / Double(Self.nFFT)))) })
    }

    private func lin(_ x: MLXArray, _ k: String, bias: Bool = true) -> MLXArray {
        let y = MLX.matmul(x, w[k + ".weight"]!.T)
        return bias ? y + w[k + ".bias"]! : y
    }

    /// x: [1, T, C]، الوزن [O, K, I]
    private func conv(_ x: MLXArray, _ k: String, pad: Int) -> MLXArray {
        conv1d(x, w[k + ".weight"]!, stride: 1, padding: pad) + w[k + ".bias"]!
    }

    /// GroupNorm(32) على القنوات، الحساب بـfloat32
    private func gn(_ x: MLXArray, _ k: String) -> MLXArray {
        let s = x.shape   // [1, T, C]
        let g = x.asType(.float32).reshaped([s[0], s[1], 32, s[2] / 32])
        let mean = g.mean(axes: [1, 3], keepDims: true)
        let v = g.variance(axes: [1, 3], keepDims: true)
        let n = ((g - mean) * MLX.rsqrt(v + 1e-6)).reshaped(s).asType(x.dtype)
        return n * w[k + ".weight"]! + w[k + ".bias"]!
    }

    private func resnet(_ x: MLXArray, _ p: String) -> MLXArray {
        var h = conv(silu(gn(x, p + ".norm1")), p + ".conv1", pad: 1)
        h = conv(silu(gn(h, p + ".norm2")), p + ".conv2", pad: 1)
        return x + h
    }

    private func rotateHalf(_ x: MLXArray) -> MLXArray {
        let h = Self.headDim / 2
        return concatenated([-x[.ellipsis, h...], x[.ellipsis, ..<h]], axis: -1)
    }

    private func attention(_ x: MLXArray, _ p: String) -> MLXArray {
        let t = x.dim(1)
        func heads(_ y: MLXArray) -> MLXArray { y.reshaped([1, t, Self.heads, Self.headDim]).transposed(0, 2, 1, 3) }
        var q = heads(lin(x, p + "q_proj", bias: false))
        var k = heads(lin(x, p + "k_proj", bias: false))
        let v = heads(lin(x, p + "v_proj", bias: false))
        let c = ropeCos.asType(q.dtype), s = ropeSin.asType(q.dtype)
        q = q * c + rotateHalf(q) * s
        k = k * c + rotateHalf(k) * s
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                                  scale: 1 / Float(Self.headDim).squareRoot(), mask: nil)
        return lin(o.transposed(0, 2, 1, 3).reshaped([1, t, Self.dim]), p + "o_proj", bias: false)
    }

    /// رموز → عينات 24kHz (عدد العينات = عدد الرموز × 480)
    func decode(_ codes: [Int]) -> [Float] {
        guard !codes.isEmpty else { return [] }
        let dt = DType.float16
        // FSQ: 8 مستويات × 4 قيم، كل رقم بأساس 4 → (رقم − 2) / 2
        var z = [Float](repeating: 0, count: codes.count * 8)
        for (i, c) in codes.enumerated() {
            var v = max(0, min(c, 65_535))
            for j in 0 ..< 8 { z[i * 8 + j] = Float(v % 4 - 2) / 2; v /= 4 }
        }
        var x = MLXArray(z, [1, codes.count, 8]).asType(dt)
        x = lin(x, "quantizer.project_out")
        let p = "acoustic_decoder."
        x = lin(x, p + "fc")
        x = conv(x, p + "embed", pad: 3)
        for i in 0 ..< 2 { x = resnet(x, p + "prior_net.\(i)") }
        for i in 0 ..< 12 {
            let l = p + "layers.\(i)."
            x = x + attention(MLXFast.rmsNorm(x, weight: w[l + "input_layernorm.weight"]!, eps: 1e-6), l + "self_attn.")
            let h = MLXFast.rmsNorm(x, weight: w[l + "post_attention_layernorm.weight"]!, eps: 1e-6)
            x = x + lin(silu(lin(h, l + "mlp.fc1", bias: false)), l + "mlp.fc2", bias: false)
            if i % 4 == 3 { eval(x) }
        }
        for i in 0 ..< 2 { x = resnet(x, p + "post_net.\(i)") }
        let xf = x.asType(.float32)
        x = MLXFast.layerNorm(xf, weight: w[p + "norm.weight"]!.asType(.float32), bias: w[p + "norm.bias"]!.asType(.float32), eps: 1e-6)
        let y = MLX.matmul(x, w[p + "head.linear.weight"]!.asType(.float32).T) + w[p + "head.linear.bias"]!.asType(.float32)
        return istft(y[0])
    }

    /// رأس ISTFT بحشو "same" مثل Vocos: n_fft 1920، hop 480 (ربع النافذة)
    private func istft(_ y: MLXArray) -> [Float] {
        let bins = Self.nFFT / 2 + 1   // 961
        let mag = MLX.minimum(MLX.exp(y[0..., ..<bins]), MLXArray(Float(100)))
        let ph = y[0..., bins...]
        let spec = (mag * MLX.cos(ph)) + (mag * MLX.sin(ph)).asImaginary()
        let frames = MLXFFT.irfft(spec, n: Self.nFFT, axis: -1) * window   // [n, 1920]
        let n = frames.dim(0)
        let hop = Self.hop
        let chunks = frames.reshaped([n, 4, hop])
        var out = MLXArray.zeros([n + 3, hop])
        var env = MLXArray.zeros([n + 3, hop])
        let w2 = (window * window).reshaped([4, hop])
        for j in 0 ..< 4 {
            let widths: [IntOrPair] = [.init((j, 3 - j)), .init((0, 0))]
            out = out + MLX.padded(chunks[0..., j, 0...], widths: widths)
            env = env + MLX.padded(MLX.broadcast(w2[j].expandedDimensions(axis: 0), to: [n, hop]), widths: widths)
        }
        var a = (out / MLX.maximum(env, MLXArray(Float(1e-11)))).reshaped([-1])
        let trim = (Self.nFFT - hop) / 2   // 720
        let total = a.dim(0)
        guard total > 2 * trim else { return [] }
        a = a[trim ..< (total - trim)]
        eval(a)
        return a.asArray(Float.self)
    }
}
