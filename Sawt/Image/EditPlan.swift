import Foundation
import CoreGraphics
import CoreImage
import UIKit
import MLX

// MARK: - خطة التعديل من عارض الصور

/// وش يبي المستخدم من الصورة: تعليمة (مع ملاحظات على نقاط)، تغيير حجم، علامات توضيحية، أو إزالة منطقة.
/// القناع صورة رمادية بنسبة الصورة الأصلية: الأبيض = المنطقة اللي تتغيّر، والباقي يبقى مثل ما هو بالبكسل.
struct EditPlan: Sendable {
    enum Kind: String, Sendable { case instruct, resize, markup, remove }
    var kind: Kind = .instruct
    /// قناع PNG (أبيض = يتغيّر). بدون قناع = تعديل عام على الصورة كلها
    var mask: URL?
    /// الصورة مع العلامات المرسومة (للعلامات التوضيحية)
    var annotated: URL?
    /// النسبة الجديدة لتغيير الحجم (مثلًا 16:9)
    var aspectW = 0
    var aspectH = 0
    /// وصف الصورة الأصلي لو كانت مرسومة (يفيد «واقعي+» في التكملة)
    var basePrompt: String?
}

/// مدخلات جاهزة للمحرك (تنبني داخل خط الرسم لأن MLXArray مو Sendable)
struct EditInputs {
    /// أبعاد الناتج
    let w: Int, h: Int
    /// نقطة البداية والجزء المعروف [1, h, w, 3] بين −1 و1
    let canvas: MLXArray
    /// الصورة المرجعية بأبعادها (تختلف عن الناتج في تغيير الحجم)
    let ref: MLXArray
    let refW: Int, refH: Int
    /// الصورة مع العلامات، بأبعاد المرجع
    let ref2: MLXArray?
    /// قناع ناعم [1, h, w, 1] (1 = يتولّد). nil = الصورة كلها
    let mask: MLXArray?

    /// القناع على مستوى رقع الكامن: [1, (h/cell)·(w/cell), 1]. أي رقعة يلمسها القناع تتولّد
    func tokenMask(cell: Int) -> MLXArray? {
        guard let mask else { return nil }
        let m = mask.reshaped([1, h / cell, cell, w / cell, cell]).max(axes: [2, 4])
        return (m .> 0.02).asType(.float32).reshaped([1, (h / cell) * (w / cell), 1])
    }

    /// يدمج الناتج بالبكسل: خارج القناع يرجع الأصل بالضبط، وحدوده ناعمة
    func composite(_ px: MLXArray) -> MLXArray {
        guard let mask else { return px }
        return mask * px + (1 - mask) * canvas
    }

    static func prepare(source: URL, plan: EditPlan?) throws -> EditInputs {
        let cg = try EditImage.upright(source)
        let (rw, rh) = EditImage.size(for: cg)
        let ref = EditImage.pixels(try EditImage.rgba(cg, w: rw, h: rh), w: rw, h: rh)
        var ref2: MLXArray?
        if let a = plan?.annotated {
            let acg = try EditImage.upright(a)
            ref2 = EditImage.pixels(try EditImage.rgba(acg, w: rw, h: rh), w: rw, h: rh)
        }

        if let plan, plan.kind == .resize, plan.aspectW > 0, plan.aspectH > 0 {
            let (w, h) = EditImage.size(aspectW: Double(plan.aspectW), h: Double(plan.aspectH))
            let r = Resize.canvas(cg, w: w, h: h)
            return EditInputs(w: w, h: h, canvas: EditImage.pixels(r.rgba, w: w, h: h), ref: ref, refW: rw, refH: rh,
                              ref2: nil, mask: Mask.array(r.mask, w: w, h: h))
        }

        var mask: MLXArray?
        if let m = plan?.mask {
            // الإزالة تحتاج هامش أوسع (ظل الشي وحوافه)، والملاحظات والعلامات أقل
            let grow = plan?.kind == .remove ? 10.0 : 6.0
            mask = Mask.array(try Mask.load(m, w: rw, h: rh, grow: grow, feather: 6), w: rw, h: rh)
        }
        return EditInputs(w: rw, h: rh, canvas: ref, ref: ref, refW: rw, refH: rh, ref2: ref2, mask: mask)
    }
}

// MARK: - الأقنعة

enum Mask {
    static let ci = CIContext(options: [.cacheIntermediates: false])

    /// يقرأ القناع بنفس قص الصورة، يوسّعه ويليّن حدوده → بايتات رمادية w×h
    static func load(_ url: URL, w: Int, h: Int, grow: Double, feather: Double) throws -> [UInt8] {
        guard let ui = UIImage(contentsOfFile: url.path), let cg = ui.cgImage else { throw SawtError.failed("ما قدرت أقرأ القناع") }
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: EditImage.fillRect(cg, w: w, h: h))
            return true
        }
        guard ok else { throw SawtError.failed("ما قدرت أجهّز القناع") }
        return soften(gray, w: w, h: h, grow: grow, feather: feather)
    }

    /// توسيع (أقصى قيمة بالجوار) ثم تنعيم غاوسي، بـCore Image
    static func soften(_ gray: [UInt8], w: Int, h: Int, grow: Double, feather: Double) -> [UInt8] {
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return gray }
        var img = CIImage(cgImage: cg).clampedToExtent()
        if grow > 0 { img = img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]) }
        if feather > 0 { img = img.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]) }
        img = img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { buf in
            ci.render(img, toBitmap: buf.baseAddress!, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return out
    }

    /// بايتات رمادية → [1, h, w, 1] بين 0 و1
    static func array(_ gray: [UInt8], w: Int, h: Int) -> MLXArray {
        MLXArray(gray, [1, h, w, 1]).asType(.float32) / 255
    }

    /// هل القناع فيه شي مرسوم؟
    static func isEmpty(_ url: URL) -> Bool {
        guard let ui = UIImage(contentsOfFile: url.path), let cg = ui.cgImage else { return true }
        var px = [UInt8](repeating: 0, count: 64 * 64)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return !px.contains { $0 > 20 }
    }
}

// MARK: - تغيير الحجم (تكملة الأطراف)

enum Resize {
    /// القماش الجديد: الصورة الأصلية بالوسط بحجمها كامل (احتواء)، والأطراف الجديدة معبّأة بنسخة مموّهة منها
    /// كبداية قريبة الألوان. القناع = الأطراف + شريط ٨ بكسل داخل الصورة عشان الحد يذوب.
    static func canvas(_ cg: CGImage, w: Int, h: Int) -> (rgba: [UInt8], mask: [UInt8]) {
        let fit = min(Double(w) / Double(cg.width), Double(h) / Double(cg.height))
        let dw = Double(cg.width) * fit, dh = Double(cg.height) * fit
        let inner = CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh)

        // خلفية مموّهة بتعبئة كاملة
        var bg = CIImage(cgImage: cg)
        let fill = EditImage.fillRect(cg, w: w, h: h)
        bg = bg.transformed(by: CGAffineTransform(scaleX: fill.width / Double(cg.width), y: fill.height / Double(cg.height))
            .concatenating(CGAffineTransform(translationX: fill.minX, y: fill.minY)))
        bg = bg.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let blurred = Mask.ci.createCGImage(bg, from: CGRect(x: 0, y: 0, width: w, height: h))

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            if let blurred { ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            ctx.draw(cg, in: inner)
        }

        var gray = [UInt8](repeating: 255, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(inner.insetBy(dx: 8, dy: 8))
        }
        // الصورة تعبّي القماش تقريبًا (نفس النسبة): ما فيه أطراف جديدة
        return (rgba, Mask.soften(gray, w: w, h: h, grow: 0, feather: 5))
    }
}
