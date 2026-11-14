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

    private let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Catalog.builtInLLMs) { row($0) }
                } header: {
                    Text("النماذج اللغوية")
                } footer: {
                    Text("ذاكرة جهازك تقريبًا \(String(format: "%.0f", ramGB)) GB. النماذج تنزل من Hugging Face وتشتغل على الجهاز بدون إنترنت بعد التنزيل.")
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
}
