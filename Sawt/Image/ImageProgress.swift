import SwiftUI
import CoreGraphics
import CoreML

/// صورة معاينة تنتقل من خيط الرسم للواجهة
final class PreviewBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// مرحلة الرسم الحالية
enum GenPhase: Sendable, Equatable {
    case prompt                 // نموذج المحادثة يكتب البرومبت
    case loading                // تحميل نموذج الصور
    case drawing(Int, Int)      // خطوة / عدد الخطوات (Stable Diffusion)
    case waiting                // محرك ما يعطي تقدم (Image Playground وGemini)
    case decoding               // فك الصورة وحفظها

    var kind: Int {
        switch self {
        case .prompt: 0
        case .loading: 1
        case .drawing: 2
        case .waiting: 3
        case .decoding: 4
        }
    }
}

/// تقدم الرسم الحالي (صورة وحدة في نفس الوقت)
@MainActor
final class ImageProgress: ObservableObject {
    static let shared = ImageProgress()

    @Published private(set) var id: UUID?
    @Published private(set) var phase: GenPhase = .prompt
    @Published private(set) var preview: CGImage?
    private(set) var phaseStart = Date()

    func begin(_ id: UUID) {
        self.id = id
        phase = .prompt
        preview = nil
        phaseStart = Date()
    }

    func end() {
        id = nil
        preview = nil
    }

    func set(_ p: GenPhase, preview box: PreviewBox?) {
        guard id != nil else { return }
        if p.kind != phase.kind { phaseStart = Date() }
        phase = p
        if let box { preview = box.image }
    }

    /// يُستدعى من أي خيط
    nonisolated static func post(_ p: GenPhase, preview: PreviewBox? = nil) {
        Task { @MainActor in ImageProgress.shared.set(p, preview: preview) }
    }

    /// المرحلة المعروضة والنسبة الكلية (٠…١) في لحظة معيّنة
    func stage(at now: Date) -> (label: String, fraction: Double) {
        let dt = max(0, now.timeIntervalSince(phaseStart))
        func ease(_ tau: Double) -> Double { 1 - exp(-dt / tau) }
        switch phase {
        case .prompt:
            return ("أفهم الوصف", 0.08 * ease(4))
        case .loading:
            return ("أجهّز المشهد", 0.08 + 0.07 * ease(8))
        case .drawing(let k, let n):
            let f = n > 0 ? Double(k) / Double(n) : 0
            let label = f < 0.35 ? "أرسم المسودة الأولى" : f < 0.7 ? "أرسم الملامح" : "أحسّن التفاصيل"
            return (label, 0.15 + 0.8 * f)
        case .waiting:
            // ما فيه تقدم حقيقي: مراحل بالوقت ونسبة تقرب من ٩٥٪ بدون ما توصلها
            let label = dt < 3 ? "أجهّز المشهد" : dt < 9 ? "أرسم المسودة الأولى" : dt < 16 ? "أرسم الملامح" : "أحسّن التفاصيل"
            return (label, 0.1 + 0.85 * ease(14))
        case .decoding:
            return ("أجهّز الصورة", 0.97)
        }
    }

    /// معاينة تقريبية من الـlatents بدون VAE: تحويل خطي معروف من ٤ قنوات إلى RGB (صورة ٦٤×٦٤ مغبّشة)
    nonisolated static func latentPreview(_ a: MLShapedArray<Float32>) -> CGImage? {
        let sh = a.shape
        guard sh.count == 4, sh[1] == 4 else { return nil }
        let h = sh[2], w = sh[3], plane = h * w
        let s = a.scalars
        guard s.count >= 4 * plane else { return nil }
        // معاملات تقريبية شائعة لمعاينة latents في Stable Diffusion
        let m: [(Float, Float, Float)] = [
            (0.298, 0.207, 0.208),
            (0.187, 0.286, 0.173),
            (-0.158, 0.189, 0.264),
            (-0.184, -0.271, -0.473),
        ]
        var px = [UInt8](repeating: 255, count: plane * 4)
        for i in 0..<plane {
            var r: Float = 0, g: Float = 0, b: Float = 0
            for c in 0..<4 {
                let v = s[c * plane + i]
                r += v * m[c].0; g += v * m[c].1; b += v * m[c].2
            }
            px[i * 4] = UInt8(max(0, min(255, (r + 1) * 127.5)))
            px[i * 4 + 1] = UInt8(max(0, min(255, (g + 1) * 127.5)))
            px[i * 4 + 2] = UInt8(max(0, min(255, (b + 1) * 127.5)))
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }
}

// MARK: - الواجهة

/// أثناء الرسم: البرومبت أول، وتحته بطاقة بحجم الصورة فيها نقاط تتوهج بألوان أيقونة صوت
struct GenProgressView: View {
    let message: Message
    @ObservedObject private var hub = ImageProgress.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNeg = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = message.genPrompt {
                promptBox(p)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 30)) { tl in
                let live = hub.id == message.id
                let st = live ? hub.stage(at: tl.date) : (label: "أجهّز", fraction: 0.0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(st.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .id(st.label)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: st.label)
                    card(t: reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate,
                         progress: st.fraction, preview: live ? hub.preview : nil)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: message.genPrompt)
    }

    private func promptBox(_ p: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("📝 البرومبت").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(p).font(.callout).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let n = message.genNegative, !n.isEmpty {
                Button { withAnimation { showNeg.toggle() } } label: {
                    Label(showNeg ? "إخفاء اللي نتجنبه" : "اللي نتجنبه", systemImage: showNeg ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showNeg {
                    Text(n).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func card(t: Double, progress: Double, preview: CGImage?) -> some View {
        // المعاينة تظهر تحت النقاط في آخر ~٣٠٪
        let reveal = max(0, min(1, (progress - 0.65) / 0.3))
        return ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.04, blue: 0.15), Color(red: 0.09, green: 0.07, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .blur(radius: 14 - 8 * reveal)
                    .opacity(0.85 * reveal)
            }
            // كرة المكالمة نفسها (نفس الشيدر)، طاقتها تزيد بهدوء مع التقدم
            GeometryReader { g in
                OrbView(mic: 0,
                        out: Float(min(1, 0.12 + 0.5 * progress + (reduceMotion ? 0 : 0.05 * sin(t * 1.4)))),
                        state: .thinking, animated: !reduceMotion)
                    .frame(width: g.size.width * 0.62, height: g.size.width * 0.62)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .opacity(1 - 0.45 * reveal)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .padding(.horizontal, 12).frame(height: 32)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(maxWidth: 300)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("أرسم الصورة")
        .accessibilityValue("\(Int((progress * 100).rounded())) بالمية")
    }
}

