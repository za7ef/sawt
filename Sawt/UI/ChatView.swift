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
    /// وضع البحث اللي ينتظر موافقة تنبيه الإنترنت
    @State private var webPending: NetworkGate.Mode?
    /// المستخدم قريب من آخر المحادثة؟ (لو طلع لفوق ما نسحبه لتحت مع كل رمز)
    @State private var nearBottom = true
    /// المستخدم يسحب القائمة بيده الحين (نحدّث «قريب من تحت» بس من حركته، مو من نمو الرد)
    @State private var userScrolling = false
    /// وصل شي جديد والمستخدم فوق (نقطة على زر النزول)
    @State private var hasNew = false
    @AppStorage("netWarned") private var netWarned = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            messages
            composer
        }
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(isPresented: $voiceMode) {
            VoiceModeView()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $showModels) { ModelsView() }
        .alert("المشغّل طافي — تبي أشغّله وأنفّذ المهمة؟",
               isPresented: Binding(get: { store.runnerAsk != nil }, set: { if !$0, store.runnerAsk != nil { store.answerRunnerAsk(run: false) } })) {
            Button("شغّل ونفّذ") { store.answerRunnerAsk(run: true) }
            Button("لا، دردشة عادية", role: .cancel) { store.answerRunnerAsk(run: false) }
        } message: {
            Text("المشغّل هو اللي يخليني أشوف الشاشة وأضغط بدالك، وبدونه ما أقدر أنفّذ.")
        }
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

    /// قائمة اختيار النموذج (من اسم النموذج الصغير في النص فوق)
    @ViewBuilder private var modelMenuItems: some View {
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
    }

    /// رأس بسيط: زر القائمة يمين، اسم النموذج صغير بالنص، وكبسولة (محادثة جديدة + «…») يسار
    private var topBar: some View {
        HStack(spacing: 10) {
            // زر القائمة: دائرة زجاج 44 بخطين أبيض (السفلي أقصر)، بدون لون التطبيق الأزرق
            Button(action: openDrawer) {
                VStack(alignment: .trailing, spacing: 6) {
                    Capsule().frame(width: 20, height: 2.2)
                    Capsule().frame(width: 13, height: 2.2)
                }
                .environment(\.layoutDirection, .leftToRight)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("القائمة")

            Spacer(minLength: 4)

            Menu { modelMenuItems } label: {
                HStack(spacing: 4) {
                    statusDot
                    Text(activeTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("النموذج: \(activeTitle)")
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


            Spacer(minLength: 4)

            // بالعربي أول عنصر يمين: الكتابة جوّا و«…» على الطرف الخارجي (يسار)
            HStack(spacing: 2) {
                Button { store.newConversation() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("محادثة جديدة")
                Menu {
                    Menu { modelMenuItems } label: { Label("النموذج: \(activeTitle)", systemImage: "cpu") }
                    Button { showModels = true } label: { Label("كل النماذج…", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("المزيد")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
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
                        StreamingRow(live: store.live) {
                            if nearBottom { proxy.scrollTo("bottom", anchor: .bottom) } else if !hasNew { hasNew = true }
                        }
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
            .overlay(alignment: .bottom) {
                if !nearBottom {
                    Button {
                        hasNew = false
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        nearBottom = true
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12)))
                            .overlay(alignment: .topTrailing) {
                                if hasNew { Circle().fill(Color.accentColor).frame(width: 10, height: 10).offset(x: 1, y: -1) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("انزل لآخر المحادثة")
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: nearBottom)
            .onChange(of: nearBottom) { _, v in if v { hasNew = false } }
            .onAppear { scrollToEnd(proxy, delayed: true) }
            .onChange(of: store.current?.messages.count) {
                // رسالة جديدة: ننزل لو المستخدم تحت، أو لو آخر رسالة منه (أرسل للتو)
                if !nearBottom && store.current?.messages.last?.role != .user { hasNew = true }
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

    /// «+»: المرفقات وبحث الويب والتفكير (حالتهم ظاهرة هنا وكشرائح فوق النص)
    private var attachMenu: some View {
        Menu {
            Section {
                Button { showCamera = true } label: { Label("الكاميرا", systemImage: "camera") }
                Button { showPhotos = true } label: { Label("الصور", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("الملفات", systemImage: "folder") }
            }
            Section {
                Menu {
                    Picker("بحث في الويب", selection: Binding(get: { net.mode }, set: { setWeb($0) })) {
                        Text("طافي").tag(NetworkGate.Mode.off)
                        Text("تلقائي").tag(NetworkGate.Mode.auto)
                        Text("دايم").tag(NetworkGate.Mode.on)
                    }
                } label: { Label("بحث في الويب: \(net.modeLabel)", systemImage: "globe") }
                Menu {
                    Picker("التفكير", selection: Binding(get: { store.thinkMode }, set: { store.setThinkMode($0) })) {
                        ForEach(ThinkMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { Label("التفكير: \(store.thinkMode.label)", systemImage: "brain") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 22, weight: .regular)).frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }

    /// أول مرة يطلع من طافي: تنبيه الإنترنت مرة وحدة
    private func setWeb(_ m: NetworkGate.Mode) {
        if net.mode == .off, m != .off, !netWarned { webPending = m } else { applyWeb(m) }
    }
    private func applyWeb(_ m: NetworkGate.Mode) {
        switch m {
        case .off: net.on = false
        case .auto: net.auto = true; net.on = true
        case .on: net.auto = false; net.on = true
        }
    }

    /// شرائح الحالة: تبين وش مشغّل، والضغط يطفيه
    @ViewBuilder private var stateChips: some View {
        if net.mode != .off || store.thinkMode == .on {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if net.mode != .off {
                        chip("globe", net.mode == .auto ? "بحث تلقائي" : "بحث دايم") { applyWeb(.off) }
                    }
                    if store.thinkMode == .on {
                        chip("brain", "تفكير عميق") { store.setThinkMode(.off) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }

    private func chip(_ icon: String, _ title: String, off: @escaping () -> Void) -> some View {
        Button(action: off) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)، اضغط عشان تطفيه")
    }

    private var micButton: some View {
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
                .font(.system(size: 20, weight: .regular))
                .symbolEffect(.pulse, isActive: dictation.isRecording)
                .foregroundStyle(dictation.isRecording ? .red : .primary)
                .frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(dictation.isBusy || !models.stt.isReady)
    }

    /// خانة وحدة مثل ChatGPT: «+» ثم النص ثم المايك ثم الزر الأزرق (مكالمة ← إرسال ← إيقاف)
    private var composer: some View {
        VStack(spacing: 0) {
            pendingBar
            VStack(alignment: .leading, spacing: 0) {
                stateChips
                HStack(alignment: .bottom, spacing: 4) {
                    attachMenu
                    ComposerField(text: $draft, placeholder: dictation.isRecording ? "أسمعك…" : "اسأل صوت",
                                  focused: $focused, clearToken: sendGen)
                    micButton
                    actionButton.padding(.trailing, 4)
                }
                // خانة 52: عناصر بارتفاع 44 + 4 فوق وتحت، والدائرة 36 تبعد 8 عن الحافة
                .padding(.vertical, 4)
            }
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .padding(.top, 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draft.isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.isGenerating)
            .animation(.easeOut(duration: 0.2), value: net.mode)
            .animation(.easeOut(duration: 0.2), value: store.thinkMode)
        }
        .alert("بيتم الوصول للإنترنت", isPresented: Binding(get: { webPending != nil }, set: { if !$0 { webPending = nil } })) {
            Button("متابعة") { netWarned = true; if let m = webPending { applyWeb(m) }; webPending = nil }
            Button("إلغاء", role: .cancel) { webPending = nil }
        } message: {
            Text("سؤالك بيروح لمحرك بحث (DuckDuckGo، أو ويكيبيديا كبديل) عشان يجيب صفحات، والباقي يظل على جوالك. لما تطفي البحث ينقطع التطبيق عن الإنترنت.")
        }
    }

    /// الزر الأزرق داخل الخانة: إيقاف وقت التوليد، إرسال لو فيه نص، وإلا مكالمة صوتية
    @ViewBuilder private var actionButton: some View {
        if store.isGenerating {
            Button { store.stop() } label: { blueCircle("stop.fill", size: 13) }
                .buttonStyle(.plain)
                .accessibilityLabel("إيقاف")
                .transition(.scale.combined(with: .opacity))
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty {
            Button(action: send) { blueCircle("arrow.up", size: 16) }
                .buttonStyle(.plain)
                .accessibilityLabel("إرسال")
                .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: startVoice) {
                blueCircle("waveform", size: 15)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("مكالمة صوتية")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// الزر الأزرق داخل الخانة: دائرة 36 في مساحة لمس 44
    private func blueCircle(_ icon: String, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color(red: 0.16, green: 0.42, blue: 1.0)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
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
                // رسالتك فقاعة زرقاء غامقة صغيرة في نهاية السطر (يسار بالعربي)، والرد بدون فقاعة
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    if let atts = message.attachments, !atts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(atts) { AttachmentChip(a: $0, size: 72) } }
                        }
                        .frame(maxWidth: 260)
                    }
                    Text(message.text)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    if message.viaVoice {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let m = message.model, !m.isEmpty {
                        Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
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
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let src = message.sources, !src.isEmpty {
                        SourcesList(sources: src)
                    }
                    if !streaming {
                        // صف أدوات خفيف: نسخ، قراءة، مشاركة، والباقي تحت «…»
                        HStack(spacing: 20) {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .accessibilityLabel("نسخ")
                            Button { Speaker.shared.speak(message.text) } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            .accessibilityLabel("اقرأ الرد")
                            ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("مشاركة")
                            Menu {
                                if NamaaVoice.isInstalled, let namaa = Catalog.namaaVoice {
                                    Button { Speaker.shared.speak(message.text, voice: namaa) } label: {
                                        Label("اقرأ بصوت نماء (تجريبي)", systemImage: "person.wave.2")
                                    }
                                }
                                Button { UIPasteboard.general.string = message.text } label: {
                                    Label("نسخ النص", systemImage: "doc.on.doc")
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(height: 20)
                            }
                            .accessibilityLabel("المزيد")
                            if message.viaVoice { Image(systemName: "waveform") }
                        }
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.gray.opacity(0.75))
                        .buttonStyle(.plain)
                        .padding(.top, 2)
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
