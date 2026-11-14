import SwiftUI

/// وضع المكالمة بملء الشاشة.
struct VoiceModeView: View {
    @EnvironmentObject var call: CallController
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showCaptions = true
    @AppStorage("showCallDebug") private var showDebug = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                if showDebug { DebugOverlay(debug: call.debug).padding(.horizontal, 16).padding(.top, 8) }
                Spacer()
                OrbView(mic: call.micLevel, out: call.outLevel, state: call.state)
                    .frame(width: 260, height: 260)
                    .contentShape(Circle())
                    .onTapGesture { call.interrupt() }
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: call.state)
                    .padding(.top, 28)
                Spacer()
                if showCaptions { captions.padding(.horizontal, 24).padding(.bottom, 18) }
                controls.padding(.bottom, 24)
            }
        }
        .onAppear {
            call.onTurnsChanged = { turns in Task { @MainActor in ChatStore.shared.syncFromCall(turns) } }
            call.start(seed: store.seedForCall())
        }
        .onDisappear {
            call.end()
            call.onTurnsChanged = nil
        }
        .onChange(of: call.state) { _, s in
            if s == .idle, call.error != nil { } // يبقى ظاهر للتنبيه
        }
        .alert("تنبيه", isPresented: Binding(get: { call.error != nil }, set: { if !$0 { call.error = nil } })) {
            Button("تمام", role: .cancel) { if call.state == .idle { dismiss() } }
        } message: { Text(call.error ?? "") }
        .statusBarHidden(false)
    }

    private var background: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.accent.opacity(0.18 + 0.25 * Double(call.outLevel)), .clear],
                           center: .center, startRadius: 20, endRadius: 420)
                .animation(.easeOut(duration: 0.2), value: call.outLevel)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Button { showCaptions.toggle() } label: {
                Image(systemName: showCaptions ? "captions.bubble.fill" : "captions.bubble")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            Spacer()
            VStack(spacing: 2) {
                Text("صوت").font(.headline)
                Text(settings.llm.title + " • " + settings.voice.title)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showDebug.toggle() } label: {
                Image(systemName: showDebug ? "ladybug.fill" : "ladybug").frame(width: 44, height: 44)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var statusText: String {
        switch call.state {
        case .idle: return models.allReady ? "جاهز" : "يجهّز النماذج…"
        case .starting: return "يتصل…"
        case .listening: return call.muted ? "المايك مكتوم" : "أسمعك…"
        case .hearing: return "تكلّم، أنا أسمع"
        case .thinking: return "يفكر…"
        case .speaking: return "اضغط الكرة أو تكلّم عشان تقاطعه"
        }
    }

    private var captions: some View {
        let lastUser = call.turns.last(where: { $0.role == .user })?.text ?? ""
        let user = call.liveUser.isEmpty ? (call.state == .hearing ? "" : lastUser) : call.liveUser
        let ai = call.liveAI.isEmpty ? (call.turns.last?.role == .assistant ? call.turns.last!.text : "") : call.liveAI
        return VStack(alignment: .leading, spacing: 10) {
            if !user.isEmpty {
                Text(user).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if !ai.isEmpty {
                Text(ai).font(.body).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(user.isEmpty && ai.isEmpty ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: ai)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 28) {
                Button { call.toggleMute() } label: {
                    Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.title2).frame(width: 68, height: 68)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .tint(call.muted ? .red : nil)

                Button { call.interrupt() } label: {
                    Image(systemName: "hand.raised.fill").font(.title2).frame(width: 68, height: 68)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(!(call.state == .speaking || call.state == .thinking))

                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title2.weight(.bold)).frame(width: 68, height: 68)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .tint(.red)
            }
        }
    }
}

/// لوحة تشخيص صغيرة: توضح وين يعلق.
struct DebugOverlay: View {
    let debug: CallController.Debug
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("الحالة: \(debug.stage)").bold()
                Spacer()
                Circle().fill(debug.vadSpeech ? .green : .gray).frame(width: 9, height: 9)
                Text(String(format: "%.0f dB", debug.micDB)).monospacedDigit()
            }
            Text("آخر كلام: \(debug.lastTranscript.isEmpty ? "—" : debug.lastTranscript)").lineLimit(2)
            Text("سمع \(debug.sttMs)ms • أول كلمة \(debug.firstTokenMs)ms • أول صوت \(debug.firstAudioMs)ms")
                .monospacedDigit()
            HStack {
                Text("ذاكرة \(debug.ramMB)MB • متبقي \(debug.availMB)MB • حرارة \(debug.thermal)").monospacedDigit()
                Spacer()
                Button { shareURL = Log.shared.export() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ActivityView(items: [u]) }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
