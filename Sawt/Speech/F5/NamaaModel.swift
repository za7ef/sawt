import Foundation
import MLX
import MLXFFT
import MLXNN
import MLXRandom

// منفذ F5-TTS (نسخة v1 Base) و Vocos على MLX، مبني على f5-tts-swift و vocos-swift (رخصة MIT)
// مع فروقات v1: الدوران الموضعي على كل رؤوس الانتباه، وتصفير حشو النص في كتل ConvNeXt.

// MARK: - طبقات مشتركة

final class N5Conv1d: Module, UnaryLayer {
    let weight: MLXArray
    let bias: MLXArray?
    let padding: Int
    let groups: Int

    init(inputChannels: Int, outputChannels: Int, kernelSize: Int, padding: Int, groups: Int = 1) {
        self.weight = MLXArray.zeros([outputChannels, kernelSize, inputChannels / groups])
        self.bias = MLXArray.zeros([outputChannels])
        self.padding = padding
        self.groups = groups
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = conv1d(x, weight, stride: 1, padding: padding, dilation: 1, groups: groups)
        if let bias { y = y + bias }
        return y
    }
}

func n5Mish(_ x: MLXArray) -> MLXArray { x * MLX.tanh(MLX.log(1 + MLX.exp(x))) }

final class N5GRN: Module {
    var gamma: MLXArray
    var beta: MLXArray
    init(dim: Int) {
        gamma = MLXArray.zeros([1, 1, dim]); beta = MLXArray.zeros([1, 1, dim])
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let gx = MLX.sqrt(MLX.sum(x * x, axis: 1, keepDims: true))
        let nx = gx / (MLX.mean(gx, axis: -1, keepDims: true) + 1e-6)
        return gamma * (x * nx) + beta + x
    }
}

final class N5ConvNeXtV2: Module {
    let dwconv: N5Conv1d
    let norm: LayerNorm
    let pwconv1: Linear
    let grn: N5GRN
    let pwconv2: Linear

    init(dim: Int, intermediate: Int) {
        dwconv = N5Conv1d(inputChannels: dim, outputChannels: dim, kernelSize: 7, padding: 3, groups: dim)
        norm = LayerNorm(dimensions: dim, eps: 1e-6)
        pwconv1 = Linear(dim, intermediate)
        grn = N5GRN(dim: intermediate)
        pwconv2 = Linear(intermediate, dim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var o = dwconv(x)
        o = norm(o)
        o = pwconv1(o)
        o = gelu(o)
        o = grn(o)
        o = pwconv2(o)
        return x + o
    }
}

// MARK: - التضمينات

final class N5TextEmbedding: Module {
    let text_embed: Embedding
    let text_blocks: [N5ConvNeXtV2]
    let dim: Int

    init(numEmbeds: Int, dim: Int, convLayers: Int) {
        text_embed = Embedding(embeddingCount: numEmbeds + 1, dimensions: dim)
        text_blocks = (0 ..< convLayers).map { _ in N5ConvNeXtV2(dim: dim, intermediate: dim * 2) }
        self.dim = dim
        super.init()
    }

    func callAsFunction(_ tokens: MLXArray, seqLen: Int, drop: Bool) -> MLXArray {
        // tokens: [1, nt] بقيم -1 للحشو
        var text = tokens + 1
        let n = text.dim(1)
        if n > seqLen { text = text[0..., 0 ..< seqLen] }
        if n < seqLen {
            text = MLX.concatenated([text, MLXArray.zeros([text.dim(0), seqLen - n], type: Int32.self)], axis: 1)
        }
        if drop { text = MLX.zeros(like: text) }
        let pad = (text .== 0).expandedDimensions(axis: -1)
        var x = text_embed(text)
        // precompute_freqs_cis(dim): [cos | sin]
        let half = dim / 2
        let inv = MLXArray((0 ..< half).map { 1.0 / pow(Float(10000), Float(2 * $0) / Float(dim)) })
        let t = MLXArray((0 ..< seqLen).map { Float($0) })
        let outer = t.expandedDimensions(axis: 1) * inv.expandedDimensions(axis: 0)
        let freqs = MLX.concatenated([MLX.cos(outer), MLX.sin(outer)], axis: -1)
        x = x + freqs.expandedDimensions(axis: 0).asType(x.dtype)
        let zero = MLXArray(Float(0)).asType(x.dtype)
        x = MLX.where(pad, zero, x)
        for b in text_blocks {
            x = b(x)
            x = MLX.where(pad, zero, x)
        }
        return x
    }
}

final class N5ConvPos: Module {
    let conv1d: [N5Conv1d]
    init(dim: Int) {
        conv1d = [N5Conv1d(inputChannels: dim, outputChannels: dim, kernelSize: 31, padding: 15, groups: 16),
                  N5Conv1d(inputChannels: dim, outputChannels: dim, kernelSize: 31, padding: 15, groups: 16)]
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        n5Mish(conv1d[1](n5Mish(conv1d[0](x))))
    }
}

final class N5InputEmbedding: Module {
    let proj: Linear
    let conv_pos_embed: N5ConvPos
    init(melDim: Int, textDim: Int, outDim: Int) {
        proj = Linear(melDim * 2 + textDim, outDim)
        conv_pos_embed = N5ConvPos(dim: outDim)
        super.init()
    }
    func callAsFunction(x: MLXArray, cond: MLXArray, text: MLXArray, dropCond: Bool) -> MLXArray {
        let c = dropCond ? MLX.zeros(like: cond) : cond
        let h = proj(MLX.concatenated([x, c, text], axis: -1))
        return conv_pos_embed(h) + h
    }
}

final class N5TimeEmbedding: Module {
    let time_mlp: [Linear]
    init(dim: Int) {
        time_mlp = [Linear(256, dim), Linear(dim, dim)]
        super.init()
    }
    func callAsFunction(_ t: MLXArray) -> MLXArray {
        // SinusPositionEmbedding(256) بمقياس 1000
        let half = 128
        let e = log(Float(10000)) / Float(half - 1)
        let freqs = MLX.exp(MLXArray((0 ..< half).map { Float($0) }) * -e)
        let arg = 1000 * t.expandedDimensions(axis: 1) * freqs.expandedDimensions(axis: 0)
        let emb = MLX.concatenated([MLX.sin(arg), MLX.cos(arg)], axis: -1)
        return time_mlp[1](silu(time_mlp[0](emb)))
    }
}

// MARK: - كتل المحوّل

func n5RotateHalf(_ x: MLXArray) -> MLXArray {
    // ترتيب x_transformers المتداخل: (x1, x2) -> (-x2, x1)
    var shape = x.shape
    let d = shape.removeLast()
    let r = x.reshaped(shape + [d / 2, 2])
    let x1 = r[.ellipsis, 0], x2 = r[.ellipsis, 1]
    return MLX.stacked([-x2, x1], axis: -1).reshaped(shape + [d])
}

final class N5Attention: Module {
    let heads: Int
    let to_q: Linear, to_k: Linear, to_v: Linear
    let to_out: [Linear]
    init(dim: Int, heads: Int, dimHead: Int) {
        self.heads = heads
        let inner = heads * dimHead
        to_q = Linear(dim, inner); to_k = Linear(dim, inner); to_v = Linear(dim, inner)
        to_out = [Linear(inner, dim)]
        super.init()
    }
    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let b = x.dim(0), n = x.dim(1)
        func split(_ t: MLXArray) -> MLXArray {
            t.reshaped([b, n, heads, -1]).transposed(0, 2, 1, 3)
        }
        var q = split(to_q(x)), k = split(to_k(x))
        let v = split(to_v(x))
        // v1: الدوران على كل الرؤوس بعد تقسيمها
        q = q * cos + n5RotateHalf(q) * sin
        k = k * cos + n5RotateHalf(k) * sin
        let scale = 1.0 / Float(q.dim(3)).squareRoot()
        var w = MLX.matmul(q * scale, k.transposed(0, 1, 3, 2))
        w = softmax(w.asType(.float32), axis: -1).asType(v.dtype)
        let o = MLX.matmul(w, v).transposed(0, 2, 1, 3).reshaped([b, n, -1])
        return to_out[0](o)
    }
}

final class N5AdaNorm: Module {
    let linear: Linear
    let norm: LayerNorm
    init(dim: Int, chunks: Int) {
        linear = Linear(dim, dim * chunks)
        norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        super.init()
    }
    func params(_ emb: MLXArray, _ chunks: Int) -> [MLXArray] {
        linear(silu(emb)).split(parts: chunks, axis: 1).map { $0.expandedDimensions(axis: 1) }
    }
}

final class N5FeedForward: Module {
    let fc1: Linear, fc2: Linear
    init(dim: Int, mult: Int) {
        fc1 = Linear(dim, dim * mult); fc2 = Linear(dim * mult, dim)
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(geluApproximate(fc1(x))) }
}

final class N5DiTBlock: Module {
    let attn_norm: N5AdaNorm
    let attn: N5Attention
    let ff_norm: LayerNorm
    let ff: N5FeedForward
    init(dim: Int, heads: Int, dimHead: Int, ffMult: Int) {
        attn_norm = N5AdaNorm(dim: dim, chunks: 6)
        attn = N5Attention(dim: dim, heads: heads, dimHead: dimHead)
        ff_norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        ff = N5FeedForward(dim: dim, mult: ffMult)
        super.init()
    }
    func callAsFunction(_ x: MLXArray, t: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let p = attn_norm.params(t, 6) // shift_msa, scale_msa, gate_msa, shift_mlp, scale_mlp, gate_mlp
        let normed = attn_norm.norm(x) * (1 + p[1]) + p[0]
        var h = x + p[2] * attn(normed, cos: cos, sin: sin)
        let n2 = ff_norm(h) * (1 + p[4]) + p[3]
        h = h + p[5] * ff(n2)
        return h
    }
}

final class N5DiT: Module {
    let time_embed: N5TimeEmbedding
    let text_embed: N5TextEmbedding
    let input_embed: N5InputEmbedding
    let transformer_blocks: [N5DiTBlock]
    let norm_out: N5AdaNorm
    let proj_out: Linear
    let dimHead = 64

    init(dim: Int = 1024, depth: Int = 22, heads: Int = 16, ffMult: Int = 2,
         melDim: Int = 100, textNumEmbeds: Int, textDim: Int = 512, convLayers: Int = 4) {
        time_embed = N5TimeEmbedding(dim: dim)
        text_embed = N5TextEmbedding(numEmbeds: textNumEmbeds, dim: textDim, convLayers: convLayers)
        input_embed = N5InputEmbedding(melDim: melDim, textDim: textDim, outDim: dim)
        transformer_blocks = (0 ..< depth).map { _ in N5DiTBlock(dim: dim, heads: heads, dimHead: 64, ffMult: ffMult) }
        norm_out = N5AdaNorm(dim: dim, chunks: 2)
        proj_out = Linear(dim, melDim)
        super.init()
    }

    func rope(_ n: Int) -> (MLXArray, MLXArray) {
        let half = dimHead / 2
        let inv = MLXArray((0 ..< half).map { 1.0 / pow(Float(10000), Float(2 * $0) / Float(dimHead)) })
        let t = MLXArray((0 ..< n).map { Float($0) })
        var f = t.expandedDimensions(axis: 1) * inv.expandedDimensions(axis: 0)   // [n, 32]
        f = MLX.stacked([f, f], axis: -1).reshaped([n, dimHead])                // متداخل
        return (MLX.cos(f), MLX.sin(f))
    }

    /// يرجع التنبؤ الشرطي وغير الشرطي معًا (دفعة 2) لتوجيه CFG.
    func callAsFunction(x: MLXArray, cond: MLXArray, textCond: MLXArray, textUncond: MLXArray,
                        time: Float, rope: (MLXArray, MLXArray)) -> MLXArray {
        let tvec = time_embed(MLXArray([time]))
        let a = input_embed(x: x, cond: cond, text: textCond, dropCond: false)
        let b = input_embed(x: x, cond: cond, text: textUncond, dropCond: true)
        var h = MLX.concatenated([a, b], axis: 0)
        let t = MLX.concatenated([tvec, tvec], axis: 0).asType(h.dtype)
        let c = rope.0.asType(h.dtype), s = rope.1.asType(h.dtype)
        for blk in transformer_blocks { h = blk(h, t: t, cos: c, sin: s) }
        let p = norm_out.params(t, 2) // scale, shift
        h = norm_out.norm(h) * (1 + p[0]) + p[1]
        return proj_out(h)
    }
}

// MARK: - Vocos

final class N5VocosBlock: Module {
    let dwconv: N5Conv1d
    let norm: LayerNorm
    let pwconv1: Linear
    let pwconv2: Linear
    let gamma: MLXArray
    init(dim: Int, intermediate: Int) {
        dwconv = N5Conv1d(inputChannels: dim, outputChannels: dim, kernelSize: 7, padding: 3, groups: dim)
        norm = LayerNorm(dimensions: dim, eps: 1e-6)
        pwconv1 = Linear(dim, intermediate)
        pwconv2 = Linear(intermediate, dim)
        gamma = MLXArray.ones([dim])
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        x + gamma * pwconv2(gelu(pwconv1(norm(dwconv(x)))))
    }
}

final class N5VocosBackbone: Module {
    let embed: N5Conv1d
    let norm: LayerNorm
    let convnext: [N5VocosBlock]
    let final_layer_norm: LayerNorm
    override init() {
        embed = N5Conv1d(inputChannels: 100, outputChannels: 512, kernelSize: 7, padding: 3)
        norm = LayerNorm(dimensions: 512, eps: 1e-6)
        convnext = (0 ..< 8).map { _ in N5VocosBlock(dim: 512, intermediate: 1536) }
        final_layer_norm = LayerNorm(dimensions: 512, eps: 1e-6)
        super.init()
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = norm(embed(x))
        for b in convnext { h = b(h) }
        return final_layer_norm(h)
    }
}

final class N5VocosHead: Module {
    let out: Linear
    override init() { out = Linear(512, 1026); super.init() }
}

final class N5Vocos: Module {
    let backbone: N5VocosBackbone
    let head: N5VocosHead
    override init() { backbone = N5VocosBackbone(); head = N5VocosHead(); super.init() }

    /// mel: [1, n, 100] -> عينات 24kHz
    func decode(_ mel: MLXArray) -> MLXArray {
        let h = head.out(backbone(mel))[0]                 // [n, 1026]
        let parts = h.split(parts: 2, axis: -1)
        let mag = MLX.minimum(MLX.exp(parts[0]), MLXArray(Float(100)))
        let ph = parts[1]
        let spec = (mag * MLX.cos(ph)) + (mag * MLX.sin(ph)).asImaginary()
        let frames = MLXFFT.irfft(spec, n: 1024, axis: -1)      // [n, 1024]
        let win = N5Audio.hann(1024)
        let fw = frames * win
        // تجميع متداخل (hop 256 = ربع النافذة) بدون حلقة على الإطارات
        let n = fw.dim(0)
        let chunks = fw.reshaped([n, 4, 256])
        var out = MLXArray.zeros([n + 3, 256])
        var env = MLXArray.zeros([n + 3, 256])
        let w2 = (win * win).reshaped([4, 256])
        for j in 0 ..< 4 {
            let widths: [IntOrPair] = [.init((j, 3 - j)), .init((0, 0))]
            out = out + MLX.padded(chunks[0..., j, 0...], widths: widths)
            env = env + MLX.padded(MLX.broadcast(w2[j].expandedDimensions(axis: 0), to: [n, 256]), widths: widths)
        }
        var y = (out / MLX.maximum(env, MLXArray(Float(1e-8)))).reshaped([-1])
        // padding="same": قص (n_fft - hop)/2 من الطرفين
        let trim = 384
        let total = y.dim(0)
        if total > 2 * trim { y = y[trim ..< (total - trim)] }
        return y
    }
}

// MARK: - الصوت والميل

enum N5Audio {
    static func hann(_ size: Int) -> MLXArray {
        // نافذة دورية مثل torch.hann_window
        MLXArray((0 ..< size).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(size)))) })
    }

    /// log-mel مثل vocos/F5: n_fft 1024, hop 256, center (انعكاس)، magnitude
    static func logMel(_ audio: [Float], filterbank: MLXArray) -> MLXArray {
        let nfft = 1024, hop = 256, pad = 512
        guard audio.count > pad + 1 else { return MLXArray.zeros([1, 1, 100]) }
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0 ..< audio.count { padded[i + pad] = audio[i] }
        for i in 0 ..< pad {
            padded[pad - 1 - i] = audio[min(i + 1, audio.count - 1)]
            padded[pad + audio.count + i] = audio[max(audio.count - 2 - i, 0)]
        }
        let frames = 1 + (padded.count - nfft) / hop
        let x = MLXArray(padded)
        let strided = MLX.asStrided(x, [frames, nfft], strides: [hop, 1])
        let spec = MLXFFT.rfft(strided * hann(nfft), axis: -1)
        let mag = MLX.abs(spec)                                 // [frames, 513]
        let mel = MLX.matmul(mag, filterbank.transposed())      // [frames, 100]
        return MLX.log(MLX.maximum(mel, MLXArray(Float(1e-5)))).expandedDimensions(axis: 0)
    }
}
