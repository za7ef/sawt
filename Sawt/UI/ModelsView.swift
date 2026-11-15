import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var customRepo = ""
    @State private var refresh = 0
    @State private var confirmDelete: LLMOption?
    @State private var confirmSTT: STTOption?
    @State private var confirmAll = false
    @State private var files: [Storage.ModelFolder] = []
    /// تبويب النماذج اللغوية: كرت الشاشة (MLX) أو المعالج (llama.cpp)
    @State private var tab = CloudLLM.active != nil ? "cloud" : (UserDefaults.standard.string(forKey: "llmDevice") == "cpu" ? "cpu" : "gpu")

    private let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("نوع التشغيل", selection: $tab) {
                        Text("كرت الشاشة").tag("gpu")
                        Text("المعالج").tag("cpu")
                        Text("النماذج السحابية").tag("cloud")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if tab == "cloud" {
                    CloudSections(showActivate: true)
                } else if tab == "cpu" {
                    Section {
                        ForEach(GGUFSpec.all) { CPUModelRow(spec: $0, ramGB: ramGB) }
                    } header: {
                        Text("نماذج المعالج")
                    } footer: {
                        Text("المختار هنا يشتغل كل ما كان التشغيل على المعالج: إعداد «المعالج»، أو «تلقائي» والتطبيق بالخلفية — للدردشة والمكالمة والوكيل. أبطأ من كرت الشاشة لكنه يكمل بالخلفية.")
                    }
                } else {
                Section {
                    ForEach(Catalog.builtInLLMs) { row($0) }
                } header: {
                    Text("نماذج كرت الشاشة")
                } footer: {
                    Text("ذاكرة جهازك تقريبًا \(String(format: "%.0f", ramGB)) GB. النماذج تنزل من Hugging Face مرة وحدة، وبعدها تشتغل على الجهاز بدون إنترنت. المختار هنا يشتغل والتطبيق قدّام (كرت الشاشة).")
                }

                Section("نموذج مخصص") {
                    ForEach(Catalog.customLLMs) { row($0) }
                    HStack {
                        TextField("mlx-community/اسم-النموذج", text: $customRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        Button("إضافة") {
                            Catalog.addCustom(customRepo)
                            customRepo = ""
                            refresh += 1
                        }
                        .disabled(!customRepo.contains("/"))
                    }
                }
                }

                Section {
                    ForEach(Catalog.stts) { s in
                        Button {
                            settings.sttID = s.id
                            models.loadSTT()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).foregroundStyle(.primary)
                                    Text("\(s.subtitle) • \(s.approxSize)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.sttID == s.id { phaseView(models.stt) }
                                else if models.downloadedSTT.contains(s.id) {
                                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                                }
                                if s.id != "apple" && models.downloadedSTT.contains(s.id) {
                                    Button(role: .destructive) { confirmSTT = s } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } header: {
                    Text("السمع (تحويل الكلام لنص)")
                } footer: {
                    if let p = models.stt.progress {
                        Text("ينزل… \(Int(p * 100))٪")
                    } else if models.stt == .preparing {
                        Text("يجهّز نموذج السمع. أول مرة ممكن ياخذ دقيقة أو دقيقتين.")
                    } else if case .failed(let e) = models.stt {
                        Text(e).foregroundStyle(.red)
                    } else {
                        Text("اضغط على النموذج عشان ينزل ويشتغل.")
                    }
                }

                Section {
                    if files.isEmpty {
                        Text("ما فيه ملفات نماذج على الجهاز").foregroundStyle(.secondary)
                    }
                    ForEach(files) { f in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.name).font(.subheadline).lineLimit(1)
                                    .environment(\.layoutDirection, .leftToRight)
                                Text(f.statusText).font(.caption).foregroundStyle(f.isOrphan ? .orange : .secondary)
                            }
                            Spacer()
                            Text(Storage.format(f.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                models.deleteFolder(f)
                                reloadFiles()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("حذف كل النماذج", role: .destructive) { confirmAll = true }
                } header: {
                    Text("الملفات على الجهاز")
                } footer: {
                    Text("كل مجلدات النماذج الموجودة فعليًا، حتى التنزيلات الناقصة والقديمة.")
                }
            }
            .task { reloadFiles() }
            .id(refresh)
            .confirmationDialog("تحذف نموذج السمع؟", isPresented: Binding(get: { confirmSTT != nil },
                                                                     set: { if !$0 { confirmSTT = nil } }),
                                titleVisibility: .visible) {
                Button("حذف من الجهاز", role: .destructive) {
                    if let s = confirmSTT { models.deleteSTT(s.id); reloadFiles() }
                }
            }
            .confirmationDialog("تحذف كل النماذج من الجوال؟", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("حذف الكل", role: .destructive) { models.deleteAllModels(); reloadFiles() }
            }
            .navigationTitle("النماذج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
            }
            .confirmationDialog("حذف النموذج؟", isPresented: Binding(get: { confirmDelete != nil },
                                                                    set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("حذف من الجهاز", role: .destructive) {
                    if let m = confirmDelete {
                        models.delete(m)
                        reloadFiles()
                        if m.custom { Catalog.removeCustom(m.id); refresh += 1 }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ m: LLMOption) -> some View {
        let active = settings.llmID == m.id
        let isDown = models.downloaded.contains(m.id)
        let downloading = models.downloadingID == m.id
        let tooBig = m.ramGB > 0 && m.ramGB > ramGB * 0.55
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(m.title).font(.headline)
                if m.vision {
                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("يشوف الصور")
                }
                if let tag = m.tag {
                    Text(tag).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.5)), in: .capsule)
                }
                Spacer()
                if active && models.llm.isReady {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                if m.sizeGB > 0 { Label(m.sizeText, systemImage: "arrow.down.circle") }
                if m.ramGB > 0 { Label(String(format: "%.1f GB", m.ramGB), systemImage: "memorychip") }
                Label(m.speed, systemImage: "bolt")
            }
            .font(.caption).foregroundStyle(.secondary)
            .environment(\.layoutDirection, .rightToLeft)
            if m.ramGB > 0 { fitChips(m) }
            Text("العربي: \(m.arabic)" + (tooBig ? " • قد يكون ثقيل على جهازك" : ""))
                .font(.caption).foregroundStyle(tooBig ? .orange : .secondary)

            if downloading, let p = models.llm.progress {
                ProgressView(value: p) {
                    Text("ينزل… \(Int(p * 100))٪").font(.caption)
                }
            } else if active && models.llm == .preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("يجهّز النموذج في الذاكرة…").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if downloading {
                    Button("إيقاف مؤقت") { models.pauseDownload() }.buttonStyle(.glass)
                } else if !(active && (models.llm.isReady || models.llm == .preparing)) {
                    Button(isDown ? "تشغيل" : "تنزيل وتشغيل") { models.activate(m) }
                        .buttonStyle(.glassProminent)
                }
                if isDown || m.custom {
                    Button(role: .destructive) { confirmDelete = m } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                }
                if case .failed(let e) = models.llm, active {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func phaseView(_ p: ModelManager.Phase) -> some View {
        switch p {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading(let v): ProgressView(value: v).frame(width: 60)
        case .preparing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("يجهّز…").font(.caption) }
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }

    private func reloadFiles() {
        Task {
            let down = models.downloaded, downS = models.downloadedSTT
            let list = await Task.detached(priority: .utility) { Storage.modelFolders(downloaded: down, downloadedSTT: downS) }.value
            files = list
        }
    }

    /// أي آيفونات تشغّله: للكتابة وللمكالمة، وهل يناسب هالجوال.
    @ViewBuilder private func fitChips(_ m: LLMOption) -> some View {
        let text = DeviceFit.minTier(needGB: DeviceFit.textNeed(m))
        let call = DeviceFit.minTier(needGB: DeviceFit.callNeed(m))
        let fit = DeviceFit.fitHere(m)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                chip("كتابة: " + (text?.label ?? "ثقيل على الآيفون"), icon: "text.bubble")
                chip("مكالمة: " + (call?.label ?? "ثقيل على الآيفون"), icon: "phone")
            }
            switch fit {
            case .both:
                Label("يناسب جوالك", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .textOnly:
                Label("على جوالك يناسب الكتابة، المكالمة ممكن تقفل", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .none:
                Label("ثقيل على جوالك", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .unknown:
                EmptyView()
            }
        }
        .font(.caption2.weight(.semibold))
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: .capsule)
    }
}


/// بطاقة نموذج المعالج (GGUF على llama.cpp): نفس شكل بطاقات كرت الشاشة
struct CPUModelRow: View {
    let spec: GGUFSpec
    let ramGB: Double
    @ObservedObject private var dl: LlamaDownloader
    @AppStorage("cpuModel") private var activeID = GGUFSpec.active.id
    @State private var confirmDelete = false

    init(spec: GGUFSpec, ramGB: Double) {
        self.spec = spec
        self.ramGB = ramGB
        _dl = ObservedObject(wrappedValue: LlamaDownloader.of(spec))
    }

    var body: some View {
        let active = activeID == spec.id
        let fits = spec.ramGB <= ramGB * 0.55
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(spec.name).font(.headline)
                if let tag = spec.tag {
                    Text(tag).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.5)), in: .capsule)
                }
                Spacer()
                if active && dl.downloaded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                Label(spec.sizeText, systemImage: "arrow.down.circle")
                Label(String(format: "%.1f GB", spec.ramGB), systemImage: "memorychip")
                Label(spec.speed, systemImage: "bolt")
            }
            .font(.caption).foregroundStyle(.secondary)
            .environment(\.layoutDirection, .rightToLeft)
            Group {
                if fits {
                    Label("يناسب جوالك", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("ثقيل على جوالك", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption2.weight(.semibold))
            Text("العربي: \(spec.arabic) • على المعالج، يشتغل بالخلفية").font(.caption).foregroundStyle(.secondary)

            if dl.running {
                ProgressView(value: dl.progress) {
                    Text("ينزل… \(Int(dl.progress * 100))٪").font(.caption)
                }
            }
            HStack(spacing: 10) {
                if dl.running {
                    Button("إلغاء") { dl.cancel() }.buttonStyle(.glass)
                } else if !dl.downloaded {
                    Button("تنزيل وتشغيل") { dl.activateWhenDone = true; dl.start() }
                        .buttonStyle(.glassProminent)
                } else if !active {
                    Button("تشغيل") { GGUFSpec.setActive(spec); activeID = spec.id }
                        .buttonStyle(.glassProminent)
                }
                if dl.downloaded {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.glass)
                }
                if !dl.message.isEmpty && !dl.running && !dl.downloaded {
                    Text(dl.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .confirmationDialog("تحذف \(spec.name)؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف من الجهاز", role: .destructive) { dl.delete() }
        }
    }
}
