import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var call: CallController
    var openDrawer: () -> Void

    @State private var draft = ""
    @State private var voiceMode = false
    @State private var showModels = false
    @StateObject private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            messages
            composer
        }
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(isPresented: $voiceMode) {
            VoiceModeView()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $showModels) { ModelsView() }
        .alert("تنبيه", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("تمام", role: .cancel) {}
        } message: { Text(store.error ?? "") }
    }

    // MARK: الشريط العلوي

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: openDrawer) {
                Image(systemName: "line.3.horizontal").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            Spacer()

            Menu {
                ForEach(Catalog.llms.filter { models.downloaded.contains($0.id) || $0.id == settings.llmID }) { m in
                    Button {
                        models.activate(m)
                    } label: {
                        if m.id == settings.llmID { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
                Divider()
                Button { showModels = true } label: { Label("كل النماذج…", systemImage: "square.grid.2x2") }
            } label: {
                HStack(spacing: 6) {
                    Text("صوت").fontWeight(.bold)
                    Text(settings.llm.title).foregroundStyle(.secondary)
                    statusDot
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { store.newConversation() } label: {
                Image(systemName: "square.and.pencil").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var statusDot: some View {
        switch models.llm {
        case .ready: EmptyView()
        case .loading(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        case .preparing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: الرسائل

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if (store.current?.messages ?? []).isEmpty && !store.isGenerating {
                        EmptyState(startVoice: startVoice)
                            .padding(.top, 120)
                    }
                    ForEach(store.current?.messages ?? []) { m in
                        MessageRow(message: m).id(m.id)
                    }
                    if store.isGenerating {
                        MessageRow(message: Message(role: .assistant, text: store.streamingText), streaming: true)
                            .id("stream")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.current?.messages.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.currentID) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: خانة الكتابة

    private var composer: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(dictation.isRecording ? "أسمعك…" : "اكتب رسالة", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 12)
                        .padding(.leading, 16)
                        .submitLabel(.send)

                    Button {
                        if dictation.isRecording {
                            dictation.stop { text in draft += (draft.isEmpty ? "" : " ") + text }
                        } else {
                            dictation.start()
                        }
                    } label: {
                        Image(systemName: dictation.isRecording ? "stop.circle.fill" : (dictation.isBusy ? "ellipsis" : "mic"))
                            .font(.title3)
                            .symbolEffect(.pulse, isActive: dictation.isRecording)
                            .foregroundStyle(dictation.isRecording ? .red : .primary)
                            .frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(dictation.isBusy || !models.stt.isReady)
                    .padding(.trailing, 6)
                }
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                actionButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .padding(.top, 6)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draft.isEmpty)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.isGenerating)
    }

    @ViewBuilder private var actionButton: some View {
        if store.isGenerating {
            Button { store.stop() } label: {
                Image(systemName: "stop.fill").font(.body.weight(.bold)).frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .transition(.scale.combined(with: .opacity))
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(store.isGenerating)
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: startVoice) {
                Image(systemName: "waveform").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func send() {
        guard models.llm.isReady else {
            store.error = models.llm.isBusy ? "النموذج للحين يتجهز، لحظات." : "اختر نموذج ونزّله من شاشة النماذج أول."
            if !models.llm.isBusy { showModels = true }
            return
        }
        let t = draft
        draft = ""
        store.send(t) { failed in draft = failed }
    }

    private func startVoice() {
        focused = false
        store.stop()
        voiceMode = true
    }
}

struct EmptyState: View {
    var startVoice: () -> Void
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            OrbView(mic: 0, out: 0, state: .idle)
                .frame(width: 110, height: 110)
                .scaleEffect(appear ? 1 : 0.6)
                .opacity(appear ? 1 : 0)
            Text("وش في بالك؟").font(.title2.weight(.semibold))
            Text("كل شي يشتغل على جوالك بدون إنترنت")
                .font(.subheadline).foregroundStyle(.secondary)
            Button(action: startVoice) {
                Label("ابدأ مكالمة صوتية", systemImage: "waveform")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appear = true } }
    }
}

struct MessageRow: View {
    let message: Message
    var streaming = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                // في الواجهة العربية بداية السطر يمين، فرسائلك تطلع يمين مثل ChatGPT
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    if message.viaVoice {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 50)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if streaming && message.text.isEmpty {
                        TypingDots()
                    } else {
                        Text(LocalizedStringKey(message.text))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !streaming {
                        HStack(spacing: 14) {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            Button { Speaker.shared.speak(message.text) } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            if message.viaVoice { Image(systemName: "waveform") }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle().fill(.secondary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.6 + 0.4 * abs(sin(t * 3 + Double(i) * 0.6)))
                }
            }
            .padding(.vertical, 8)
        }
    }
}
