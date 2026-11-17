import SwiftUI

// MARK: - نص الرد بإيقاع ثابت مع ظهور ناعم لكل كلمة

/// يعرض نص الرد كلمة كلمة بإيقاع ثابت (يسرّع لو تراكم النص)، وكل دفعة جديدة تظهر بتلاشي ناعم.
/// نقسم على المسافات بس، فما تنكسر الحروف العربية المتصلة؛ والتلاشي لون على مقطع من نفس النص المنسّق.
/// لما يخلص الرد أو ينوقف، الرسالة النهائية تطلع كاملة على طول (هالعرض للرد الجاري بس).
struct PacedText: View {
    let target: String
    /// الرد خلص: نطلق آخر كلمة على طول ونبلّغ لما نلحق
    var done = false
    var onGrow: () -> Void = {}
    var onCaughtUp: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Reveal { let at: Int; let time: Date }
    @State private var shown = 0
    @State private var reveals: [Reveal] = []
    @State private var lastLen = 0
    @State private var lastGrowth = Date()
    // نسخة حيّة من المدخلات: مهمة .task تحتفظ بنسخة الـView وقت بدايتها، فقراءة target منها تعطي أول دفعة بس
    @State private var latest = ""
    @State private var finished = false
    @State private var reported = false

    private static let fade = 0.12

    var body: some View {
        if reduceMotion {
            Text(Self.render(target))
                .onChange(of: target) { onGrow() }
                .onAppear { if done { onCaughtUp() } }
                .onChange(of: done) { if done { onCaughtUp() } }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reveals.isEmpty)) { tl in
                Text(styled(at: tl.date))
            }
            .onAppear { latest = target; finished = done }
            .onChange(of: target) { latest = target }
            .onChange(of: done) { finished = done }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    step()
                }
            }
        }
    }

    /// ينسّق النص (روابط/عريض/مائل) بنفس قواعد الرسالة النهائية
    static func render(_ s: String) -> AttributedString {
        let clean = SafeMarkdown.clean(s)
        return (try? AttributedString(markdown: clean, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(clean)
    }

    private func styled(at now: Date) -> AttributedString {
        let chars = Array(target)
        let n = min(shown, chars.count)
        var out = Self.render(String(chars[0..<n]))
        let total = out.characters.count
        let live = reveals.filter { now.timeIntervalSince($0.time) < Self.fade && $0.at < n }
        for (k, r) in live.enumerated() {
            // بداية المقطع بعد التنسيق = طول تنسيق النص قبله
            let start = min(total, Self.render(String(chars[0..<r.at])).characters.count)
            let endRaw = k + 1 < live.count ? live[k + 1].at : n
            let end = min(total, k + 1 < live.count ? Self.render(String(chars[0..<endRaw])).characters.count : total)
            guard start < end else { continue }
            let a = out.characters.index(out.characters.startIndex, offsetBy: start)
            let b = out.characters.index(out.characters.startIndex, offsetBy: end)
            let x = max(0, min(1, now.timeIntervalSince(r.time) / Self.fade))
            out[a..<b].foregroundColor = Color.primary.opacity(x * (2 - x))   // ease-out
        }
        return out
    }

    /// يطلع كلمة أو أكثر حسب التراكم: يمشي بإيقاع ثابت وما يتأخر كثير عن النموذج
    private func step() {
        let chars = Array(latest)
        let now = Date()
        if chars.count != lastLen { lastLen = chars.count; lastGrowth = now }
        if shown > chars.count { shown = chars.count; reveals = [] }
        reveals.removeAll { now.timeIntervalSince($0.time) >= Self.fade }
        let backlog = chars.count - shown
        guard backlog > 0 else {
            if finished, !reported, reveals.isEmpty { reported = true; onCaughtUp() }
            return
        }
        let words = backlog > 600 ? 8 : backlog > 300 ? 4 : backlog > 120 ? 2 : 1
        var i = shown
        var released = 0
        while released < words, i < chars.count {
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            // آخر كلمة للحين تنكتب: ننتظرها إلا لو النموذج وقف شوي
            if j == chars.count, !finished, now.timeIntervalSince(lastGrowth) < 0.35 { break }
            i = j
            released += 1
        }
        guard i > shown else { return }
        reveals.append(Reveal(at: shown, time: now))
        shown = i
        onGrow()
    }
}

// MARK: - الخط الزمني لمهمة الوكيل

struct AgentTimeline: View {
    let steps: [AgentStepRec]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                AgentStepRow(step: s, isLast: i == steps.count - 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: steps)
    }
}

struct AgentStepRow: View {
    let step: AgentStepRec
    let isLast: Bool
    @State private var open = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                StepMark(state: step.state)
                    .frame(width: 22, height: 22)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.subheadline)
                    .foregroundStyle(step.state == .skipped ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if !step.details.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("التفاصيل")
                            Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if open {
                        Text(step.details.joined(separator: "\n"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
    }
}

/// علامة الحالة: كل حالة لها رسمة متحركة، وتتبدل بتكبير + تلاشي
struct StepMark: View {
    let state: AgentStepRec.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .done: DoneMark(still: reduceMotion)
            case .failed: FailMark(muted: false, still: reduceMotion)
            case .skipped: FailMark(muted: true, still: reduceMotion)
            case .running: RunningMark(still: reduceMotion)
            case .ask: AskMark(still: reduceMotion)
            case .pending:
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .id(state)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: state)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .done: L("تمت")
        case .failed: L("فشلت")
        case .skipped: L("لم تكتمل")
        case .running: L("قيد التنفيذ")
        case .ask: L("تنتظر موافقتك")
        case .pending: L("بالانتظار")
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.68))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.73, y: r.minY + r.height * 0.36))
        return p
    }
}

private struct XLine: Shape {
    let flip: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = r.width * 0.33, b = r.width * 0.67
        p.move(to: CGPoint(x: r.minX + (flip ? b : a), y: r.minY + a))
        p.addLine(to: CGPoint(x: r.minX + (flip ? a : b), y: r.minY + b))
        return p
    }
}

private struct DoneMark: View {
    let still: Bool
    @State private var fill: CGFloat = 0.6
    @State private var draw: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent).scaleEffect(fill)
            CheckShape()
                .trim(from: 0, to: draw)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .onAppear {
            if still { fill = 1; draw = 1; return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { fill = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.08)) { draw = 1 }
        }
    }
}

private struct FailMark: View {
    let muted: Bool
    let still: Bool
    @State private var first: CGFloat = 0
    @State private var second: CGFloat = 0
    @State private var shake: CGFloat = 0

    var body: some View {
        let tint = muted ? Color.red.opacity(0.35) : Color.red
        ZStack {
            Circle().fill(muted ? Color.gray.opacity(0.25) : Color.red)
            XLine(flip: false).trim(from: 0, to: first)
                .stroke(muted ? tint : Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            XLine(flip: true).trim(from: 0, to: second)
                .stroke(muted ? tint : Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .offset(x: shake)
        .onAppear {
            if still { first = 1; second = 1; return }
            withAnimation(.easeOut(duration: 0.16)) { first = 1 }
            withAnimation(.easeOut(duration: 0.16).delay(0.16)) { second = 1 }
            guard !muted else { return }
            withAnimation(.easeInOut(duration: 0.06).delay(0.34).repeatCount(4, autoreverses: true)) { shake = 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                withAnimation(.easeOut(duration: 0.08)) { shake = 0 }
            }
        }
    }
}

private struct RunningMark: View {
    let still: Bool
    @State private var spin = false
    @State private var pulse: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(4)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .scaleEffect(pulse)
        .onAppear {
            guard !still else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            pulse = 1.25
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { pulse = 1 }
        }
    }
}

private struct AskMark: View {
    let still: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.orange, lineWidth: 1.5)
            Image(systemName: "questionmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.orange)
                .symbolEffect(.pulse, options: .repeating, isActive: !still)
        }
    }
}
