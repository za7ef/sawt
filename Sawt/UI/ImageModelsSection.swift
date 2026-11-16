import SwiftUI
import ImagePlayground

/// قسم «الصور» في صفحة النماذج: اختيار المحرك، تنزيل/حذف Stable Diffusion، وفحص Image Playground
struct ImageModelsSection: View {
    @ObservedObject private var sd = SDModels.shared
    @AppStorage("imageEngine") private var engineRaw = ""
    @AppStorage("playgroundStyle") private var styleID = ""
    @State private var probeNote: Bool?
    @Environment(\.supportsImagePlayground) private var supportsPlayground
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
                     ? "كل وصف (عربي أو إنجليزي) يكتبه نموذج المحادثة وصف إنجليزي مفصّل: الأسلوب والإضاءة والتكوين وكلمات الجودة، مع قائمة أشياء نتجنبها."
                     : "الوصف الإنجليزي يروح مباشرة (أسرع وبدون تحميل النموذج). العربي يترجمه نموذج المحادثة لـStable Diffusion وImage Playground لأنهم ما يفهمون عربي، وGemini ياخذه زي ما هو.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Text("نافذة آبل تنفتح بالوصف جاهز وتأكّد منها. في iOS 27 يرسم على سحابة آبل الخاصة (يحتاج نت).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("افحص") { probeNote = supportsPlayground }
                    .buttonStyle(.borderless)
            }
            if let ok = probeNote {
                Text(ok ? "متاح ✓" : "مو متاح: شغّل Apple Intelligence وتوليد الصور من الإعدادات، وتأكد إن لغة الجهاز ومنطقته مدعومة.")
                    .font(.caption).foregroundStyle(ok ? Color.green : Color.red)
            }
            Picker("النمط", selection: $styleID) {
                ForEach(PlaygroundStyles.all, id: \.id) { s in Text(s.label).tag(s.id == "animation" ? "" : s.id) }
            }
        }
    }
}
