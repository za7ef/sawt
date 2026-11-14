import PhotosUI
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
    @State private var pending: [Attachment] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attaching = false
    @ObservedObject private var net = NetworkGate.shared
    @State private var webAsk = false

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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in addImage(img) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 3, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            attaching = true
            Task {
                for it in items {
                    if let data = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        addImage(img)
                    }
                }
                photoItems = []
                attaching = false
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: Attachments.fileTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attaching = true
            Task {
                for u in urls.prefix(3) {
                    do { pending.append(try await Attachments.addFile(u)) }
                    catch { store.error = error.localizedDescription }
                }
                attaching = false
            }
        }
        .onChange(of: dictation.error) { _, e in if let e { store.error = e; dictation.error = nil } }
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
                        MessageRow(message: m).equatable().id(m.id)
                    }
                    if store.isGenerating {
                        StreamingRow(live: store.live) { proxy.scrollTo("bottom", anchor: .bottom) }
                            .id("stream")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.current?.messages.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.currentID) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: خانة الكتابة

    private func addImage(_ img: UIImage) {
        do {
            pending.append(try Attachments.addImage(img))
            ModelManager.shared.preloadVisionIfUseful()
        }
        catch { store.error = error.localizedDescription }
    }

    @ViewBuilder private var pendingBar: some View {
        if !pending.isEmpty || attaching {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending) { a in
                            AttachmentChip(a: a, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        pending.removeAll { $0.id == a.id }
                                        a.deleteFiles()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").font(.callout)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                        }
                        if attaching { ProgressView().frame(width: 56, height: 56) }
                    }
                    .padding(.horizontal, 16).padding(.top, 6)
                }
                if pending.contains(where: { $0.kind == .image }) && settings.llm.vision {
                    Text("أول صورة تحتاج تحميل النموذج بوضع النظر، ياخذ ثواني وذاكرة أكثر شوي.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                if pending.contains(where: { $0.kind == .image }) && !settings.llm.vision {
                    HStack(spacing: 6) {
                        Text("\(settings.llm.title) ما يشوف الصور، بيقرأ النص اللي فيها بس.")
                        if let v = Catalog.llms.first(where: { $0.vision && models.downloaded.contains($0.id) })
                            ?? Catalog.llms.first(where: { $0.vision }) {
                            Button("بدّل لـ \(v.title)") { models.activate(v) }.font(.caption.weight(.semibold))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button { showCamera = true } label: { Label("الكاميرا", systemImage: "camera") }
            Button { showPhotos = true } label: { Label("الصور", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("الملفات", systemImage: "folder") }
        } label: {
            Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    /// زر الإنترنت/البحث في الويب: مقفول = التطبيق ما يتصل بالإنترنت أبدًا.
    private var webButton: some View {
        Button {
            if net.on { net.on = false } else { webAsk = true }
        } label: {
            Image(systemName: "globe")
                .font(.body.weight(.medium))
                .foregroundStyle(net.on ? Theme.accent : Color.secondary)
                .frame(width: 34, height: 44)
                .background(net.on ? Theme.accent.opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(net.on ? "بحث في الويب: شغال" : "بحث في الويب: مقفول")
        .alert("بيتم الوصول للإنترنت", isPresented: $webAsk) {
            Button("متابعة") { net.on = true }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("سؤالك بيروح لمحرك بحث (DuckDuckGo، أو ويكيبيديا كبديل) عشان يجيب صفحات، والباقي يظل على جوالك. لما تقفل الزر ينقطع التطبيق عن الإنترنت.")
        }
    }

    /// تفكير عميق (لكل محادثة)
    private var thinkButton: some View {
        Button {
            store.setDeepThink(!store.deepThink)
        } label: {
            Image(systemName: "brain")
                .font(.body.weight(.medium))
                .foregroundStyle(store.deepThink ? Theme.accent : Color.secondary)
                .frame(width: 34, height: 44)
                .background(store.deepThink ? Theme.accent.opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.deepThink ? "تفكير عميق: شغال" : "تفكير عميق: طافي")
    }

    private var composer: some View {
        VStack(spacing: 0) {
        pendingBar
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    thinkButton
                    webButton
                    TextField(dictation.isRecording ? "أسمعك…" : "اكتب رسالة", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 12)
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
    }

    @ViewBuilder private var actionButton: some View {
        if store.isGenerating {
            Button { store.stop() } label: {
                Image(systemName: "stop.fill").font(.body.weight(.bold)).frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .transition(.scale.combined(with: .opacity))
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty {
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
        let atts = pending
        draft = ""
        pending = []
        store.send(t, attachments: atts, web: net.on) { failed in draft = failed; pending = atts }
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
            OrbView(mic: 0, out: 0, state: .idle, animated: false)
                .frame(width: 110, height: 110)
                .scaleEffect(appear ? 1 : 0.6)
                .opacity(appear ? 1 : 0)
            Text("وش في بالك؟").font(.title2.weight(.semibold))
            Text("النموذج يشتغل على جوالك، والإنترنت مقفول إلا إذا شغّلته")
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

struct MessageRow: View, Equatable {
    let message: Message
    var streaming = false
    @State private var showMemory = false

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message == b.message && a.streaming == b.streaming }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                // في الواجهة العربية بداية السطر يمين، فرسائلك تطلع يمين مثل ChatGPT
                VStack(alignment: .leading, spacing: 4) {
                    if let atts = message.attachments, !atts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(atts) { AttachmentChip(a: $0, size: 72) } }
                        }
                        .frame(maxWidth: 260)
                    }
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
                    if message.memorySaved == true {
                        Button { showMemory = true } label: {
                            Text("تم حفظ الذاكرة").font(.caption2).foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    if let n = message.notice {
                        Label(n, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    if let th = message.thinking, !th.isEmpty {
                        ThinkingSection(text: th, seconds: message.thinkSeconds, live: false)
                    }
                    if streaming && message.text.isEmpty {
                        TypingDots()
                    } else {
                        Text(SafeMarkdown.key(message.text))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let src = message.sources, !src.isEmpty {
                        SourcesList(sources: src)
                    }
                    if !streaming {
                        HStack(spacing: 14) {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            Button { Speaker.shared.speak(message.text) } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            if NamaaVoice.isInstalled, let namaa = Catalog.namaaVoice {
                                Button { Speaker.shared.speak(message.text, voice: namaa) } label: {
                                    Label("نماء", systemImage: "person.wave.2")
                                        .labelStyle(.titleAndIcon)
                                }
                                .accessibilityLabel("اقرأ بصوت نماء السعودي (تجريبي)")
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
        .sheet(isPresented: $showMemory) { NavigationStack { MemoryView() } }
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

/// الرد اللي ينكتب الحين: يراقب StreamBuffer بس، فالقائمة ما تنعاد كل كلمة.
struct StreamingRow: View {
    @ObservedObject var live: StreamBuffer
    var onGrow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let st = live.status {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(st) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !live.thinking.isEmpty {
                ThinkingSection(text: live.thinking, seconds: nil, live: live.text.isEmpty)
            }
            if live.text.isEmpty {
                if live.status == nil && live.thinking.isEmpty { TypingDots() }
            } else {
                Text(SafeMarkdown.key(live.text))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: live.text) { onGrow() }
    }
}

/// قسم التفكير: رمادي ومطوي افتراضيًا.
struct ThinkingSection: View {
    let text: String
    let seconds: Double?
    let live: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain").font(.caption2)
                    Text(title).font(.caption)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.gray)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 2) }
                    .textSelection(.enabled)
            }
        }
    }

    private var title: String {
        if live { return "يفكر…" }
        if let s = seconds { return "فكّر لمدة \(max(1, Int(s.rounded())))ث" }
        return "التفكير"
    }
}

/// روابط المصادر تحت الرد.
struct SourcesList: View {
    let sources: [WebSource]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("المصادر").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                Button {
                    if let u = URL(string: s.url), u.scheme == "https" || u.scheme == "http" { openURL(u) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(i + 1)]").font(.caption.monospacedDigit())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.title).font(.caption).lineLimit(1)
                            Text(URL(string: s.url)?.host ?? s.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// تنسيق Markdown بدون روابط قابلة للضغط في نص النموذج (حماية من روابط مدسوسة من صفحات الويب).
/// الروابط الوحيدة القابلة للضغط هي قائمة المصادر.
enum SafeMarkdown {
    private static let linkRE = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let autoRE = try! NSRegularExpression(pattern: #"<((?:https?|mailto|tel|sms):[^>\s]+)>"#, options: [.caseInsensitive])

    static func clean(_ s: String) -> String {
        var t = s
        // [نص](رابط) → نص (الدومين)
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in linkRE.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let label = ns.substring(with: m.range(at: 1))
            let host = URL(string: ns.substring(with: m.range(at: 2)))?.host
            out += label + (host.map { " (\($0))" } ?? "")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        t = out
        t = autoRE.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "`$1`")
        return t
    }

    static func key(_ s: String) -> LocalizedStringKey {
        LocalizedStringKey(clean(s))
    }
}
