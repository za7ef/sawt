import CoreGraphics
import Foundation
import MLX
import MLXNN
import MLXRandom
import Tokenizers

// «دقيق»: FLUX.2 Klein 4B بأوزان ثلاثية (Bonsai Image من PrismML) على MLX، على الجوال بالكامل.
// المرجع: diffusers (Flux2KleinPipeline) و flux-2-swift-mlx (Vincent Gourbin، MIT).
// الترتيب عشان الذاكرة (8GB): مُرمّز النص يشتغل ويطلع، بعده المحوّل يشتغل ويطلع، بعده VAE.

enum Klein {
    /// نسخة ثابتة من المستودع عشان الملفات ما تتغير تحتنا
    static let revision = "2c24c81b934a658ba5590cf39088ba929985b4a8"
    static let base = "https://huggingface.co/prism-ml/bonsai-image-ternary-4B-mlx-2bit/resolve/\(revision)/"

    /// ملفات «دقيق» نفسه وأحجامها التقريبية بالميقا (لشريط التقدم)
    static let files: [(path: String, mb: Double)] = [
        ("transformer-packed-mflux/diffusion_pytorch_model.safetensors", 1425),
        ("vae/diffusion_pytorch_model.safetensors", 168),
    ]

    static let steps = 4
    static let size = 512                 // مضاعفات 32
    static let maxTokens = 512
    static let hiddenLayers = [9, 18, 27] // مخرجات هالطبقات من Qwen3 (بعد ٩ و١٨ و٢٧ طبقة)
}

/// مُرمّز النص المشترك بين «دقيق» و«واقعي+»: Qwen3-4B بـ4 بت (نفس الأوزان الأصلية للاثنين)،
/// ينزل مرة وحدة في مجلد مشترك من مستودع Bonsai
enum QwenShared {
    static let base = Klein.base + "text_encoder-mlx-4bit/"
    static let files: [(path: String, mb: Double)] = [
        ("model.safetensors", 2263),
        ("config.json", 0.01),
        ("tokenizer.json", 11.4),
        ("tokenizer_config.json", 0.01),
        ("special_tokens_map.json", 0.01),
        ("added_tokens.json", 0.01),
        ("vocab.json", 2.8),
        ("merges.txt", 1.7),
    ]
    static let approxGB = 2.28

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageModels/qwen3-4b-mlx4", isDirectory: true)
    }

    static var installed: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.path).path) }
    }
}

// MARK: - أوزان + طبقة خطية (مكمّمة أو عادية)

struct KleinWeights {
    var d: [String: MLXArray]
    let bits: Int
    let group: Int

    subscript(_ k: String) -> MLXArray {
        guard let a = d[k] else { preconditionFailure("klein: missing weight \(k)") }
        return a
    }

    func has(_ k: String) -> Bool { d[k] != nil }

    func lin(_ x: MLXArray, _ k: String) -> MLXArray {
        var y: MLXArray
        if let s = d[k + ".scales"] {
            // البتات والمجموعة من الأشكال: الأعمدة المعبّأة = in·bits/32، والمقاييس = in/group
            let w = self[k + ".weight"]
            let inDim = x.dim(-1)
            let b = bits > 0 ? bits : w.dim(1) * 32 / inDim
            let g = group > 0 ? group : inDim / s.dim(1)
            y = quantizedMatmul(x.asType(s.dtype), w, scales: s, biases: d[k + ".biases"],
                                transpose: true, groupSize: g, bits: b)
        } else {
            y = matmul(x, self[k + ".weight"].T)
        }
        if let b = d[k + ".bias"] { y = y + b }
        return y
    }
}

enum KleinError: LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self {
        case .missing(let w): return "ملفات «دقيق» ناقصة (\(w)). احذفه ونزّله من جديد."
        }
    }
}

// MARK: - مُرمّز النص (Qwen3-4B بـ4 بت)

final class QwenTextEncoder {
    private let w: KleinWeights
    private let tok: any Tokenizer
    private let layerCount: Int

    private let heads = 32, kvHeads = 8, headDim = 128

    /// keep = عدد الطبقات اللي نشغّلها (الباقي نشيله قبل ما ينحمّل للذاكرة)
    init(dir: URL, keep: Int) async throws {
        var all = try loadArrays(url: dir.appendingPathComponent("model.safetensors"))
        for k in Array(all.keys) {
            if k == "model.norm.weight" || k.hasPrefix("lm_head") { all[k] = nil; continue }
            guard k.hasPrefix("model.layers.") else { continue }
            let rest = k.dropFirst("model.layers.".count)
            if let n = Int(rest.prefix { $0.isNumber }), n >= keep { all[k] = nil }
        }
        guard all["model.embed_tokens.scales"] != nil, all["model.layers.\(keep - 1).mlp.down_proj.weight"] != nil else {
            throw KleinError.missing("text_encoder")
        }
        w = KleinWeights(d: all, bits: 4, group: 64)
        layerCount = keep
        tok = try await AutoTokenizer.from(modelFolder: dir)
    }

    /// «دقيق»: قالب المحادثة بدون تفكير، حشو لين 512، ومخرجات الطبقات 9/18/27 جنب بعض → [1, 512, 7680]
    func encodeKlein(_ prompt: String) -> MLXArray {
        let text = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return run(text, padTo: Klein.maxTokens, collect: Klein.hiddenLayers)
    }

    /// «واقعي+»: القالب مع التفكير مفعّل (بدون وسم think)، بدون حشو، ومخرج الطبقة قبل الأخيرة → [1, L, 2560]
    func encodeZImage(_ prompt: String) -> MLXArray {
        let text = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
        return run(text, padTo: nil, collect: [ZImage.hiddenLayer])
    }

    private func run(_ text: String, padTo: Int?, collect: [Int]) -> MLXArray {
        var ids = tok.encode(text: text, addSpecialTokens: false)
        if ids.count > Klein.maxTokens { ids = Array(ids.prefix(Klein.maxTokens)) }
        let n = ids.count
        if let padTo { ids += Array(repeating: 151643, count: padTo - n) }   // حشو يمين بـ<|endoftext|>
        let L = ids.count

        let input = MLXArray(ids.map { Int32($0) })
        let emb = dequantized(w["model.embed_tokens.weight"].take(input, axis: 0),
                              scales: w["model.embed_tokens.scales"].take(input, axis: 0),
                              biases: w["model.embed_tokens.biases"].take(input, axis: 0),
                              groupSize: 64, bits: 4)
        var h = emb.reshaped([1, L, -1])

        // سببي + نتجاهل الحشو
        let qi = MLXArray((0 ..< L).map { Int32($0) }).reshaped([L, 1])
        let kj = MLXArray((0 ..< L).map { Int32($0) }).reshaped([1, L])
        let allowed = (kj .<= qi) .&& (kj .< Int32(n))
        let mask = which(allowed, MLXArray(Float(0)), MLXArray(-Float.infinity)).asType(h.dtype)

        var outs: [MLXArray] = []
        for i in 0 ..< layerCount {
            h = layer(h, i, mask: mask, L: L)
            if collect.contains(i + 1) {
                eval(h)
                outs.append(h)
            }
        }
        let out = concatenated(outs, axis: -1)
        eval(out)
        return out
    }

    private func layer(_ x: MLXArray, _ i: Int, mask: MLXArray, L: Int) -> MLXArray {
        let p = "model.layers.\(i)."
        let r = MLXFast.rmsNorm(x, weight: w[p + "input_layernorm.weight"], eps: 1e-6)
        var q = w.lin(r, p + "self_attn.q_proj").reshaped([1, L, heads, headDim])
        var k = w.lin(r, p + "self_attn.k_proj").reshaped([1, L, kvHeads, headDim])
        let v = w.lin(r, p + "self_attn.v_proj").reshaped([1, L, kvHeads, headDim]).transposed(0, 2, 1, 3)
        q = MLXFast.rmsNorm(q, weight: w[p + "self_attn.q_norm.weight"], eps: 1e-6).transposed(0, 2, 1, 3)
        k = MLXFast.rmsNorm(k, weight: w[p + "self_attn.k_norm.weight"], eps: 1e-6).transposed(0, 2, 1, 3)
        q = MLXFast.RoPE(q, dimensions: headDim, traditional: false, base: 1_000_000, scale: 1, offset: 0)
        k = MLXFast.RoPE(k, dimensions: headDim, traditional: false, base: 1_000_000, scale: 1, offset: 0)
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                                  scale: 1 / Float(headDim).squareRoot(), mask: mask)
        var h = x + w.lin(o.transposed(0, 2, 1, 3).reshaped([1, L, heads * headDim]), p + "self_attn.o_proj")
        let r2 = MLXFast.rmsNorm(h, weight: w[p + "post_attention_layernorm.weight"], eps: 1e-6)
        let mlp = silu(w.lin(r2, p + "mlp.gate_proj")) * w.lin(r2, p + "mlp.up_proj")
        h = h + w.lin(mlp, p + "mlp.down_proj")
        return h
    }
}

// MARK: - المحوّل (FLUX.2 Klein 4B، أوزان ثلاثية بـ2 بت)

final class KleinTransformer {
    private let w: KleinWeights
    private let dim = 3072, heads = 24, headDim = 128, mlpHidden = 9216
    private let doubleBlocks = 5, singleBlocks = 20

    init(dir: URL) throws {
        let d = try loadArrays(url: dir.appendingPathComponent("diffusion_pytorch_model.safetensors"))
        guard d["x_embedder.weight"] != nil, d["single_transformer_blocks.19.attn.to_out.scales"] != nil else {
            throw KleinError.missing("transformer")
        }
        w = KleinWeights(d: d, bits: 2, group: 128)
    }

    /// cos/sin لكل موضع: [S, 128]. المواضع: النص (0,0,0,l) ثم الصورة (0,y,x,0)
    /// ثم الصورة المرجعية للتعديل (10,y,x,0) — نفس Flux2KleinPipeline: الزمن T = 10 + 10·i للمرجع رقم i
    static func rope(textLen: Int, h: Int, w: Int, refs: [(h: Int, w: Int)] = []) -> (cos: MLXArray, sin: MLXArray) {
        var ids: [Int32] = []
        ids.reserveCapacity((textLen + h * w + refs.reduce(0) { $0 + $1.h * $1.w }) * 4)
        for l in 0 ..< textLen { ids += [0, 0, 0, Int32(l)] }
        for y in 0 ..< h { for x in 0 ..< w { ids += [0, Int32(y), Int32(x), 0] } }
        for (i, r) in refs.enumerated() {
            let t = Int32(10 + 10 * i)
            for y in 0 ..< r.h { for x in 0 ..< r.w { ids += [t, Int32(y), Int32(x), 0] } }
        }
        let pos = MLXArray(ids).reshaped([-1, 4]).asType(.float32)
        var cs: [MLXArray] = [], ss: [MLXArray] = []
        for a in 0 ..< 4 {
            let axisDim = 32
            let half = MLXArray(stride(from: 0, to: axisDim, by: 2).map { Float($0) / Float(axisDim) })
            let inv = 1 / MLX.pow(MLXArray(Float(2000)), half)                      // [16]
            let f = pos[0..., a].expandedDimensions(axis: 1) * inv.expandedDimensions(axis: 0)  // [S,16]
            // كل تردد يتكرر مرتين (أزواج متجاورة)
            let c = MLX.cos(f).expandedDimensions(axis: -1), s = MLX.sin(f).expandedDimensions(axis: -1)
            cs.append(concatenated([c, c], axis: -1).reshaped([-1, axisDim]))
            ss.append(concatenated([s, s], axis: -1).reshaped([-1, axisDim]))
        }
        return (concatenated(cs, axis: -1), concatenated(ss, axis: -1))
    }

    /// تدوير الأزواج المتجاورة: (a, b) → (a·cos − b·sin, b·cos + a·sin). x: [B, H, S, D]
    private func applyRope(_ x: MLXArray, _ r: (cos: MLXArray, sin: MLXArray)) -> MLXArray {
        let s = x.shape
        let xf = x.asType(.float32)
        let pairs = xf.reshaped([s[0], s[1], s[2], s[3] / 2, 2])
        let a = pairs[.ellipsis, 0], b = pairs[.ellipsis, 1]
        let rotated = stacked([-b, a], axis: -1).reshaped(s)
        return (xf * r.cos + rotated * r.sin).asType(x.dtype)
    }

    private func ln(_ x: MLXArray) -> MLXArray { MLXFast.layerNorm(x, weight: nil, bias: nil, eps: 1e-6) }

    private func modulate(_ x: MLXArray, shift: MLXArray, scale: MLXArray) -> MLXArray {
        ln(x) * (1 + scale.expandedDimensions(axis: 1)) + shift.expandedDimensions(axis: 1)
    }

    /// يقسّم مخرج طبقة التعديل إلى (shift, scale, gate) × عدد المجموعات
    private func modParams(_ temb: MLXArray, _ key: String, sets: Int) -> [(shift: MLXArray, scale: MLXArray, gate: MLXArray)] {
        let m = w.lin(silu(temb), key)
        return (0 ..< sets).map { i in
            let o = i * 3 * dim
            return (shift: m[0..., o ..< (o + dim)], scale: m[0..., (o + dim) ..< (o + 2 * dim)], gate: m[0..., (o + 2 * dim) ..< (o + 3 * dim)])
        }
    }

    private func toHeads(_ x: MLXArray) -> MLXArray {
        x.reshaped([x.dim(0), x.dim(1), heads, headDim]).transposed(0, 2, 1, 3)
    }

    private func merge(_ x: MLXArray) -> MLXArray {
        x.transposed(0, 2, 1, 3).reshaped([x.dim(0), x.dim(2), heads * headDim])
    }

    private func rms(_ x: MLXArray, _ k: String) -> MLXArray { MLXFast.rmsNorm(x, weight: w[k], eps: 1e-6) }

    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray) -> MLXArray {
        MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                          scale: 1 / Float(headDim).squareRoot(), mask: nil)
    }

    /// تضمين الزمن: جيبي 256 (cos أول) ثم طبقتين
    private func timeEmbedding(_ t: Float, dtype: DType) -> MLXArray {
        let half = 128
        let freqs = MLX.exp(MLXArray((0 ..< half).map { -log(Float(10000)) * Float($0) / Float(half) }))
        let a = (t * freqs).reshaped([1, half])
        let emb = concatenated([MLX.cos(a), MLX.sin(a)], axis: -1).asType(dtype)
        let h = silu(w.lin(emb, "time_guidance_embed.timestep_embedder.linear_1"))
        return w.lin(h, "time_guidance_embed.timestep_embedder.linear_2")
    }

    /// x: [1, S_img, 128]، ctx: [1, S_txt, 7680]، sigma من 1 لين 0. يرجع السرعة [1, S_img, 128]
    func callAsFunction(_ x: MLXArray, ctx: MLXArray, sigma: Float, rope: (cos: MLXArray, sin: MLXArray)) -> MLXArray {
        let dt = ctx.dtype
        var img = w.lin(x.asType(dt), "x_embedder")
        var txt = w.lin(ctx, "context_embedder")
        let nTxt = txt.dim(1)
        let temb = timeEmbedding(sigma * 1000, dtype: dt)

        let mi = modParams(temb, "double_stream_modulation_img.linear", sets: 2)
        let mt = modParams(temb, "double_stream_modulation_txt.linear", sets: 2)
        let ropeTxt = (cos: rope.cos[0 ..< nTxt], sin: rope.sin[0 ..< nTxt])
        let ropeImg = (cos: rope.cos[nTxt...], sin: rope.sin[nTxt...])

        for i in 0 ..< doubleBlocks {
            let p = "transformer_blocks.\(i)."
            let ni = modulate(img, shift: mi[0].shift, scale: mi[0].scale)
            let nt = modulate(txt, shift: mt[0].shift, scale: mt[0].scale)
            var q = applyRope(rms(toHeads(w.lin(ni, p + "attn.to_q")), p + "attn.norm_q.weight"), ropeImg)
            var k = applyRope(rms(toHeads(w.lin(ni, p + "attn.to_k")), p + "attn.norm_k.weight"), ropeImg)
            let v = toHeads(w.lin(ni, p + "attn.to_v"))
            let aq = applyRope(rms(toHeads(w.lin(nt, p + "attn.add_q_proj")), p + "attn.norm_added_q.weight"), ropeTxt)
            let ak = applyRope(rms(toHeads(w.lin(nt, p + "attn.add_k_proj")), p + "attn.norm_added_k.weight"), ropeTxt)
            let av = toHeads(w.lin(nt, p + "attn.add_v_proj"))
            q = concatenated([aq, q], axis: 2)
            k = concatenated([ak, k], axis: 2)
            let o = attention(q, k, concatenated([av, v], axis: 2))
            let oTxt = merge(o[0..., 0..., 0 ..< nTxt, 0...])
            let oImg = merge(o[0..., 0..., nTxt..., 0...])
            img = img + mi[0].gate.expandedDimensions(axis: 1) * w.lin(oImg, p + "attn.to_out.0")
            txt = txt + mt[0].gate.expandedDimensions(axis: 1) * w.lin(oTxt, p + "attn.to_add_out")

            let fi = modulate(img, shift: mi[1].shift, scale: mi[1].scale)
            img = img + mi[1].gate.expandedDimensions(axis: 1) * ff(fi, p + "ff")
            let ft = modulate(txt, shift: mt[1].shift, scale: mt[1].scale)
            txt = txt + mt[1].gate.expandedDimensions(axis: 1) * ff(ft, p + "ff_context")
            eval(img, txt)
        }

        var hs = concatenated([txt, img], axis: 1)
        let ms = modParams(temb, "single_stream_modulation.linear", sets: 1)[0]
        for i in 0 ..< singleBlocks {
            let p = "single_transformer_blocks.\(i).attn."
            let n = modulate(hs, shift: ms.shift, scale: ms.scale)
            let proj = w.lin(n, p + "to_qkv_mlp_proj")
            let inner = heads * headDim
            let q = applyRope(rms(toHeads(proj[0..., 0..., 0 ..< inner]), p + "norm_q.weight"), rope)
            let k = applyRope(rms(toHeads(proj[0..., 0..., inner ..< (2 * inner)]), p + "norm_k.weight"), rope)
            let v = toHeads(proj[0..., 0..., (2 * inner) ..< (3 * inner)])
            let gate = proj[0..., 0..., (3 * inner) ..< (3 * inner + mlpHidden)]
            let up = proj[0..., 0..., (3 * inner + mlpHidden)...]
            let attn = merge(attention(q, k, v))
            let out = w.lin(concatenated([attn, silu(gate) * up], axis: -1), p + "to_out")
            hs = hs + ms.gate.expandedDimensions(axis: 1) * out
            if i % 4 == 3 { eval(hs) }
        }

        img = hs[0..., nTxt..., 0...]
        // norm_out: (scale, shift) بهالترتيب
        let m = w.lin(silu(temb), "norm_out.linear")
        let scale = m[0..., 0 ..< dim].expandedDimensions(axis: 1)
        let shift = m[0..., dim...].expandedDimensions(axis: 1)
        img = ln(img) * (1 + scale) + shift
        return w.lin(img, "proj_out").asType(.float32)
    }

    private func ff(_ x: MLXArray, _ p: String) -> MLXArray {
        let h = w.lin(x, p + ".linear_in")
        let gate = h[0..., 0..., 0 ..< mlpHidden]
        let up = h[0..., 0..., mlpHidden...]
        return w.lin(silu(gate) * up, p + ".linear_out")
    }
}

// MARK: - فك الصورة (AutoencoderKLFlux2، المفكك بس، بدقة float32)

/// مفكك AutoencoderKL (نفس البنية في FLUX.1 وFLUX.2). الأوزان بأسماء diffusers وتخطيط MLX للالتفاف.
final class VAEDecoder {
    let w: KleinWeights

    /// pytorchLayout: أوزان الالتفاف [O, I, kh, kw] تنقلب لـ[O, kh, kw, I]. ملفات mflux جاهزة بتخطيط MLX
    /// وبعض أسمائها فيها .conv/.norm زيادة، فنوحّدها.
    init(file: URL, pytorchLayout: Bool) throws {
        let raw = try loadArrays(url: file)
        var d: [String: MLXArray] = [:]
        for (k0, v) in raw {
            if k0.hasPrefix("encoder.") || k0.hasPrefix("quant_conv.") || k0.hasSuffix("num_batches_tracked") { continue }
            let k = k0.replacingOccurrences(of: "decoder.conv_in.conv.", with: "decoder.conv_in.")
                .replacingOccurrences(of: "decoder.conv_out.conv.", with: "decoder.conv_out.")
                .replacingOccurrences(of: "decoder.conv_norm_out.norm.", with: "decoder.conv_norm_out.")
            // الأوزان المكمّمة (طبقة الانتباه في mflux) تبقى زي ما هي
            if v.dtype == .uint32 || k.hasSuffix(".scales") || k.hasSuffix(".biases") { d[k] = v; continue }
            var a = v.asType(.float32)
            if pytorchLayout && a.ndim == 4 { a = a.transposed(0, 2, 3, 1) }
            d[k] = a
        }
        guard d["decoder.conv_out.weight"] != nil, d["decoder.conv_in.weight"] != nil else {
            throw KleinError.missing("vae")
        }
        w = KleinWeights(d: d, bits: 0, group: 0)
    }

    private func conv(_ x: MLXArray, _ k: String, pad: Int = 1) -> MLXArray {
        conv2d(x, w[k + ".weight"], stride: 1, padding: .init(pad)) + w[k + ".bias"]
    }

    private func gn(_ x: MLXArray, _ k: String, groups: Int = 32, eps: Float = 1e-6) -> MLXArray {
        let s = x.shape   // [B, H, W, C]
        let g = x.reshaped([s[0], s[1] * s[2], groups, s[3] / groups])
        let mean = g.mean(axes: [1, 3], keepDims: true)
        let v = g.variance(axes: [1, 3], keepDims: true)
        let n = ((g - mean) * MLX.rsqrt(v + eps)).reshaped(s)
        return n * w[k + ".weight"] + w[k + ".bias"]
    }

    private func resnet(_ x: MLXArray, _ p: String) -> MLXArray {
        var h = conv(silu(gn(x, p + ".norm1")), p + ".conv1")
        h = conv(silu(gn(h, p + ".norm2")), p + ".conv2")
        let skip = w.has(p + ".conv_shortcut.weight") ? conv(x, p + ".conv_shortcut", pad: 0) : x
        return skip + h
    }

    private func midAttention(_ x: MLXArray, _ p: String) -> MLXArray {
        let s = x.shape
        let n = gn(x, p + ".group_norm").reshaped([s[0], s[1] * s[2], s[3]])
        let q = w.lin(n, p + ".to_q").asType(.float32).expandedDimensions(axis: 1)
        let k = w.lin(n, p + ".to_k").asType(.float32).expandedDimensions(axis: 1)
        let v = w.lin(n, p + ".to_v").asType(.float32).expandedDimensions(axis: 1)
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                                  scale: 1 / Float(s[3]).squareRoot(), mask: nil)
        let out = w.lin(o.squeezed(axis: 1), p + ".to_out.0").asType(.float32).reshaped(s)
        return x + out
    }

    private func upsample(_ x: MLXArray) -> MLXArray {
        let s = x.shape
        let e = x.reshaped([s[0], s[1], 1, s[2], 1, s[3]])
        return MLX.broadcast(e, to: [s[0], s[1], 2, s[2], 2, s[3]]).reshaped([s[0], s[1] * 2, s[2] * 2, s[3]])
    }

    /// كامن [1, h, w, C] (NHWC، بعد فك التطبيع) → صورة [1, 8h, 8w, 3] بين −1 و1
    func decode(_ z: MLXArray) -> MLXArray {
        var h = conv(z.asType(.float32), "decoder.conv_in")
        h = resnet(h, "decoder.mid_block.resnets.0")
        h = midAttention(h, "decoder.mid_block.attentions.0")
        h = resnet(h, "decoder.mid_block.resnets.1")
        eval(h)
        for b in 0 ..< 4 {
            for r in 0 ..< 3 { h = resnet(h, "decoder.up_blocks.\(b).resnets.\(r)") }
            if b < 3 { h = conv(upsample(h), "decoder.up_blocks.\(b).upsamplers.0.conv") }
            eval(h)
        }
        h = conv(silu(gn(h, "decoder.conv_norm_out")), "decoder.conv_out")
        return h
    }
}

/// FLUX.2: BatchNorm + فك الترقيع + post_quant_conv قبل المفكك
final class KleinVAE {
    private let dec: VAEDecoder
    private let bnMean: MLXArray, bnVar: MLXArray

    init(dir: URL) throws {
        dec = try VAEDecoder(file: dir.appendingPathComponent("diffusion_pytorch_model.safetensors"), pytorchLayout: true)
        guard let m = dec.w.d["bn.running_mean"], let v = dec.w.d["bn.running_var"],
              dec.w.has("post_quant_conv.weight") else { throw KleinError.missing("vae") }
        bnMean = m
        bnVar = v
    }

    /// صورة [1, H, W, 3] → كامن مرقّع ومطبّع [1, H/16, W/16, 128] (نفس _encode_vae_image في diffusers)
    static func encode(_ px: MLXArray, dir: URL) throws -> MLXArray {
        let file = dir.appendingPathComponent("diffusion_pytorch_model.safetensors")
        let enc = try VAEEncoder(file: file, pytorchLayout: true)
        let z = enc.encode(px)   // [1, H/8, W/8, 32]
        let s = z.shape
        // ترقيع 2×2: القناة = c·4 + p1·2 + p2 (عكس decode)
        let p = z.reshaped([s[0], s[1] / 2, 2, s[2] / 2, 2, s[3]]).transposed(0, 1, 3, 5, 2, 4)
            .reshaped([s[0], s[1] / 2, s[2] / 2, s[3] * 4])
        let bn = try loadArrays(url: file)
        guard let m = bn["bn.running_mean"], let v = bn["bn.running_var"] else { throw KleinError.missing("vae") }
        let out = (p - m.asType(.float32)) / MLX.sqrt(v.asType(.float32) + 1e-4)
        eval(out)
        return out
    }

    /// الكامن المرقّع [1, h, w, 128] → صورة [1, 16h, 16w, 3]
    func decode(_ patchified: MLXArray) -> MLXArray {
        let s = patchified.shape
        var z = patchified.asType(.float32) * MLX.sqrt(bnVar + 1e-4) + bnMean
        // نفك الترقيع: القناة = c·4 + p1·2 + p2
        z = z.reshaped([s[0], s[1], s[2], 32, 2, 2]).transposed(0, 1, 4, 2, 5, 3)
            .reshaped([s[0], s[1] * 2, s[2] * 2, 32])
        z = conv2d(z, dec.w["post_quant_conv.weight"], stride: 1, padding: 0) + dec.w["post_quant_conv.bias"]
        return dec.decode(z)
    }
}

// MARK: - التوليد كامل

enum KleinPipeline {
    /// sigmas بعد الإزاحة الديناميكية (نفس diffusers: mu تجريبي حسب طول التسلسل وعدد الخطوات)
    static func sigmas(steps: Int, seqLen: Int) -> [Float] {
        let a1: Float = 8.73809524e-05, b1: Float = 1.89833333
        let a2: Float = 0.00016927, b2: Float = 0.45666666
        let mu: Float
        if seqLen > 4300 {
            mu = a2 * Float(seqLen) + b2
        } else {
            let m200 = a2 * Float(seqLen) + b2
            let m10 = a1 * Float(seqLen) + b1
            let a = (m200 - m10) / 190
            mu = a * Float(steps) + (m200 - 200 * a)
        }
        var out: [Float] = (0 ..< steps).map { i in
            let t = 1 - Float(i) / Float(steps)
            return exp(mu) / (exp(mu) + (1 / t - 1))
        }
        out.append(0)
        return out
    }

    /// يرسم صورة. status للنص، step(k, n) للتقدم. يفك كل جزء من الذاكرة بعد ما يخلص.
    /// source: صورة للتعديل (وصف + صورة): تدخل كصورة مرجعية بجنب الكامن، والناتج بنفس أبعادها (≤ 512²)
    /// plan: أدوات العارض — قناع (يتولّد داخله بس والباقي يرجع من الأصل كل خطوة)، تغيير حجم، وصورة العلامات كمرجع ثاني.
    static func generate(dir: URL, prompt: String, seed: UInt64, source: URL? = nil, plan: EditPlan? = nil,
                         onPhase: @escaping (String) -> Void,
                         onStep: @escaping (Int, Int) -> Void) async throws -> CGImage {
        var lh = Klein.size / 16, lw = Klein.size / 16

        // ٠) الصور المرجعية للتعديل: نرمّزها أول، قبل ما نحمّل الأشياء الثقيلة
        var refTokens: MLXArray?
        var refDims: [(h: Int, w: Int)] = []
        var edit: EditInputs?
        var known: MLXArray?      // كامن الأجزاء المعروفة (للقناع)
        var tokMask: MLXArray?
        if let source {
            onPhase("source")
            let e = try EditInputs.prepare(source: source, plan: plan)
            edit = e
            lh = e.h / 16; lw = e.w / 16
            let vdir = dir.appendingPathComponent("vae")
            var refs = [try KleinVAE.encode(e.ref, dir: vdir).reshaped([1, (e.refH / 16) * (e.refW / 16), 128])]
            refDims = [(e.refH / 16, e.refW / 16)]
            if let r2 = e.ref2 {
                refs.append(try KleinVAE.encode(r2, dir: vdir).reshaped([1, (e.refH / 16) * (e.refW / 16), 128]))
                refDims.append((e.refH / 16, e.refW / 16))
            }
            refTokens = concatenated(refs, axis: 1)
            if let m = e.tokenMask(cell: 16) {
                tokMask = m
                // نفس الأبعاد = القماش هو المرجع نفسه، فما نرمّزه مرتين
                known = e.w == e.refW && e.h == e.refH
                    ? refs[0] : try KleinVAE.encode(e.canvas, dir: vdir).reshaped([1, lh * lw, 128])
                eval(known!, m)
            }
            eval(refTokens!)
            MLX.Memory.clearCache()
            slog("klein: edit \(plan?.kind.rawValue ?? "instruct") \(e.w)x\(e.h) refs=\(refDims.count) mask=\(tokMask != nil) footprint=\(RAM.footprintMB)MB")
            try Task.checkCancellation()
        }

        // ١) النص
        onPhase("encode")
        var ctx: MLXArray
        do {
            let enc = try await QwenTextEncoder(dir: QwenShared.dir, keep: Klein.hiddenLayers.max() ?? 27)
            ctx = enc.encodeKlein(prompt)
        }
        MLX.Memory.clearCache()
        slog("klein: text encoded \(ctx.shape) footprint=\(RAM.footprintMB)MB")
        try Task.checkCancellation()

        // ٢) إزالة الضجيج
        onPhase("load")
        let noise = MLXRandom.normal([1, lh * lw, 128], key: MLXRandom.key(seed))
        var latents = noise
        do {
            let tr = try KleinTransformer(dir: dir.appendingPathComponent("transformer-packed-mflux"))
            let rope = KleinTransformer.rope(textLen: ctx.dim(1), h: lh, w: lw, refs: refDims)
            // mu من طول تسلسل الناتج بس (بدون المرجع)، مثل diffusers
            let sig = sigmas(steps: Klein.steps, seqLen: lh * lw)
            onStep(0, Klein.steps)
            for i in 0 ..< Klein.steps {
                try Task.checkCancellation()
                var v: MLXArray
                if let refTokens {
                    // [الكامن ‖ المرجع] بنفس الزمن، وناخذ مخرج الكامن بس
                    let both = concatenated([latents, refTokens.asType(latents.dtype)], axis: 1)
                    v = tr(both, ctx: ctx, sigma: sig[i], rope: rope)
                    v = v[0..., 0 ..< (lh * lw), 0...]
                } else {
                    v = tr(latents, ctx: ctx, sigma: sig[i], rope: rope)
                }
                latents = latents + (sig[i + 1] - sig[i]) * v
                if let known, let tokMask {
                    // خارج القناع: نرجع الأصل مخلوط بنفس الضجيج عند sigma التالية (blended latent / RePaint)
                    let s = sig[i + 1]
                    let k = (1 - s) * known.asType(latents.dtype) + s * noise.asType(latents.dtype)
                    latents = tokMask * latents + (1 - tokMask) * k
                }
                eval(latents)
                onStep(i + 1, Klein.steps)
            }
        }
        ctx = MLXArray(0)
        refTokens = nil
        known = nil
        MLX.Memory.clearCache()
        slog("klein: denoised footprint=\(RAM.footprintMB)MB")

        // ٣) فك الصورة
        onPhase("decode")
        let pixels: MLXArray
        do {
            let vae = try KleinVAE(dir: dir.appendingPathComponent("vae"))
            let raw = vae.decode(latents.reshaped([1, lh, lw, 128]))
            pixels = edit?.composite(raw) ?? raw
            eval(pixels)
        }
        defer { MLX.Memory.clearCache() }
        return try toImage(pixels)
    }

    static func toImage(_ px: MLXArray) throws -> CGImage {
        let s = px.shape   // [1, H, W, 3]
        let rgb = MLX.clip((px[0] + 1) * 127.5, min: 0, max: 255).asType(.uint8)
        let alpha = MLXArray.full([s[1], s[2], 1], values: MLXArray(UInt8(255)), type: UInt8.self)
        let rgba = concatenated([rgb, alpha], axis: -1)
        let bytes = rgba.asArray(UInt8.self)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: s[2], height: s[1], bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s[2] * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SawtError.failed("ما قدرت أحوّل الصورة")
        }
        return img
    }
}
