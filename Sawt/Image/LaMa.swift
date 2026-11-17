import Foundation
import CoreML
import Vision
import CoreImage
import UIKit

// MARK: - LaMa (إزالة الأشياء) — Core ML على الجهاز

/// LaMa (advimman/lama، Apache-2.0) بتحويل Core ML من mlboydaisuke/LaMa-CoreML (Apache-2.0)، دخل 800×800.
/// جزء من «دقيق»: ينزل معه في مجلده وينحذف معه. الإزالة في «دقيق» تمر عليه بدل الانتشار (أسرع وأنظف للإزالة).
enum LaMa {
    /// نسخة ثابتة من المستودع
    static let revision = "5ed76e3799ab4cad31381750d29880c267477e18"
    static let base = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/\(revision)/"
    static let files: [(path: String, mb: Double, bytes: Int64)] = [
        ("LaMa.mlpackage/Manifest.json", 0.01, 617),
        ("LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel", 1.1, 1_101_809),
        ("LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 215.5, 215_544_960),
    ]
    static let side = 800

    static var dir: URL { SDModels.dir(.klein).appendingPathComponent("lama", isDirectory: true) }
    private static var compiledURL: URL { dir.appendingPathComponent("LaMa.mlmodelc", isDirectory: true) }

    /// كل الملفات موجودة وبأحجامها الصحيحة
    static var installed: Bool {
        files.allSatisfy { f in
            let p = dir.appendingPathComponent(f.path).path
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? -1
            return size == f.bytes
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MLModel?

    /// يحمّل النموذج (يجمّعه أول مرة ويحفظ النسخة المجمّعة جنبه)
    static func model() async throws -> MLModel {
        lock.lock(); let c = cached; lock.unlock()
        if let c { return c }
        guard installed else { throw SawtError.notReady(L("أداة الإزالة")) }
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            let tmp = try await MLModel.compileModel(at: dir.appendingPathComponent("LaMa.mlpackage"))
            try? FileManager.default.removeItem(at: compiledURL)
            try FileManager.default.moveItem(at: tmp, to: compiledURL)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all   // نفس الإعداد اللي اتحقق منه المحوّل
        let m = try MLModel(contentsOf: compiledURL, configuration: cfg)
        lock.lock(); cached = m; lock.unlock()
        return m
    }

    static func unload() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// يمسح المنطقة البيضاء في القناع ويعبّيها. الناتج بدقة الصورة الأصلية، وخارج القناع يبقى مثل ما هو بالبكسل.
    static func inpaint(source: URL, mask maskURL: URL) async throws -> CGImage {
        let cg = try EditImage.upright(source)
        let w = cg.width, h = cg.height
        let model = try await model()
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let ic = inputs["image"]?.imageConstraint, let mc = inputs["mask"]?.imageConstraint else {
            throw SawtError.failed(L("نموذج الإزالة لا يحتوي على المدخلات المتوقعة"))
        }
        // القناع بأبعاد الصورة: نوسّعه شوي (حواف الشي وظله) ونليّنه للدمج
        let soft = try Mask.load(maskURL, w: w, h: h, grow: 8, feather: 4)
        let hard = soft.map { $0 > 8 ? UInt8(255) : UInt8(0) }
        guard let maskCG = gray(hard, w: w, h: h), let softCG = gray(soft, w: w, h: h) else {
            throw SawtError.failed(L("تعذّر تجهيز القناع"))
        }
        // Core ML يصغّر الصورة والقناع لـ800×800 بنفسه حسب القيود
        let opts: [MLFeatureValue.ImageOption: Any] = [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        let img = try MLFeatureValue(cgImage: cg, constraint: ic, options: opts)
        let msk = try MLFeatureValue(cgImage: maskCG, constraint: mc, options: opts)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk])
        let out = try await model.prediction(from: input)
        guard let buf = out.featureValue(for: "output")?.imageBufferValue else {
            throw SawtError.failed(L("لم يُرجع نموذج الإزالة صورة"))
        }
        // نكبّر الناتج لحجم الأصل وندمجه بالقناع الناعم فوق الأصل
        var res = CIImage(cvPixelBuffer: buf)
        res = res.transformed(by: CGAffineTransform(scaleX: Double(w) / res.extent.width, y: Double(h) / res.extent.height))
        let blended = res.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: cg),
            kCIInputMaskImageKey: CIImage(cgImage: softCG),
        ])
        guard let final = Mask.ci.createCGImage(blended, from: CGRect(x: 0, y: 0, width: w, height: h)) else {
            throw SawtError.failed(L("تعذّر دمج الناتج"))
        }
        return final
    }

    private static func gray(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
