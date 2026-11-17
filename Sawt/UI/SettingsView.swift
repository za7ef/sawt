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
    @State private var appLang = AppLang.choice
    @State private var showRestart = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SettingsRow(icon: "waveform", color: .purple, title: L("الصوت والمكالمة"), sub: voiceName) { VoiceSettingsPage() }
                    SettingsRow(icon: "cpu", color: .blue, title: L("النماذج"), sub: modelSummary) { ModelsView(embedded: true) }
                    SettingsRow(icon: "paintpalette.fill", color: .pink, title: L("الصور"), sub: ImageEngine(rawValue: imageEngine)?.title ?? L("لم تختر محركًا")) { ImageSettingsPage() }
                    SettingsRow(icon: "iphone.gen3", color: .orange, title: L("الوكيل والتحكم بالجهاز"), sub: L("تجريبي")) { PhoneControlView() }
                }
                Section {
                    SettingsRow(icon: "person.fill", color: .teal, title: L("عنك والشخصية"), sub: L("الذاكرة: %@", String(memory.items.count))) { ProfileSettingsPage() }
                    SettingsRow(icon: "lock.shield.fill", color: .green, title: L("الخصوصية والسحابة"), sub: CloudLLM.active.map { L("سحابي: %@", $0.title) } ?? L("على الجهاز")) { PrivacyCloudPage() }
                    SettingsRow(icon: "internaldrive.fill", color: .gray, title: L("التخزين والتشخيص"), sub: used) { StorageDiagPage() }
                }
                Section {
                    Picker(selection: $appLang) {
                        Text("حسب لغة الجهاز").tag("system")
                        Text(verbatim: "العربية").tag("ar")
                        Text(verbatim: "English").tag("en")
                    } label: {
                        Label("لغة التطبيق", systemImage: "globe")
                    }
                    .onChange(of: appLang) { _, v in
                        AppLang.set(v)
                        showRestart = true
                    }
                }
                Section {
                    SettingsRow(icon: "info", color: .indigo, title: L("حول Sowtly"), sub: AppVersion.label) { AboutPage() }
                }
            }
            .alert("تغيير اللغة", isPresented: $showRestart) {
                Button("أعد التشغيل الآن") { exit(0) }
                Button("لاحقًا", role: .cancel) {}
            } message: {
                Text("يُطبَّق التغيير بعد إعادة تشغيل التطبيق.")
            }
            .task {
                let u = await Task.detached(priority: .utility) { Storage.usage() }.value
                used = Storage.format(u.models + u.cache)
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }

    private var voiceName: String {
        Catalog.allVoices.first { $0.id == settings.voiceID }?.title ?? L("صوت Apple")
    }

    private var modelSummary: String {
        if let c = CloudLLM.active { return L("سحابي: %@", c.title) }
        let dev = llmDevice == "cpu" ? L("المعالج") : L("معالج الرسوميات")
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
    @ObservedObject private var audar = AudarVoice.shared
    @State private var confirmAudarDelete = false
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
                        Speaker.shared.speak(L("مرحبًا! أنا Sowtly، أسمعك وأرد عليك فورًا. عن ماذا تحب أن نتحدث اليوم؟"))
                    } label: {
                        Label("جرّب الصوت", systemImage: "play.circle")
                    }
                } header: {
                    Text("الصوت")
                } footer: {
                    Text("ننصح بالنبرة السعودية للمكالمات. النص الإنجليزي يُقرأ بصوت Apple.")
                }

                Section {
                    ForEach(VoiceDownloads.items) { item in
                        downloadRow(item)
                    }
                    namaaDownloadRow
                    audarDownloadRow
                } header: {
                    Text("أصوات للتحميل")
                } footer: {
                    Text("تُحمَّل مرة واحدة وتعمل دون إنترنت. التراخيص في «حول Sowtly».")
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
                    Text("متى يرد؟")
                } footer: {
                    Text("سريع: يرد بمجرد أن تتوقف عن الكلام. صبور: يمنحك وقتًا للتفكير.")
                }

                Section {
                    Picker("اللغة", selection: $settings.language) {
                        Text("تلقائي").tag("auto")
                        Text("العربية").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    if !AppleSTT.supportsOnDevice {
                        Toggle("اسمح لتعرّف Apple على الكلام باستخدام الإنترنت", isOn: $allowAppleServer)
                    }
                } header: {
                    Text("لغة التعرّف على الكلام")
                } footer: {
                    if !AppleSTT.supportsOnDevice {
                        Text("يحتاج جهازك إلى الإنترنت للتعرّف على الكلام العربي عبر Apple.")
                    }
                }

                Section("المكالمة") {
                    Toggle("معلومات التشخيص في المكالمة", isOn: $showCallDebug)
                }

                Section {
                    audarRow
                } header: {
                    Text("متقدم: أودار")
                } footer: {
                    Text("ستة أصوات من نموذج واحد، وأفضلها في اللهجة الخليجية. «جرّب» يستخدم صوت أودار المختار، أو الأول إن كان المختار صوتًا آخر.")
                }

                Section {
                    namaaRow
                } header: {
                    Text("متقدم: نماء (تجريبي)")
                } footer: {
                    Text("أبطأ ويرفع حرارة الجهاز. خطوات أقل = أسرع، وأكثر = أوضح.")
                }

        }
        .alert("نماء ثقيل على المكالمات", isPresented: $namaaWarn) {
            Button("حسنًا") {}
        } message: {
            Text("يتأخر الرد لأنه يولّد كل جملة كاملة قبل أن يتكلم، ويرفع حرارة الجهاز.")
        }
        .confirmationDialog("حذف صوت نماء؟", isPresented: $confirmNamaaDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { namaa.delete(); models.voiceChanged() }
        }
        .confirmationDialog("حذف أصوات أودار؟", isPresented: $confirmAudarDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { audar.delete(); models.voiceChanged() }
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
                    Text(L("لم يكتمل: %@", m)).font(.caption).foregroundStyle(.red)
                case .idle:
                    Text(voiceDL.installed(item) ? L("مُحمَّل على جهازك") : item.approx).font(.caption).foregroundStyle(.secondary)
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
                Button("تحميل") { voiceDL.download(item) }.buttonStyle(.borderless)
            }
        }
    }

    /// نماء في قائمة التنزيلات: الحالة + تنزيل/حذف
    @ViewBuilder private var namaaDownloadRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(Catalog.namaaVoice?.title ?? L("نماء سعودي (تجريبي)"))
                switch namaa.state {
                case .downloading(let p):
                    ProgressView(value: p).frame(maxWidth: 160)
                case .converting:
                    Text("جارٍ تجهيز النموذج… (دقيقة تقريبًا)").font(.caption).foregroundStyle(.secondary)
                case .failed(let m):
                    Text(L("لم يكتمل: %@", m)).font(.caption).foregroundStyle(.red)
                case .ready:
                    Text("مُحمَّل على جهازك").font(.caption).foregroundStyle(.secondary)
                case .notDownloaded:
                    Text("تحميل ~1.4 GB • ~700 MB بعده").font(.caption).foregroundStyle(.secondary)
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
                Button("تحميل") { namaa.download() }.buttonStyle(.borderless)
            }
        }
    }

    /// أودار في قائمة التنزيلات: الحالة + تنزيل/إلغاء/حذف
    @ViewBuilder private var audarDownloadRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("أودار (٦ أصوات)")
                switch audar.state {
                case .downloading(let p):
                    ProgressView(value: p).frame(maxWidth: 160)
                case .failed(let m):
                    Text(L("لم يكتمل: %@", m)).font(.caption).foregroundStyle(.red)
                case .ready:
                    Text("مُحمَّل على جهازك").font(.caption).foregroundStyle(.secondary)
                case .notDownloaded:
                    Text("~840 MB • عربي (فصحى وخليجي) وإنجليزي").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch audar.state {
            case .ready:
                Button(role: .destructive) { confirmAudarDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            case .downloading:
                Button("إلغاء", role: .cancel) { audar.cancel() }.buttonStyle(.borderless)
            case .notDownloaded, .failed:
                Button("تحميل") { audar.download() }.buttonStyle(.borderless)
            }
        }
    }

    /// متقدم: تجربة أودار مع الوقت والسرعة
    @ViewBuilder private var audarRow: some View {
        if case .ready = audar.state {
            Button {
                audar.test()
            } label: {
                HStack {
                    Label("جرّب", systemImage: "play.circle")
                    Spacer()
                    if audar.testing { ProgressView() }
                }
            }
            .disabled(audar.testing)
            if let r = audar.lastTest {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("حمِّله من «أصوات للتحميل» في الأعلى.").foregroundStyle(.secondary)
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
                Text("16 (أعلى جودة، أبطأ)").tag(16)
            }
            if let r = namaa.lastTest {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("حمِّله من «أصوات للتحميل» في الأعلى.").foregroundStyle(.secondary)
        }
    }

}

// MARK: - اختبارات المعالج (تبويب المعالج في النماذج)

struct CPUTestsSection: View {
    @State private var cpuTest: String?
    @State private var cpuFailed = false

    var body: some View {
        Section {
            Button("اختبر المعالج") {
                cpuTest = L("جارٍ اختبار المعالج…")
                Task {
                    let r = await LLMService.shared.cpuSelfTest()
                    cpuTest = r.ok ? L("المعالج يعمل (%@)", r.info) : L("لم يعمل المعالج: %@", r.info)
                    cpuFailed = !r.ok
                }
            }
            Button("اختبر سرعة الخيوط (٢/٤/٦)") {
                cpuTest = L("جارٍ قياس السرعة… (دقيقة تقريبًا)")
                Task { cpuTest = await LLMService.shared.cpuThreadBench() }
            }
        } header: {
            Text("متقدم")
        } footer: {
            if let cpuTest { Text(cpuTest).foregroundStyle(cpuFailed ? Color.red : Color.secondary) }
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
                Text("اختياري، ويبقى على جهازك فقط.")
            }

            Section {
                NavigationLink {
                    MemoryView()
                } label: {
                    LabeledContent("الذاكرة", value: "\(memory.items.count)")
                }
            } footer: {
                Text("محفوظة على جهازك فقط، ويمكنك تعديلها.")
            }

            Section {
                TextEditor(text: $settings.persona).frame(minHeight: 160)
                Button("استعادة الافتراضي") { settings.persona = AppSettings.defaultPersona }
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
                NavigationLink("سياسة الخصوصية") { MarkdownPage(title: L("سياسة الخصوصية"), file: "privacy") }
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
                    LabeledContent("ذاكرة التخزين المؤقت", value: Storage.format(u.cache))
                } else {
                    HStack { ProgressView(); Text("جارٍ الحساب…").foregroundStyle(.secondary) }
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
                Button("مسح ذاكرة التخزين المؤقت") {
                    Task.detached { Storage.clearCache() ; await refreshUsage() }
                }
            } header: {
                Text("التخزين")
            } footer: {
                Text("مسح ذاكرة التخزين المؤقت لا يحذف النماذج.")
            }

            Section("التشخيص") {
                Button {
                    shareURL = Log.shared.export()
                } label: {
                    Label("تصدير السجل", systemImage: "square.and.arrow.up")
                }
                LabeledContent("ذاكرة التطبيق", value: "\(RAM.footprintMB) MB")
                LabeledContent("حرارة الجهاز", value: ThermalWatch.label)
            }

            Section {
                Button("حذف كل النماذج", role: .destructive) { confirmAll = true }
            }
        }
        .task { await refreshUsage() }
        .confirmationDialog("حذف كل النماذج من الجهاز؟", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) {
                models.deleteAllModels()
                Task { await refreshUsage() }
            }
        } message: { Text("ستحتاج إلى تحميلها من جديد.") }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ActivityView(items: [u]) }
        }
        .navigationTitle("التخزين والتشخيص")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refreshUsage() async {
        let u = await Task.detached(priority: .utility) { Storage.usage() }.value
        let d = models.downloaded, busy = models.downloadingID
        let list = await Task.detached(priority: .utility) {
            Storage.modelFolders(downloaded: d).filter { f in
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
            .navigationTitle("حول Sowtly")
            .navigationBarTitleDisplayMode(.inline)
    }
}
