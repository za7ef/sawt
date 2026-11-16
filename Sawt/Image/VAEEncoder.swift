import Foundation
import CoreGraphics
import UIKit
import MLX
import MLXNN

// MARK: - مرمّز VAE (AutoencoderKL، نفس البنية في FLUX.1 وFLUX.2) لتعديل الصور

/// مرمّز AutoencoderKL مشترك بين «دقيق» (FLUX.2، 32 قناة + quant_conv) و«واقعي+» (Z-Image/FLUX.1، 16 قناة).
/// الأوزان من نفس ملف VAE اللي ينزل مع كل محرك (فيه المرمّز والمفكك)، فما يحتاج تنزيل زيادة.
/// يرجع متوسط التوزيع الكامن (وضع argmax في diffusers) بتخطيط NHWC.
final class VAEEncoder {
    private let w: KleinWeights

    /// pytorchLayout: أوزان الالتفاف [O, I, kh, kw] تنقلب لـ[O, kh, kw, I]. ملفات mflux جاهزة بتخطيط MLX
    /// وأسماء بعض طبقاتها فيها .conv2d/.norm زيادة، فنوحّدها لأسماء diffusers.
    init(file: URL, pytorchLayout: Bool) throws {
        let raw = try loadArrays(url: file)
        var d: [String: MLXArray] = [:]
        for (k0, v) in raw {
            guard k0.hasPrefix("encoder.") || k0.hasPrefix("quant_conv.") else { continue }
            let k = k0.replacingOccurrences(of: ".conv2d.", with: ".")
                .replacingOccurrences(of: "encoder.conv_norm_out.norm.", with: "encoder.conv_norm_out.")
            if v.dtype == .uint32 || k.hasSuffix(".scales") || k.hasSuffix(".biases") { d[k] = v; continue }
            var a = v.asType(.float32)
            if pytorchLayout && a.ndim == 4 { a = a.transposed(0, 2, 3, 1) }
            d[k] = a
        }
        guard d["encoder.conv_in.weight"] != nil, d["encoder.conv_out.weight"] != nil,
              d["encoder.mid_block.attentions.0.to_q.weight"] != nil else {
            throw SawtError.failed("ملف VAE ما فيه المرمّز")
        }
        w = KleinWeights(d: d, bits: 0, group: 0)
    }

    private func conv(_ x: MLXArray, _ k: String, pad: Int = 1, stride: Int = 1) -> MLXArray {
        conv2d(x, w[k + ".weight"], stride: .init(stride), padding: .init(pad)) + w[k + ".bias"]
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

    /// صورة [1, H, W, 3] بين −1 و1 → متوسط الكامن [1, H/8, W/8, C]
    func encode(_ px: MLXArray) -> MLXArray {
        var h = conv(px.asType(.float32), "encoder.conv_in")
        for b in 0 ..< 4 {
            for r in 0 ..< 2 { h = resnet(h, "encoder.down_blocks.\(b).resnets.\(r)") }
            if b < 3 {
                // Downsample2D في diffusers: حشو صفري يمين وتحت بس، ثم التفاف بخطوة 2 بدون حشو
                h = MLX.padded(h, widths: [.init((0, 0)), .init((0, 1)), .init((0, 1)), .init((0, 0))])
                h = conv(h, "encoder.down_blocks.\(b).downsamplers.0.conv", pad: 0, stride: 2)
            }
            eval(h)
        }
        h = resnet(h, "encoder.mid_block.resnets.0")
        h = midAttention(h, "encoder.mid_block.attentions.0")
        h = resnet(h, "encoder.mid_block.resnets.1")
        h = conv(silu(gn(h, "encoder.conv_norm_out")), "encoder.conv_out")
        if w.has("quant_conv.weight") {
            h = conv2d(h, w["quant_conv.weight"], stride: 1, padding: 0) + w["quant_conv.bias"]
        }
        // النصف الأول = المتوسط، والثاني = لوغاريتم التباين (ما نحتاجه)
        let c = h.dim(3) / 2
        let mean = h[.ellipsis, 0 ..< c]
        eval(mean)
        return mean
    }
}

// MARK: - تجهيز صورة المستخدم

enum EditImage {
    /// أكبر مساحة للتعديل على الجوال: 512×512 (التسلسل يتضاعف مع الصورة المرجعية)
    static let maxArea = 512 * 512

    /// أبعاد الناتج: نفس نسبة الصورة بمساحة ≤ 512² ومضاعفات 16 (أصغر ضلع 256)
    static func size(for img: CGImage) -> (w: Int, h: Int) {
        let w0 = Double(img.width), h0 = Double(img.height)
        let s = min(1, (Double(maxArea) / (w0 * h0)).squareRoot())
        func snap(_ v: Double) -> Int { max(256, Int(v * s / 16) * 16) }
        var w = snap(w0), h = snap(h0)
        while w * h > maxArea { if w >= h { w -= 16 } else { h -= 16 } }
        return (w, h)
    }

    /// يقرأ الصورة (مع اتجاهها) ويقصّها من الوسط على الأبعاد → [1, H, W, 3] بين −1 و1
    static func load(_ url: URL) throws -> (pixels: MLXArray, w: Int, h: Int) {
        guard let ui = UIImage(contentsOfFile: url.path) else { throw SawtError.failed("ما قدرت أقرأ الصورة") }
        // نرسمها مرة بالاتجاه الصحيح (صور الكاميرا مخزنة مدوّرة)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let upright = UIGraphicsImageRenderer(size: ui.size, format: fmt).image { _ in ui.draw(at: .zero) }
        guard let cg = upright.cgImage else { throw SawtError.failed("ما قدرت أقرأ الصورة") }
        let (w, h) = size(for: cg)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SawtError.failed("ما قدرت أجهّز الصورة")
        }
        ctx.interpolationQuality = .high
        // تعبئة مع قص من الوسط (نفس resize_mode="crop" تقريبًا)
        let sc = max(Double(w) / Double(cg.width), Double(h) / Double(cg.height))
        let dw = Double(cg.width) * sc, dh = Double(cg.height) * sc
        ctx.draw(cg, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
        let rgba = MLXArray(bytes, [1, h, w, 4])
        let px = rgba[.ellipsis, 0 ..< 3].asType(.float32) / 127.5 - 1
        return (px, w, h)
    }
}
