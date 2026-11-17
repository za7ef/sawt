import Foundation
import CoreGraphics
import UIKit

// MARK: - التعديل يلمس اللي طلبته بس، والباقي يبقى الأصل بدقته الكاملة

/// النموذج يعدّل على 512² ويعيد رسم الصورة كلها (حتى «دقيق» يغيّر الكتابة والتفاصيل شوي).
/// الحل: نقارن الناتج بالأصل ونطلع «قناع التغيير» (وين تغيّر فعلًا بشكل واضح)، ثم نلصق المنطقة المتغيّرة بس
/// فوق الصورة الأصلية بدقتها الكاملة. خارج القناع = بكسل الأصل نفسه.
enum AutoMask {
    struct Result { let image: CGImage; let coverage: Double }

    /// قناع التغيير بأبعاد الناتج (w×h) — nil لو التغيير عام على الصورة كلها أو ما فيه تغيير واضح
    static func changeMask(original o: [UInt8], edited e: [UInt8], w: Int, h: Int) -> (mask: [UInt8], coverage: Double)? {
        let n = w * h
        // ١) فرق إدراكي بسيط: الإضاءة بوزن أقل، واللون (أحمر-أخضر / أزرق-أصفر) بوزن أكبر
        var d = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let r1 = Float(o[i * 4]), g1 = Float(o[i * 4 + 1]), b1 = Float(o[i * 4 + 2])
            let r2 = Float(e[i * 4]), g2 = Float(e[i * 4 + 1]), b2 = Float(e[i * 4 + 2])
            let dl = ((r2 + g2 + b2) - (r1 + g1 + b1)) / 3
            let da = (r2 - g2) - (r1 - g1)
            let db = ((r2 + g2) / 2 - b2) - ((r1 + g1) / 2 - b1)
            d[i] = (0.5 * dl * dl + da * da + db * db).squareRoot() / 255
        }
        // ٢) تنعيم: يلغي فروق الملمس الصغيرة (إعادة الرسم تغيّر الحبيبات والحروف بشكل متناثر)
        d = boxBlur(d, w: w, h: h, r: 4)
        d = boxBlur(d, w: w, h: h, r: 4)
        // ٣) عتبة أوتسو (تفصل «تغيّر مقصود» عن «انحراف إعادة الرسم»)، بحد أدنى
        let t = max(0.10, otsu(d))
        var bin = [UInt8](repeating: 0, count: n)
        for i in 0 ..< n where d[i] > t { bin[i] = 1 }
        // ٤) نخلي القطع المهمة بس: «وزن» القطعة = مساحتها × متوسط فرقها.
        //    المطلوب (الدب صار أحمر) فرقه قوي ومساحته كبيرة؛ انحراف إعادة الرسم (بالونات، حروف) أضعف أو أصغر.
        let (labels, areas) = components(bin, w: w, h: h)
        guard !areas.isEmpty else { return nil }
        var sums = [Double](repeating: 0, count: areas.count)
        for i in 0 ..< n where labels[i] != 0 { sums[labels[i] - 1] += Double(d[i]) }
        let means = zip(sums, areas).map { $0 / Double(max($1, 1)) }
        let weights = zip(means, areas).map { $0 * Double($1) }
        guard let top = weights.indices.max(by: { weights[$0] < weights[$1] }) else { return nil }
        let minArea = Int(Double(n) * 0.004)
        var keep = Set<Int>()
        for k in areas.indices where areas[k] >= minArea && weights[k] >= weights[top] * 0.3 && means[k] >= means[top] * 0.6 {
            keep.insert(k + 1)
        }
        keep.insert(top + 1)
        var kept = 0
        for i in 0 ..< n { if labels[i] != 0, keep.contains(labels[i]) { bin[i] = 255; kept += 1 } else { bin[i] = 0 } }
        let coverage = Double(kept) / Double(n)
        slog("automask: otsu=\(String(format: "%.3f", t)) parts=\(keep.count)/\(areas.count) coverage=\(String(format: "%.1f", coverage * 100))%")
        // تغيير على أغلب الصورة (ستايل، إضاءة، خلفية كاملة) = تعديل عام: ناخذ الناتج كامل
        if coverage > 0.55 || coverage < 0.002 { return nil }
        // ٥) توسيع وتليين الحواف عشان الدمج ما يبان
        let soft = Mask.soften(bin, w: w, h: h, grow: 8, feather: 6)
        return (soft, coverage)
    }

    /// يلصق الناتج (w×h) فوق الأصل بدقته الكاملة عبر القناع (w×h). نفس القص من الوسط اللي استخدمه التعديل.
    static func composite(original: CGImage, edited: CGImage, mask: [UInt8], w: Int, h: Int) throws -> CGImage {
        let W = original.width, H = original.height
        // مكان الناتج على الأصل: عكس fillRect (الأصل انرسم على w×h بتعبئة وقص من الوسط)
        let fr = EditImage.fillRect(original, w: w, h: h)
        let sc = fr.width / Double(W)
        let dst = CGRect(x: -fr.minX / sc, y: -fr.minY / sc, width: Double(w) / sc, height: Double(h) / sc)

        let base = try EditImage.rgba(original, w: W, h: H)
        var top = [UInt8](repeating: 0, count: W * H * 4)
        var m = [UInt8](repeating: 0, count: W * H)
        let ok1: Bool = top.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(edited, in: dst)
            return true
        }
        guard ok1, let maskImg = grayImage(mask, w: w, h: h) else { throw SawtError.failed(L("تعذّر دمج التعديل")) }
        let ok2: Bool = m.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(maskImg, in: dst)
            return true
        }
        guard ok2 else { throw SawtError.failed(L("تعذّر دمج التعديل")) }
        var out = base
        for i in 0 ..< W * H {
            let a = Int(m[i])
            if a == 0 { continue }
            for c in 0 ..< 3 {
                let j = i * 4 + c
                out[j] = UInt8((Int(top[j]) * a + Int(base[j]) * (255 - a) + 127) / 255)
            }
        }
        guard let img = rgbImage(out, w: W, h: H) else { throw SawtError.failed(L("تعذّر دمج التعديل")) }
        return img
    }

    // MARK: أدوات

    static func boxBlur(_ a: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: a.count), out = tmp
        for y in 0 ..< h {
            var s: Float = 0; var cnt = 0
            for x in 0 ... min(r, w - 1) { s += a[y * w + x]; cnt += 1 }
            for x in 0 ..< w {
                tmp[y * w + x] = s / Float(cnt)
                let add = x + r + 1, sub = x - r
                if add < w { s += a[y * w + add]; cnt += 1 }
                if sub >= 0 { s -= a[y * w + sub]; cnt -= 1 }
            }
        }
        for x in 0 ..< w {
            var s: Float = 0; var cnt = 0
            for y in 0 ... min(r, h - 1) { s += tmp[y * w + x]; cnt += 1 }
            for y in 0 ..< h {
                out[y * w + x] = s / Float(cnt)
                let add = y + r + 1, sub = y - r
                if add < h { s += tmp[add * w + x]; cnt += 1 }
                if sub >= 0 { s -= tmp[sub * w + x]; cnt -= 1 }
            }
        }
        return out
    }

    /// عتبة أوتسو على قيم بين 0 و1 (256 خانة)
    static func otsu(_ a: [Float]) -> Float {
        var hist = [Double](repeating: 0, count: 256)
        for v in a { hist[min(255, max(0, Int(v * 255)))] += 1 }
        let total = Double(a.count)
        var sumAll = 0.0
        for i in 0 ..< 256 { sumAll += Double(i) * hist[i] }
        var wB = 0.0, sumB = 0.0, best = 0.0, th = 0
        for i in 0 ..< 256 {
            wB += hist[i]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(i) * hist[i]
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let v = wB * wF * (mB - mF) * (mB - mF)
            if v > best { best = v; th = i }
        }
        return Float(th) / 255
    }

    /// تسمية القطع المتصلة (٤ جيران) → (تسميات من 1، مساحة كل قطعة)
    static func components(_ bin: [UInt8], w: Int, h: Int) -> ([Int], [Int]) {
        var labels = [Int](repeating: 0, count: bin.count)
        var areas: [Int] = []
        var stack: [Int] = []
        for s in 0 ..< bin.count where bin[s] != 0 && labels[s] == 0 {
            let id = areas.count + 1
            var area = 0
            labels[s] = id; stack.append(s)
            while let p = stack.popLast() {
                area += 1
                let x = p % w, y = p / w
                if x > 0, bin[p - 1] != 0, labels[p - 1] == 0 { labels[p - 1] = id; stack.append(p - 1) }
                if x < w - 1, bin[p + 1] != 0, labels[p + 1] == 0 { labels[p + 1] = id; stack.append(p + 1) }
                if y > 0, bin[p - w] != 0, labels[p - w] == 0 { labels[p - w] = id; stack.append(p - w) }
                if y < h - 1, bin[p + w] != 0, labels[p + w] == 0 { labels[p + w] = id; stack.append(p + w) }
            }
            areas.append(area)
        }
        return (labels, areas)
    }

    static func grayImage(_ g: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let p = CGDataProvider(data: Data(g) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func rgbImage(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
