import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var customRepo = ""
    @State private var refresh = 0
    @State private var confirmDelete: LLMOption?

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

                Section("السمع (تحويل الكلام لنص)") {
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
                            }
                        }
                    }
                }
            }
            .id(refresh)
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
            }

            HStack(spacing: 10) {
                if downloading {
                    Button("إيقاف مؤقت") { models.pauseDownload() }.buttonStyle(.glass)
                } else if !(active && models.llm.isReady) {
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
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }
}
