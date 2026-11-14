import SwiftUI
import UniformTypeIdentifiers

// تجربة «تحكم بالجوال»: يتصل بخدمات المطوّر في نفس الجوال (عبر LocalDevVPN على 10.7.0.1)
// بملف الاقتران، ويقرأ شجرة الوصول ويرسل لمسة/كتابة. للاختبار فقط قبل بناء الوكيل.

#if SAWTCTL
@_silgen_name("sawtctl_probe") private func c_probe(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_tap") private func c_tap(_ cfg: UnsafePointer<CChar>, _ x: UInt16, _ y: UInt16) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_keys") private func c_keys(_ cfg: UnsafePointer<CChar>, _ what: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_ax") private func c_ax(_ cfg: UnsafePointer<CChar>, _ waitMs: UInt32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_free") private func c_free(_ p: UnsafeMutablePointer<CChar>?)
#endif

enum PhoneControl {
    static var available: Bool {
        #if SAWTCTL
        return true
        #else
        return false
        #endif
    }

    static var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }

    static var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    static func config(host: String) -> String {
        let d: [String: String] = ["pairing_file": pairingURL.path, "host": host]
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    enum Op: Sendable { case probe, ax(UInt32), tap(UInt16, UInt16), keys(String) }

    /// يشغّل العملية في خيط خلفي (الدوال متزامنة وتحجز الخيط)
    static func run(_ op: Op, host: String) async -> String {
        let cfg = config(host: host)
        return await Task.detached(priority: .userInitiated) { () -> String in
            #if SAWTCTL
            let p: UnsafeMutablePointer<CChar>? = cfg.withCString { c in
                switch op {
                case .probe: return c_probe(c)
                case .ax(let ms): return c_ax(c, ms)
                case .tap(let x, let y): return c_tap(c, x, y)
                case .keys(let w): return w.withCString { c_keys(c, $0) }
                }
            }
            guard let p else { return "{\"ok\":false,\"error\":\"null\"}" }
            let s = String(cString: p)
            c_free(p)
            return s
            #else
            return "{\"ok\":false,\"error\":\"أداة التحكم ما انبنت في هذي النسخة\"}"
            #endif
        }.value
    }
}

struct PhoneControlView: View {
    @AppStorage("pcHost") private var host = "10.7.0.1"
    @State private var importing = false
    @State private var hasPairing = PhoneControl.hasPairing
    @State private var busy = false
    @State private var countdown = 0
    @State private var output = ""
    @State private var typeText = "مرحبا من صوت"

    var body: some View {
        Form {
            Section {
                LabeledContent("الأداة", value: PhoneControl.available ? "مبنية" : "غير مبنية")
                LabeledContent("ملف الاقتران", value: hasPairing ? "موجود" : "ناقص")
                Button("استيراد ملف الاقتران") { importing = true }
                TextField("العنوان", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("لازم LocalDevVPN شغال، وصورة المطوّر (DDI) مركّبة (مثلاً من StikDebug). نفس ملف الاقتران حق StikDebug.")
            }

            Section {
                Button("فحص الاتصال") { go(.probe, delay: false, label: "probe") }
                Button("قراءة الشاشة (بعد ٥ ثواني)") { go(.ax(4000), delay: true, label: "ax") }
                Button("لمسة في نص الشاشة (بعد ٥ ثواني)") { go(.tap(32768, 32768), delay: true, label: "tap") }
                Button("زر الهوم") { go(.keys("home"), delay: false, label: "home") }
                TextField("نص للكتابة", text: $typeText)
                Button("كتابة النص (بعد ٥ ثواني)") {
                    UIPasteboard.general.string = typeText
                    go(.keys("paste"), delay: true, label: "paste")
                }
            } header: {
                Text("اختبارات")
            } footer: {
                Text("بعد ما تضغط، روح للتطبيق اللي تبي تجرّب عليه خلال ٥ ثواني. النتيجة تنحفظ في السجل وتنسخ تلقائيًا.")
            }
            .disabled(busy || !PhoneControl.available || !hasPairing)

            if countdown > 0 {
                Section { Text("يبدأ بعد \(countdown)…") }
            }
            if busy && countdown == 0 {
                Section { HStack { ProgressView(); Text("يشتغل…") } }
            }
            if !output.isEmpty {
                Section("النتيجة") {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    Button("نسخ") { UIPasteboard.general.string = output }
                }
            }
        }
        .navigationTitle("تحكم بالجوال (تجريبي)")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let dest = PhoneControl.pairingURL
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                hasPairing = true
                output = "تم حفظ ملف الاقتران (\(data.count) بايت)"
            } catch {
                output = "فشل الاستيراد: \(error.localizedDescription)"
            }
        }
    }

    private func go(_ op: PhoneControl.Op, delay: Bool, label: String) {
        busy = true
        output = ""
        let h = host
        Task { @MainActor in
            if delay {
                for i in stride(from: 5, through: 1, by: -1) {
                    countdown = i
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = 0
            }
            let r = await PhoneControl.run(op, host: h)
            Log.shared("phonectl \(label): \(r.prefix(6000))")
            UIPasteboard.general.string = r
            output = String(r.prefix(4000))
            busy = false
        }
    }
}
