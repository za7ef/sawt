import SwiftUI
import ImagePlayground

/// قسم «الصور» في صفحة النماذج: اختيار المحرك، تنزيل/حذف Stable Diffusion، وفحص Image Playground
struct ImageModelsSection: View {
    @ObservedObject private var sd = SDModels.shared
    @AppStorage("imageEngine") private var engineRaw = ""
    @AppStorage("playgroundStyle") private var styleID = ""
    @State private var styles: [ImagePlaygroundStyle] = []
    @State private var probeNote: String?
    @State private var probing = false
    @State private var confirmDelete: ImageEngine?
    @AppStorage("imageEnhance") private var enhance = true

    var body: some View {
        Section {
            Picker("المحرك", selection: $engineRaw) {
                Text("ما اخترت").tag("")
                ForEach(ImageEngine.allCases) { e in Text("\(e.title) · \(e.tag)").tag(e.rawValue) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("حسّن الوصف بالنموذج", isOn: $enhance)
                Text(enhance
                     ? "الوصف العربي يكتبه نموذج المحادثة بالإنجليزي قبل الرسم. الوصف الإنجليزي يروح مباشرة دايمًا (أسرع وبدون تحميل النموذج)."
                     : "الوصف العربي يروح زي ما هو: Stable Diffusion وImage Playground ما يفهمون عربي، Gemini يفهمه. الإنجليزي يروح مباشرة.")
                    .font(.caption).foregroundStyle(enhance ? Color.secondary : Color.orange)
            }
            ForEach([ImageEngine.sd21, .sdTurbo]) { sdRow($0) }
            playgroundRow
        } header: {
            Text("الصور")
        } footer: {
            Text("ما نبدّل بين المحركات تلقائيًا: لو المختار ما اشتغل يقول لك السبب. Stable Diffusion يشتغل على جوالك (يفك نموذج المحادثة وقت الرسم ويرجعه بعدين). Gemini مدفوع وما له مجاني: تقريبًا ‎$0.067 للصورة (1K)، وLite تقريبًا ‎$0.034، ويستخدم مفتاح Gemini حقك.")
        }
        .confirmationDialog("تحذف النموذج؟", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) { if let e = confirmDelete { sd.delete(e) }; confirmDelete = nil }
        }
    }

    @ViewBuilder private func sdRow(_ e: ImageEngine) -> some View {
        let installed = SDModels.installed(e)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title)
                    Text(e == .sd21 ? "512×512، ٢٠ خطوة، ~1.1 GB" : "512×512، خطوتين، ~1 GB — أسرع بس جودته أقل")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch sd.state[e] ?? .idle {
                case .downloading:
                    Button("إلغاء") { sd.cancel(e) }.buttonStyle(.borderless)
                default:
                    if installed {
                        Button(role: .destructive) { confirmDelete = e } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    } else {
                        Button("تنزيل") { sd.download(e) }.buttonStyle(.borderless)
                    }
                }
            }
            switch sd.state[e] ?? .idle {
            case .downloading(let p):
                ProgressView(value: p) { Text(String(format: "%ld٪", Int(p * 100))).font(.caption2) }
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.red)
            case .idle:
                if installed { Text("منزّل ✓").font(.caption).foregroundStyle(.green) }
            }
        }
    }

    private var playgroundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image Playground")
                    Text("من Apple Intelligence على جوالك. رسوم كرتونية، والوصف يروح بالإنجليزي.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(probing ? "…" : "افحص") {
                    probing = true
                    Task {
                        let r = await PlaygroundStyles.probe()
                        styles = r.styles
                        probeNote = r.error.map { "ما يشتغل: \($0)" } ?? "شغّال ✓ (\(r.styles.count) أنماط)"
                        probing = false
                    }
                }
                .buttonStyle(.borderless)
                .disabled(probing)
            }
            if let n = probeNote {
                Text(n).font(.caption).foregroundStyle(styles.isEmpty ? Color.red : Color.green)
            }
            if !styles.isEmpty {
                Picker("النمط", selection: $styleID) {
                    Text("تلقائي").tag("")
                    ForEach(styles, id: \.id) { s in Text(PlaygroundStyles.label(s)).tag(s.id) }
                }
            }
        }
    }
}
