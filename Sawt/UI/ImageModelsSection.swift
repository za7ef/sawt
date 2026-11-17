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
    @AppStorage("imageEngineRetired") private var engineRetired = false

    var body: some View {
        Section {
            Picker("المحرك", selection: $engineRaw) {
                Text("لم تختر").tag("")
                ForEach(ImageEngine.allCases) { e in Text(verbatim: "\(e.title) · \(e.tag)").tag(e.rawValue) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("حسّن الوصف بالنموذج", isOn: $enhance)
                Text(enhance
                     ? L("كل وصف (عربي أو إنجليزي) يحوّله نموذج المحادثة إلى وصف إنجليزي مفصّل: الأسلوب والإضاءة والتكوين وكلمات الجودة، مع قائمة بما يجب تجنبه.")
                     : L("الوصف الإنجليزي يُرسَل مباشرة (أسرع ودون تحميل النموذج). أما العربي فيترجمه نموذج المحادثة لـStable Diffusion وImage Playground لأنهما لا يفهمان العربية، ويأخذه Gemini كما هو."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if engineRetired && engineRaw.isEmpty {
                Text("المحرك الذي كنت تختاره أُزيل من التطبيق، وحُذفت ملفاته من جهازك. اختر «واقعي» أو «فني» أو «دقيق» أو «واقعي+» وحمِّله.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach([ImageEngine.sdReal, .sdArt, .klein, .zimage]) { sdRow($0) }
            playgroundRow
        } header: {
            Text("الصور")
        } footer: {
            Text("لا نبدّل بين المحركات تلقائيًا: إن لم يعمل المحرك المختار يخبرك بالسبب. المحركات المحلية (Stable Diffusion و«دقيق» و«واقعي+») تعمل على جهازك (تُفرِّغ نموذج المحادثة أثناء الرسم ثم تعيده). Gemini مدفوع وليس له خيار مجاني: نحو ‎$0.067 للصورة (1K)، وLite نحو ‎$0.034، ويستخدم مفتاح Gemini الخاص بك.")
        }
        .confirmationDialog("حذف النموذج؟", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
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
                    Text(Self.detail(e))
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
                        Button("تحميل") { sd.download(e) }.buttonStyle(.borderless)
                    }
                }
            }
            switch sd.state[e] ?? .idle {
            case .downloading(let p):
                ProgressView(value: p) { Text(L("%@٪", String(Int(p * 100)))).font(.caption2) }
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.red)
            case .idle:
                if installed { Text("محمَّل ✓").font(.caption).foregroundStyle(.green) }
            }
        }
    }

    private static func detail(_ e: ImageEngine) -> String {
        switch e {
        case .sdReal: L("صور واقعية (أشخاص وأماكن). 512×512، ٦ خطوات، ~0.9 GB")
        case .klein: L("مبني على Bonsai من PrismML · ~4.1 GB (مع أداة الإزالة LaMa) · 512×512 بأربع خطوات. يفهم الوصف الطويل ويُخرج تفاصيل أدق، ويعدّل الصور (يحتاج جهازًا بذاكرة 8GB).")
        case .zimage: L("مبني على Z-Image Turbo من Tongyi-MAI · ~5.9 GB (أو ~3.6 GB إن كان «دقيق» محمَّلًا، لأنهما يتشاركان مُرمِّز النص) · 512×512 بثماني خطوات. أبطأ وأقوى في الواقعية (يحتاج جهازًا بذاكرة 8GB).")
        default: L("رسم وفن وخيال. 512×512، ٨ خطوات، ~1 GB")
        }
    }

    private var playgroundRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image Playground")
                    Text("تُفتح نافذة Apple والوصف جاهز لتؤكده. في iOS 27 يرسم على سحابة Apple الخاصة (يحتاج إلى الإنترنت).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("افحص") { probeNote = supportsPlayground }
                    .buttonStyle(.borderless)
            }
            if let ok = probeNote {
                Text(ok ? L("متاح ✓") : L("غير متاح: فعّل Apple Intelligence وتوليد الصور من الإعدادات، وتأكد أن لغة الجهاز ومنطقته مدعومتان."))
                    .font(.caption).foregroundStyle(ok ? Color.green : Color.red)
            }
            Picker("النمط", selection: $styleID) {
                ForEach(PlaygroundStyles.all, id: \.id) { s in Text(s.label).tag(s.id == "animation" ? "" : s.id) }
            }
        }
    }
}
