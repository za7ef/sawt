import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SawtWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CallLiveActivity()
        AgentLiveActivity()
    }
}

struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { ctx in
            // شاشة القفل
            HStack(spacing: 12) {
                Image(systemName: ctx.state.icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("مكالمة صوت").font(.headline)
                    Text(ctx.state.label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().font(.subheadline)
                    .frame(width: 56)
                Button(intent: ToggleMuteIntent()) {
                    Image(systemName: ctx.state.muted ? "mic.slash.fill" : "mic.fill")
                }
                .tint(.gray)
                Button(intent: EndCallIntent()) {
                    Image(systemName: "phone.down.fill")
                }
                .tint(.red)
            }
            .padding()
            .environment(\.layoutDirection, .rightToLeft)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.state.label, systemImage: ctx.state.icon)
                        .font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit().font(.subheadline)
                        .frame(width: 56)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 16) {
                        Button(intent: ToggleMuteIntent()) {
                            Label(ctx.state.muted ? "شغّل المايك" : "اكتم", systemImage: ctx.state.muted ? "mic.fill" : "mic.slash.fill")
                        }
                        .tint(.gray)
                        Button(intent: EndCallIntent()) {
                            Label("إنهاء", systemImage: "phone.down.fill")
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.state.icon).foregroundStyle(.blue)
            } compactTrailing: {
                Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(width: 40)
            } minimal: {
                Image(systemName: ctx.state.icon).foregroundStyle(.blue)
            }
        }
    }
}

struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { ctx in
            HStack(spacing: 12) {
                Image(systemName: ctx.state.phaseIcon)
                    .font(.title2).foregroundStyle(ctx.state.busy ? Color.purple : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.task.map { "الوكيل: \($0)" } ?? "المشغّل: \(ctx.state.phaseTitle)").font(.headline).lineLimit(1)
                    Text(ctx.state.busy ? "\(ctx.state.phaseTitle) — \(ctx.state.step)" : ctx.state.step)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if ctx.state.busy {
                    Button(intent: StopAgentIntent()) { Label("إيقاف", systemImage: "stop.fill") }.tint(.red)
                } else {
                    Button(intent: StopRunnerIntent()) { Label("إطفاء", systemImage: "power") }.tint(.orange)
                }
            }
            .padding()
            .environment(\.layoutDirection, .rightToLeft)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ctx.state.phaseIcon).foregroundStyle(ctx.state.busy ? Color.purple : Color.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ctx.state.busy {
                        Button(intent: StopAgentIntent()) { Label("إيقاف", systemImage: "stop.fill") }.tint(.red)
                    } else {
                        Button(intent: StopRunnerIntent()) { Label("إطفاء", systemImage: "power") }.tint(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(ctx.state.phaseTitle): \(ctx.state.step)").font(.subheadline).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: ctx.state.phaseIcon).foregroundStyle(ctx.state.busy ? Color.purple : Color.green)
            } compactTrailing: {
                Text(ctx.state.phase == "step" || ctx.state.phase == nil ? "\(ctx.state.n)" : ctx.state.phaseTitle).monospacedDigit()
            } minimal: {
                Image(systemName: ctx.state.phaseIcon).foregroundStyle(ctx.state.busy ? Color.purple : Color.green)
            }
        }
    }
}
