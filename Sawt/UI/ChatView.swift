import PhotosUI
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var call: CallController
    var openDrawer: () -> Void

    @State private var draft = ""
    @State private var cloudTick = 0
    @State private var pendingCloud: CloudProvider?
    @State private var askCloudConsent = false
    /// يزيد مع كل إرسال: نتيجة إملاء صوتي متأخرة من قبل الإرسال ما ترجع تنكتب
    @State private var sendGen = 0
    @State private var voiceMode = false
    @State private var showModels = false
    @StateObject private var dictation = Dictation()
    @State private var focused = false
    @State private var pending: [Attachment] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attaching = false
    @ObservedObject private var net = NetworkGate.shared
    @State private var webAsk = false
    /// المستخدم قريب من آخر المحادثة؟ (لو طلع لفوق ما نسحبه لتحت مع كل رمز)
    @State private var nearBottom = true
    /// المستخدم يسحب القائمة بيده الحين (نحدّث «قريب من تحت» بس من حركته، مو من نمو الرد)
    @State private var userScrolling = false
    @AppStorage("netWarned") private var netWarned = false

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
        .onChange(of: showModels) { _, _ in cloudTick += 1 }
        .onChange(of: dictation.error) { _, e in if let e { store.error = e; dictation.error = nil } }
        .alert("تنبيه", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if CloudLLM.active != nil {
                Button("ارجع للنموذج المحلي") { CloudLLM.setActive(nil); cloudTick += 1; if models.llm == .idle { models.loadAll() } }
            }
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
                let _ = cloudTick
                let cloud = CloudLLM.active
                let onCPU = cloud == nil && ComputeMode.current == "cpu"
                Section("كرت الشاشة") {
                    ForEach(Catalog.llms.filter { models.downloaded.contains($0.id) || $0.id == settings.llmID }) { m in
                        Button { pickGPU(m) } label: {
                            if cloud == nil, !onCPU, m.id == settings.llmID { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                        }
                    }
                }
                let cpus = GGUFSpec.all.filter { $0.isDownloaded }
                if !cpus.isEmpty {
                    Section("المعالج") {
                        ForEach(cpus) { s in
                            Button { pickCPU(s) } label: {
                                if onCPU, s.id == GGUFSpec.active.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                            }
                        }
                    }
                }
                let clouds = CloudProvider.allCases.filter { $0.hasKey }
                if !clouds.isEmpty {
                    Section("سحابي") {
                        ForEach(clouds) { c in
                            Button { pickCloud(c) } label: {
                                if cloud == c { Label("\(c.short) · \(c.model)", systemImage: "checkmark") } else { Text("\(c.short) · \(c.model)") }
                            }
                        }
                    }
                }
                Divider()
                Button { showModels = true } label: { Label("كل النماذج…", systemImage: "square.grid.2x2") }
            } label: {
                HStack(spacing: 6) {
                    Text("صوت").fontWeight(.bold)
                    Text(activeTitle).foregroundStyle(.secondary).lineLimit(1)
                    statusDot
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .alert("النماذج السحابية", isPresented: $askCloudConsent) {
                Button("موافق") {
                    UserDefaults.standard.set(true, forKey: "cloudConsent")
                    if let c = pendingCloud { CloudLLM.setActive(c) }
                    pendingCloud = nil; cloudTick += 1
                }
                Button("إلغاء", role: .cancel) { pendingCloud = nil }
            } message: {
                Text("النموذج السحابي يرسل لخوادم الخدمة اللي اخترتها: رسايلك والمحادثة السابقة والصور المرفقة (وفي الوكيل نص الشاشة وصورتها)، حسب سياسة خصوصيتها. الطبقات المجانية ممكن تستخدم البيانات لتحسين خدماتها. هالتنبيه يطلع مرة وحدة.")
            }

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

    private var activeTitle: String {
        let _ = cloudTick
        if let c = CloudLLM.active { return c.short }
        if ComputeMode.current == "cpu" { return GGUFSpec.active.name }
        return settings.llm.title
    }

    /// كرت الشاشة: نطفي السحابي، ونرجع الإعداد لكرت الشاشة لو كان «المعالج» («تلقائي» يبقى)
    private func pickGPU(_ m: LLMOption) {
        CloudLLM.setActive(nil)
        if ComputeMode.current == "cpu" { UserDefaults.standard.set("gpu", forKey: "llmDevice"); slog("chat: menu → gpu") }
        models.activate(m)
        cloudTick += 1
    }

    /// المعالج: نطفي السحابي، ونختار نموذج المعالج ونحوّل الإعداد للمعالج
    private func pickCPU(_ s: GGUFSpec) {
        CloudLLM.setActive(nil)
        GGUFSpec.setActive(s)
        UserDefaults.standard.set("cpu", forKey: "llmDevice")
        slog("chat: menu → cpu \(s.id)")
        cloudTick += 1
    }

    /// سحابي: تنبيه الخصوصية أول مرة
    private func pickCloud(_ c: CloudProvider) {
        if CloudLLM.consent { CloudLLM.setActive(c); cloudTick += 1 }
        else { pendingCloud = c; askCloudConsent = true }
    }

    @ViewBuilder private var statusDot: some View {
        let _ = cloudTick
        if CloudLLM.active != nil {
            Image(systemName: "cloud.fill").foregroundStyle(.blue).font(.caption)
        } else if LLMService.onCPU, models.llm == .idle, LlamaModelFile.isDownloaded {
            Image(systemName: "cpu").foregroundStyle(.secondary).font(.caption)
        } else {
        switch models.llm {
        case .ready: EmptyView()
        case .loading(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        case .preparing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
        }
    }

    // MARK: الرسائل

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if (store.current?.messages ?? []).isEmpty && !store.isGenerating {
                        EmptyState(startVoice: startVoice, cloudTick: cloudTick)
                            .padding(.top, 120)
                    }
                    ForEach(store.current?.messages ?? []) { m in
                        MessageRow(message: m).equatable().id(m.id)
                    }
                    if store.isGenerating {
                        StreamingRow(live: store.live) { if nearBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                            .id("stream")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // يفتح على آخر رسالة، ولما تتغيّر المساحة (الكيبورد) يبقى ملزّق تحت
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height - (g.contentOffset.y + g.containerSize.height) < 120
            } action: { _, v in
                // نمو الرد يبعد آخر المحادثة مؤقتًا: ما نعتبره «طلع لفوق» إلا لو المستخدم هو اللي سحب
                if userScrolling || v { nearBottom = v }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .onAppear { scrollToEnd(proxy, delayed: true) }
            .onChange(of: store.current?.messages.count) {
                // رسالة جديدة: ننزل لو المستخدم تحت، أو لو آخر رسالة منه (أرسل للتو)
                if nearBottom || store.current?.messages.last?.role == .user {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: store.currentID) { scrollToEnd(proxy, delayed: true) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if nearBottom { scrollToEnd(proxy, delayed: true) }
            }
        }
    }

    /// ينزل لآخر المحادثة (مرة الحين ومرة بعد ما يخلص التخطيط/حركة الكيبورد، لأن LazyVStack يقيس متأخر)
    private func scrollToEnd(_ proxy: ScrollViewProxy, delayed: Bool) {
        proxy.scrollTo("bottom", anchor: .bottom)
        nearBottom = true
        guard delayed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            // أول مرة يطلع من طافي: نعرض تنبيه الإنترنت مرة وحدة
            if net.mode == .off, !netWarned { webAsk = true } else { net.cycle() }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.body.weight(.medium))
                    .foregroundStyle(net.mode == .off ? Color.secondary : Theme.accent)
                    .frame(width: 34, height: 44)
                    .background(net.mode == .on ? Theme.accent.opacity(0.18) : .clear, in: Circle())
                if net.mode == .auto {
                    Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent).offset(x: -2, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("بحث في الويب: \(net.modeLabel)")
        .alert("بيتم الوصول للإنترنت", isPresented: $webAsk) {
            Button("متابعة") { netWarned = true; net.cycle() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("سؤالك بيروح لمحرك بحث (DuckDuckGo، أو ويكيبيديا كبديل) عشان يجيب صفحات، والباقي يظل على جوالك. لما تقفل الزر ينقطع التطبيق عن الإنترنت.")
        }
    }

    /// تفكير عميق (لكل محادثة)
    private var thinkButton: some View {
        Button {
            store.cycleThinkMode()
        } label: {
            let m = store.thinkMode
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "brain")
                    .font(.body.weight(.medium))
                    .foregroundStyle(m == .off ? Color.secondary : Theme.accent)
                    .frame(width: 34, height: 44)
                    .background(m == .on ? Theme.accent.opacity(0.18) : .clear, in: Circle())
                if m == .auto {
                    Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent).offset(x: -2, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("تفكير عميق: \(store.thinkMode.label)")
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
                    ComposerField(text: $draft, placeholder: dictation.isRecording ? "أسمعك…" : "اكتب رسالة",
                                  focused: $focused, clearToken: sendGen)

                    Button {
                        if dictation.isRecording {
                            let gen = sendGen
                            dictation.stop { text in
                                guard gen == sendGen else { return }
                                draft += (draft.isEmpty ? "" : " ") + text
                            }
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
        guard models.llm.isReady || CloudLLM.active != nil
                || (LLMService.onCPU && LlamaModelFile.isDownloaded) else {
            store.error = models.llm.isBusy ? "النموذج للحين يتجهز، لحظات." : "اختر نموذج ونزّله من شاشة النماذج أول."
            if !models.llm.isBusy { showModels = true }
            return
        }
        // النص الفعلي في الخانة (إملاء لوحة المفاتيح ممكن ما حدّث draft)
        let t = ComposerField.currentText().flatMap { $0.isEmpty ? nil : $0 } ?? draft
        let atts = pending
        sendGen += 1
        if dictation.isRecording { dictation.stop { _ in } }
        draft = ""
        pending = []
        // التفضية الفعلية (وإنهاء إملاء النظام) تصير داخل ComposerField لما يتغير sendGen
        store.send(t, attachments: atts, web: net.mode == .on, webAuto: net.mode == .auto) { failed in draft = failed; pending = atts }
    }

    private func startVoice() {
        focused = false
        store.stop()
        voiceMode = true
    }
}

struct EmptyState: View {
    var startVoice: () -> Void
    var cloudTick: Int = 0
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            OrbView(mic: 0, out: 0, state: .idle, animated: false)
                .frame(width: 110, height: 110)
                .scaleEffect(appear ? 1 : 0.6)
                .opacity(appear ? 1 : 0)
            Text("وش في بالك؟").font(.title2.weight(.semibold))
            let _ = cloudTick
            Text(CloudLLM.active.map { "النموذج السحابي: \($0.short) — رسايلك تروح لسيرفراته" }
                 ?? "النموذج يشتغل على جوالك، والإنترنت مقفول إلا إذا شغّلته")
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
                    if message.autoSearch == true {
                        Label("بحث في الويب", systemImage: "globe")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    if let n = message.notice {
                        Label(n, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    if let th = message.thinking, !th.isEmpty {
                        ThinkingSection(text: th, seconds: message.thinkSeconds, live: false, auto: message.autoThink == true)
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
        .onChange(of: live.thinking) { onGrow() }
        .onChange(of: live.status) { onGrow() }
    }
}

/// قسم التفكير: رمادي ومطوي افتراضيًا.
struct ThinkingSection: View {
    let text: String
    let seconds: Double?
    let live: Bool
    var auto = false
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
        if let s = seconds { return (auto ? "فكّر تلقائيًا " : "فكّر لمدة ") + "\(max(1, Int(s.rounded())))ث" }
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
