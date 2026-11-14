import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var usage: Storage.Usage?
    @State private var confirmAll = false
    @State private var unused: [Storage.ModelFolder] = []
    @AppStorage("showCallDebug") private var showCallDebug = false
    @State private var shareURL: URL?
    @ObservedObject private var namaa = NamaaVoice.shared
    @State private var namaaWarn = false
    @State private var confirmNamaaDelete = false

    var body: some View {
        NavigationStack {
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
                    Text("الأصوات العربية مدمجة في التطبيق. الجمل الإنجليزية تُقرأ بصوت آبل.")
                }

                Section {
                    namaaRow
                } header: {
                    Text("نماء سعودي (تجريبي)")
                } footer: {
                    Text("تجريبي وثقيل: ياخذ وقت قبل كل جملة ويسخّن الجوال، وثقيل على المكالمات.\nنموذج NAMAA-Saudi-TTS-V2، رخصته للاستخدام الشخصي غير التجاري.")
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
                    Text("متى يرد عليك")
                } footer: {
                    Text("سريع: يرد أول ما توقف. صبور: يعطيك وقت تفكر بين الكلام. يتطبق من المكالمة الجاية.")
                }

                Section("لغة السمع") {
                    Picker("اللغة", selection: $settings.language) {
                        Text("تلقائي").tag("auto")
                        Text("عربي").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextEditor(text: $settings.persona).frame(minHeight: 160)
                    Button("رجّع الافتراضي") { settings.persona = AppSettings.defaultPersona }
                } header: {
                    Text("شخصية المساعد")
                }

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
                            LabeledContent("حذف ملفات النماذج غير المستخدمة",
                                           value: Storage.format(unused.reduce(0) { $0 + $1.bytes }))
                        }
                    }
                    Button("حذف ملفات الكاش") {
                        Task.detached { Storage.clearCache() ; await refreshUsage() }
                    }
                    Button("حذف كل النماذج", role: .destructive) { confirmAll = true }
                } header: {
                    Text("التخزين")
                } footer: {
                    Text("الكاش: ملفات مؤقتة وتنزيلات ناقصة. حذفه ما يمسح النماذج الكاملة. تقدر تحذف نموذج معيّن من شاشة النماذج.")
                }

                Section("التشخيص") {
                    Toggle("إظهار معلومات التشخيص في المكالمة", isOn: $showCallDebug)
                    Button {
                        shareURL = Log.shared.export()
                    } label: {
                        Label("تصدير السجل", systemImage: "square.and.arrow.up")
                    }
                    LabeledContent("ذاكرة التطبيق", value: "\(RAM.footprintMB) MB")
                    LabeledContent("حرارة الجوال", value: ThermalWatch.label)
                }

                Section {
                    LabeledContent("الإصدار", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("كل شي على الجهاز", value: "بدون سيرفر")
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
            .alert("نماء ثقيل على المكالمات", isPresented: $namaaWarn) {
                Button("تمام") {}
            } message: {
                Text("بيتأخر الرد في المكالمة لأنه يولّد كل جملة كاملة قبل ما يتكلم، ويسخّن الجوال. الجمل الإنجليزية تنقرأ بصوت آبل.")
            }
            .confirmationDialog("تحذف صوت نماء؟", isPresented: $confirmNamaaDelete, titleVisibility: .visible) {
                Button("حذف", role: .destructive) { namaa.delete(); models.voiceChanged() }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }

    @ViewBuilder private var namaaRow: some View {
        switch namaa.state {
        case .notDownloaded, .failed:
            if case .failed(let msg) = namaa.state {
                Text("ما كمل: \(msg)").font(.caption).foregroundStyle(.red)
            }
            Button {
                namaa.download()
            } label: {
                LabeledContent {
                    Text("~1.4 GB تنزيل • ~700 MB بعدها")
                } label: {
                    Label("نزّل الصوت", systemImage: "arrow.down.circle")
                }
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p) { Text("ينزّل… \(Int(p * 100))٪") }
                Button("إلغاء", role: .cancel) { namaa.cancel() }.font(.caption)
            }
        case .converting:
            HStack { ProgressView(); Text("يجهّز النموذج… (دقيقة تقريبًا)").foregroundStyle(.secondary) }
        case .ready:
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
            if let r = namaa.lastTest {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
            Button("حذف صوت نماء", role: .destructive) { confirmNamaaDelete = true }
        }
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
