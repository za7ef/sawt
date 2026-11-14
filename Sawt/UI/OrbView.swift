import SwiftUI

/// كرة متحركة تتفاعل مع صوتك وصوت الذكاء.
struct OrbView: View {
    var mic: Float
    var out: Float
    var state: CallController.State
    var animated = true


    private var palette: [Color] {
        switch state {
        case .hearing: return [Color(red: 0.3, green: 0.85, blue: 1.0), Theme.accent, Color(red: 0.2, green: 0.5, blue: 1)]
        case .thinking: return [Theme.accent2, Color(red: 0.95, green: 0.5, blue: 0.9), Theme.accent]
        case .speaking: return [Theme.accent, Theme.accent2, Color(red: 0.35, green: 0.9, blue: 0.95)]
        default: return [Theme.accent, Theme.accent2, Color(red: 0.3, green: 0.75, blue: 1.0)]
        }
    }

    /// نخفف الإطارات بس لما الجوال حار جدًا (serious/critical)، مو لما يكون دافي.
    private var interval: Double? {
        let st = ProcessInfo.processInfo.thermalState
        return (st == .serious || st == .critical) ? 1.0 / 30 : nil
    }

    @State private var smoother = LevelSmoother()

    var body: some View {
        // الكرة ترسم بشيدر Metal (تمريرة وحدة على كرت الشاشة) بمعدل الشاشة (60–120)،
        // والمستويات تتنعّم كل إطار بدل ما تقفز مع تحديثات المايك.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let pad: CGFloat = side * 0.6
            TimelineView(.animation(minimumInterval: interval, paused: !animated)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let lv = smoother.step(mic: Double(mic), out: Double(out), now: t)
                let c = palette
                let full = side + 2 * pad
                Rectangle()
                    .fill(.white)
                    .frame(width: full, height: full)
                    .colorEffect(ShaderLibrary.orb(
                        .float2(Float(full), Float(full)),
                        .float(Float(t.truncatingRemainder(dividingBy: 3600))),
                        .float(Float(lv.mic)), .float(Float(lv.out)),
                        .float(state == .thinking ? 1 : 0),
                        .float(Float(side / full)),
                        .color(c[0]), .color(c[1]), .color(c[2])))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// تنعيم أُسّي حسب الزمن بين الإطارات (مستقل عن معدل الإطارات).
    final class LevelSmoother {
        var mic = 0.0, out = 0.0, last = 0.0
        func step(mic m: Double, out o: Double, now: Double) -> (mic: Double, out: Double) {
            let dt = last == 0 ? 0.016 : min(0.1, max(0, now - last))
            last = now
            func ease(_ cur: Double, _ target: Double) -> Double {
                let tau = target > cur ? 0.06 : 0.18   // يطلع بسرعة وينزل بهدوء
                return cur + (target - cur) * (1 - exp(-dt / tau))
            }
            mic = ease(mic, m); out = ease(out, o)
            return (mic, out)
        }
    }
}
