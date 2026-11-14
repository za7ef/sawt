import SwiftUI

/// كرة متحركة تتفاعل مع صوتك وصوت الذكاء.
struct OrbView: View {
    var mic: Float
    var out: Float
    var state: CallController.State
    var animated = true

    @State private var smoothMic: Double = 0
    @State private var smoothOut: Double = 0

    private var palette: [Color] {
        switch state {
        case .hearing: return [Color(red: 0.3, green: 0.85, blue: 1.0), Theme.accent, Color(red: 0.2, green: 0.5, blue: 1)]
        case .thinking: return [Theme.accent2, Color(red: 0.95, green: 0.5, blue: 0.9), Theme.accent]
        case .speaking: return [Theme.accent, Theme.accent2, Color(red: 0.35, green: 0.9, blue: 0.95)]
        default: return [Theme.accent, Theme.accent2, Color(red: 0.3, green: 0.75, blue: 1.0)]
        }
    }

    private var interval: Double { ThermalWatch.isHot ? 1.0 / 15 : 1.0 / 30 }

    var body: some View {
        // 30 إطار بالثانية (15 لو الجوال حار) بدل 120، أخف بكثير على كرت الشاشة
        TimelineView(.animation(minimumInterval: interval, paused: !animated)) { ctx in
            let t: Double = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in draw(&gc, size, t) }
        }
        .onChange(of: mic) { _, v in withAnimation(.easeOut(duration: 0.12)) { smoothMic = smoothMic * 0.4 + Double(v) * 0.6 } }
        .onChange(of: out) { _, v in withAnimation(.easeOut(duration: 0.12)) { smoothOut = smoothOut * 0.4 + Double(v) * 0.6 } }
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let energy: Double = max(smoothMic, smoothOut)
        let thinkPulse: Double = state == .thinking ? 0.06 * sin(t * 4) : 0
        let r: Double = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let base: Double = r * (0.78 + 0.16 * energy + thinkPulse)
        let colors = palette

        // هالة خارجية
        gc.drawLayer { l in
            l.addFilter(.blur(radius: r * 0.25))
            l.opacity = 0.55 + 0.4 * energy
            let path = blob(c, base * 1.05, t * 0.6, 0.08 + 0.12 * energy)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
            l.fill(path, with: shading)
        }
        // الطبقات الداخلية
        for i in 0..<2 {
            let k = Double(i)
            let level: Double = i == 0 ? smoothOut : smoothMic
            let wob: Double = 0.05 + 0.18 * level + 0.02 * k
            let path = blob(c, base * (0.95 - k * 0.12), t * (0.9 + k * 0.35) + k * 2, wob)
            let cx: Double = c.x + cos(t + k) * r * 0.25
            let cy: Double = c.y + sin(t * 1.3 + k) * r * 0.25
            let g = Gradient(colors: [colors[(i + 1) % 3].opacity(0.95), colors[i % 3].opacity(0.6)])
            let shading = GraphicsContext.Shading.radialGradient(g, center: CGPoint(x: cx, y: cy),
                                                                 startRadius: 0, endRadius: base)
            gc.drawLayer { l in
                l.addFilter(.blur(radius: 6 + k * 4))
                l.opacity = 0.85 - k * 0.2
                l.fill(path, with: shading)
            }
        }
        // لمعة زجاجية
        let hl = Path(ellipseIn: CGRect(x: c.x - base * 0.5, y: c.y - base * 0.75, width: base * 0.9, height: base * 0.55))
        gc.drawLayer { l in
            l.addFilter(.blur(radius: r * 0.12))
            l.opacity = 0.35
            l.fill(hl, with: .color(.white))
        }
    }

    /// شكل دائري متموج.
    private func blob(_ c: CGPoint, _ radius: Double, _ t: Double, _ wobble: Double) -> Path {
        var p = Path()
        let n = 64
        for i in 0...n {
            let a = Double(i) / Double(n) * .pi * 2
            let d = 1 + wobble * (0.55 * sin(3 * a + t * 1.7) + 0.3 * sin(5 * a - t * 2.3) + 0.15 * sin(7 * a + t * 3.1))
            let pt = CGPoint(x: c.x + cos(a) * radius * d, y: c.y + sin(a) * radius * d)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
