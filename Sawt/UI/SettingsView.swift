import SwiftUI

// MARK: - الإعدادات: قائمة قصيرة، وكل مجموعة لها صفحة

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var memory = MemoryStore.shared
    @AppStorage("llmDevice") private var llmDevice = "gpu"
    @AppStorage("imageEngine") private var imageEngine = ""
    @State private var used: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SettingsRow(icon: "waveform", color: .purple, title: "الصوت والمكالمة", sub: voiceName) { VoiceSettingsPage() }
                    SettingsRow(icon: "cpu", color: .blue, title: "النماذج", sub: modelSummary) { ModelsView(embedded: true) }
                    SettingsRow(icon: "paintpalette.fill", color: .pink, title: "الصور", sub: ImageEngine(rawValue: imageEngine)?.title ?? "ما اخترت محرك") { ImageSettingsPage() }
                    SettingsRow(icon: "iphone.gen3", color: .orange, title: "الوكيل والتحكم بالجوال", sub: "تجريبي") { PhoneControlView() }
                }
                Section {
                    SettingsRow(icon: "person.fill", color: .teal, title: "عنك والشخصية", sub: "الذاكرة: \(memory.items.count)") { ProfileSettingsPage() }
                    SettingsRow(icon: "lock.shield.fill", color: .green, title: "الخصوصية والسحابة", sub: CloudLLM.active.map { "سحابي: \($0.title)" } ?? "على الجهاز") { PrivacyCloudPage() }
                    SettingsRow(icon: "internaldrive.fill", color: .gray, title: "التخزين والتشخيص", sub: used) { StorageDiagPage() }
                }
                Section {
                    SettingsRow(icon: "info", color: .indigo, title: "حول صوت", sub: AppVersion.label) { AboutPage() }
                }
            }
            .task {
                let u = await Task.detached(priority: .utility) { Storage.usage() }.value
                used = Storage.format(u.models + u.whisper + u.cache)
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }

    private var voiceName: String {
        Catalog.allVoices.first { $0.id == settings.voiceID }?.title ?? "صوت آبل"
    }

    private var modelSummary: String {
        if let c = CloudLLM.active { return "سحابي: \(c.title)" }
        let dev = llmDevice == "cpu" ? "المعالج" : llmDevice == "auto" ? "تلقائي" : "كرت الشاشة"
        let name = llmDevice == "cpu" ? GGUFSpec.active.name : (Catalog.llms.first { $0.id == settings.llmID }?.title ?? "")
        return name.isEmpty ? dev : "\(name) • \(dev)"
    }
}

/// صف في القائمة الرئيسية: أيقونة ملونة ٢٨ نقطة + عنوان + سطر رمادي
struct SettingsRow<Dest: View>: View {
    let icon: String
    let color: Color
    let title: String
    var sub: String?
    @ViewBuilder let dest: () -> Dest

    var body: some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if let sub, !sub.isEmpty {
                        Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - الصوت والمكالمة

struct VoiceSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager
    @AppStorage("showCallDebug") private var showCallDebug = false
    @AppStorage("allowAppleServerSTT") private var allowAppleServer = false
    @ObservedObject private var namaa = NamaaVoice.shared
    /// خطوات توليد نماء: أقل = أسرع وجودة أقل. "جرّب" يستخدم نفس الاختيار عشان تقارن بأذنك
    @AppStorage("namaaSteps") private var namaaSteps = 7
    @ObservedObject private var voiceDL = VoiceDownloads.shared
    @State private var namaaWarn = false
    @State private var confirmNamaaDelete = false

    var body: some View {
        Form {
                Section {
                    ForEach(Catalog.voices) { v in
                        Button {
                            settings.voiceID = v.id
                            models.voiceChanged()
                            if v.kind == .namaa { namaaWarn = true }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.title).foregroundStyle(.primary)
                                    Text(v.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.voiceID == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    Button {
                        Speaker.shared.speak("هلا والله! أنا صوت، أسمعك وأرد عليك على طول. وش ودك نسولف فيه اليوم؟")
                    } label: {
                        Label("جرّب الصوت", systemImage: "play.circle")
                    }
                } header: {
                    Text("الصوت")
                } footer: {
                    Text("ننصح بنبرة سعودية للمكالمات. الإنجليزي يُقرأ بصوت آبل.")
                }

                Section {
                    ForEach(VoiceDownloads.items) { item in
                        downloadRow(item)
                    }
                    namaaDownloadRow
                } header: {
                    Text("أصوات للتنزيل")
                } footer: {
                    Text("تنزل مرة وحدة وتشتغل بدون نت. التراخيص في «حول صوت».")
                }

                Section("سرعة الكلام") {
                    Slider(value: $settings.speechRate, in: 0.7...1.4, step: 0.05) {
                        Text("السرعة")
                    } minimumValueLabel: { Text("أبطأ") } maximumValueLabel: { Text("أسرع") }
                }

                Section {
                    Slider(value: $settings.patience, in: 0...1) {
                        Text("الصبر")
                    } minimumValueLabel: { Text("سريع") } maximumValueLabel: { Text("صبور") }
                } header: {
                    Text("متى يرد")
                } footer: {
                    Text("سريع: يرد أول ما تسكت. صبور: يعطيك وقت تفكر.")
                }

                Section {
                    Picker("اللغة", selection: $settings.language) {
                        Text("تلقائي").tag("auto")
                        Text("عربي").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    if settings.sttID == "apple" && !AppleSTT.supportsOnDevice {
                        Toggle("اسمح لسمع آبل يستخدم الإنترنت", isOn: $allowAppleServer)
                    }
                } header: {
                    Text("لغة السمع")
                } footer: {
                    if settings.sttID == "apple" && !AppleSTT.supportsOnDevice {
                        Text("جوالك يحتاج نت عشان يسمع العربي بسمع آبل. البديل بدون نت: Whisper من النماذج.")
                    }
                }

                Section("المكالمة") {
                    Toggle("معلومات التشخيص في المكالمة", isOn: $showCallDebug)
                }

                Section {
                    namaaRow
                } header: {
                    Text("متقدم: نماء (تجريبي)")
                } footer: {
                    Text("أبطأ ويسخّن الجوال. خطوات أقل = أسرع، أكثر = أوضح.")
                }

        }
        .alert("نماء ثقيل على المكالمات", isPresented: $namaaWarn) {
            Button("تمام") {}
        } message: {
            Text("يتأخر الرد لأنه يولّد كل جملة كاملة قبل ما يتكلم، ويسخّن الجوال.")
        }
        .confirmationDialog("تحذف صوت نماء؟", isPresented: $confirmNamaaDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { namaa.delete(); models.voiceChanged() }
        }
        .navigationTitle("الصوت والمكالمة")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func downloadRow(_ item: VoiceDownloads.Item) -> some View {
        let title = Catalog.allVoices.first { $0.id == item.id }?.title ?? item.id
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                switch voiceDL.state[item.id] ?? .idle {
                case .downloading(let p):
                    ProgressView(value: p).frame(maxWidth: 160)
                case .failed(let m):
                    Text("ما كمل: \(m)").font(.caption).foregroundStyle(.red)
                case .idle:
                    Text(voiceDL.installed(item) ? "نازل على جوالك" : item.approx).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if voiceDL.installed(item) {
                Button(role: .destructive) {
                    if settings.voiceID == item.id { settings.voiceID = "apple" }
                    voiceDL.delete(item); models.voiceChanged()
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            } else if case .downloading = voiceDL.state[item.id] ?? .idle {
                EmptyView()
            } else {
                Button("تنزيل") { voiceDL.download(item) }.buttonStyle(.borderless)
            }
        }
    }

    /// نماء في قائمة التنزيلات: الحالة + تنزيل/حذف
    @ViewBuilder private var namaaDownloadRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(Catalog.namaaVoice?.title ?? "نماء سعودي (تجريبي)")
                switch namaa.state {
                case .downloading(let p):
                    ProgressView(value: p).frame(maxWidth: 160)
                case .converting:
                    Text("يجهّز النموذج… (دقيقة تقريبًا)").font(.caption).foregroundStyle(.secondary)
                case .failed(let m):
                    Text("ما كمل: \(m)").font(.caption).foregroundStyle(.red)
                case .ready:
                    Text("نازل على جوالك").font(.caption).foregroundStyle(.secondary)
                case .notDownloaded:
                    Text("~1.4 GB تنزيل • ~700 MB بعدها").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch namaa.state {
            case .ready:
                Button(role: .destructive) { confirmNamaaDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            case .downloading:
                Button("إلغاء", role: .cancel) { namaa.cancel() }.buttonStyle(.borderless)
            case .converting:
                ProgressView()
            case .notDownloaded, .failed:
                Button("تنزيل") { namaa.download() }.buttonStyle(.borderless)
            }
        }
    }

    /// متقدم: تجربة نماء وخطواته (التنزيل والحذف في «أصوات للتنزيل»)
    @ViewBuilder private var namaaRow: some View {
        if case .ready = namaa.state {
            Button {
                namaa.test()
            } label: {
                HStack {
                    Label("جرّب", systemImage: "play.circle")
                    Spacer()
                    if namaa.testing { ProgressView() }
                }
            }
            .disabled(namaa.testing)
            Picker("الخطوات", selection: $namaaSteps) {
                Text("6 (أسرع)").tag(6)
                Text("7 (مقترح)").tag(7)
                Text("8").tag(8)
                Text("16 (أعلى جودة، بطيء)").tag(16)
            }
            if let r = namaa.lastTest {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("نزّله من «أصوات للتنزيل» فوق.").foregroundStyle(.secondary)
        }
    }

}

// MARK: - طريقة التشغيل (أعلى صفحة النماذج)

struct RunModeSection: View {
    @AppStorage("llmDevice") private var llmDevice = "gpu"
    @ObservedObject private var llamaDL = LlamaDownloader.shared
    @State private var cpuWarn = false
    @State private var cpuTest: String?

    var body: some View {
                Section {
                    Picker("تشغيل النموذج", selection: $llmDevice) {
                        Text("كرت الشاشة").tag("gpu")
                        Text("المعالج").tag("cpu")
                        Text("تلقائي").tag("auto")
                    }
                    .pickerStyle(.segmented)
                    .alert("المعالج", isPresented: $cpuWarn) {
                        Button("تمام", role: .cancel) {}
                    } message: {
                        Text("يشتغل بالخلفية لكن أبطأ من كرت الشاشة.")
                    }
                    .onChange(of: llmDevice) { _, v in
                        Task.detached(priority: .utility) { await LLMService.shared.warmUp(reason: "switch \(v)") }
                        slog("settings: llmDevice=\(v)")
                        if v == "cpu" { cpuWarn = true }
                        if v != "gpu" {
                            cpuTest = "يختبر المعالج…"
                            Task {
                                let r = await LLMService.shared.cpuSelfTest()
                                cpuTest = r.ok ? "المعالج يشتغل (\(r.info))" : "المعالج ما اشتغل: \(r.info)"
                                if !r.ok && r.info != "نموذج المعالج مو منزّل" { llmDevice = "gpu" }
                            }
                        }
                    }
                    if llmDevice != "gpu" {
                        if llamaDL.downloaded {
                            HStack {
                                Text("\(LlamaModelFile.spec.name) جاهز (\(LlamaModelFile.sizeText))")
                                Spacer()
                                Button("احذف", role: .destructive) { llamaDL.delete() }.buttonStyle(.borderless)
                            }
                        } else if llamaDL.running {
                            ProgressView(value: llamaDL.progress) { Text("ينزّل نموذج المعالج… \(Int(llamaDL.progress * 100))٪") }
                            Button("إلغاء", role: .destructive) { llamaDL.cancel() }
                        } else {
                            Button("نزّل \(LlamaModelFile.spec.name) (\(LlamaModelFile.sizeText))") { llamaDL.start() }
                            Text("المتوفر: \(ByteCountFormatter.string(fromByteCount: LlamaModelFile.freeBytes, countStyle: .file))").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !llamaDL.message.isEmpty { Text(llamaDL.message).font(.footnote) }
                    }
                } header: {
                    Text("التشغيل")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("كرت الشاشة أسرع، والمعالج يكمّل بالخلفية. تلقائي: كرت الشاشة قدّام والمعالج بالخلفية.")
                        if let cpuTest { Text(cpuTest).foregroundStyle(cpuTest.contains("ما اشتغل") ? .red : .secondary) }
                    }
                }

                if llmDevice != "gpu" {
                    Section("متقدم") {
                        Button("اختبر المعالج") {
                        cpuTest = "يختبر المعالج…"
                        Task {
                            let r = await LLMService.shared.cpuSelfTest()
                            cpuTest = r.ok ? "المعالج يشتغل (\(r.info))" : "المعالج ما اشتغل: \(r.info)"
                        }
                    }.disabled(!llamaDL.downloaded)
                    Button("اختبر سرعة الخيوط (٢/٤/٦)") {
                        cpuTest = "يقيس السرعة… (دقيقة تقريبًا)"
                        Task { cpuTest = await LLMService.shared.cpuThreadBench() }
                    }.disabled(!llamaDL.downloaded)
                    }
                }
    }
}

// MARK: - الصور

struct ImageSettingsPage: View {
    var body: some View {
        List { ImageModelsSection() }
            .navigationTitle("الصور")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - عنك والشخصية

struct ProfileSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var memory = MemoryStore.shared

    var body: some View {
        Form {
            Section {
                TextField("اسمك", text: $settings.userName)
                Picker("خاطبني بصيغة", selection: $settings.addressForm) {
                    Text("بدون تحديد").tag("")
                    Text("مذكر").tag("m")
                    Text("مؤنث").tag("f")
                }
            } header: {
                Text("عنك")
            } footer: {
                Text("اختياري، وعلى جوالك بس.")
            }

            Section {
                NavigationLink {
                    MemoryView()
                } label: {
                    LabeledContent("الذاكرة", value: "\(memory.items.count)")
                }
            } footer: {
                Text("محفوظة على جوالك بس، وتقدر تعدّلها.")
            }

            Section {
                TextEditor(text: $settings.persona).frame(minHeight: 160)
                Button("رجّع الافتراضي") { settings.persona = AppSettings.defaultPersona }
            } header: {
                Text("شخصية المساعد")
            }
        }
        .navigationTitle("عنك والشخصية")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - الخصوصية والسحابة

struct PrivacyCloudPage: View {
    var body: some View {
        Form {
            CloudSections(showActivate: true)
            Section {
                NavigationLink("سياسة الخصوصية") { MarkdownPage(title: "سياسة الخصوصية", file: "privacy") }
            }
        }
        .navigationTitle("الخصوصية والسحابة")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - التخزين والتشخيص

struct StorageDiagPage: View {
    @EnvironmentObject var models: ModelManager
    @State private var usage: Storage.Usage?
    @State private var confirmAll = false
    @State private var unused: [Storage.ModelFolder] = []
    @State private var shareURL: URL?

    var body: some View {
        Form {
            Section {
                if let u = usage {
                    LabeledContent("النماذج اللغوية", value: Storage.format(u.models))
                    LabeledContent("نماذج السمع", value: Storage.format(u.whisper))
                    LabeledContent("الكاش", value: Storage.format(u.cache))
                } else {
                    HStack { ProgressView(); Text("يحسب…").foregroundStyle(.secondary) }
                }
                if !unused.isEmpty {
                    Button(role: .destructive) {
                        for f in unused { models.deleteFolder(f) }
                        unused = []
                        Task { await refreshUsage() }
                    } label: {
                        LabeledContent("حذف ملفات غير مستخدمة",
                                       value: Storage.format(unused.reduce(0) { $0 + $1.bytes }))
                    }
                }
                Button("حذف الكاش") {
                    Task.detached { Storage.clearCache() ; await refreshUsage() }
                }
            } header: {
                Text("التخزين")
            } footer: {
                Text("حذف الكاش ما يمسح النماذج.")
            }

            Section("التشخيص") {
                Button {
                    shareURL = Log.shared.export()
                } label: {
                    Label("تصدير السجل", systemImage: "square.and.arrow.up")
                }
                LabeledContent("ذاكرة التطبيق", value: "\(RAM.footprintMB) MB")
                LabeledContent("حرارة الجوال", value: ThermalWatch.label)
            }

            Section {
                Button("حذف كل النماذج", role: .destructive) { confirmAll = true }
            }
        }
        .task { await refreshUsage() }
        .confirmationDialog("تحذف كل النماذج من الجوال؟", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) {
                models.deleteAllModels()
                Task { await refreshUsage() }
            }
        } message: { Text("بتحتاج تنزلها من جديد.") }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ActivityView(items: [u]) }
        }
        .navigationTitle("التخزين والتشخيص")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refreshUsage() async {
        let u = await Task.detached(priority: .utility) { Storage.usage() }.value
        let d = models.downloaded, s = models.downloadedSTT, busy = models.downloadingID
        let list = await Task.detached(priority: .utility) {
            Storage.modelFolders(downloaded: d, downloadedSTT: s).filter { f in
                if case .llm(let r) = f.kind, r == busy { return false }
                return f.isOrphan && f.bytes > 1_000_000
            }
        }.value
        await MainActor.run { usage = u; unused = list }
    }
}

// MARK: - حول صوت

struct AboutPage: View {
    var body: some View {
        Form { AboutSection() }
            .navigationTitle("حول صوت")
            .navigationBarTitleDisplayMode(.inline)
    }
}
