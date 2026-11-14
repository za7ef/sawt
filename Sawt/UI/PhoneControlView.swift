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

    /// يتأكد إن البيانات plist ويحدد نوعها، وبعدين يحفظها
    static func save(_ data: Data) -> String {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "الملف مو plist صالح (\(data.count) بايت)"
        }
        let kind: String
        if obj["public_key"] != nil && obj["private_key"] != nil && obj["identifier"] != nil { kind = "RemotePairing" }
        else if obj["HostID"] != nil || obj["DeviceCertificate"] != nil { kind = "lockdown" }
        else { kind = "غير معروف" }
        do {
            let dest = pairingURL
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return "تم حفظ ملف الاقتران (\(kind)، \(data.count) بايت)"
        } catch {
            return "فشل الحفظ: \(error.localizedDescription)"
        }
    }

    static func importFile(_ url: URL) -> String {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        var readErr: NSError?
        var out = ""
        // NSFileCoordinator عشان الملفات اللي في iCloud أو عند مزوّد ثاني
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &readErr) { u in
            do { out = save(try Data(contentsOf: u)) } catch { out = "فشل القراءة: \(error.localizedDescription)" }
        }
        if let readErr, out.isEmpty { out = "فشل القراءة: \(readErr.localizedDescription)" }
        return out
    }

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
    @State private var pasting = false
    @State private var pasteText = ""
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
                Button("الصق محتوى الملف") { pasting = true }
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
        .sheet(isPresented: $importing) {
            DocPicker { url in
                importing = false
                guard let url else { Log.shared("phonectl picker: cancelled"); return }
                Log.shared("phonectl picker: picked \(url.lastPathComponent)")
                output = PhoneControl.importFile(url)
                hasPairing = PhoneControl.hasPairing
                Log.shared("phonectl import: \(output)")
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasteText)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding()
                    .navigationTitle("الصق محتوى الملف")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { pasting = false } }
                        ToolbarItem(placement: .primaryAction) {
                            Button("لصق") { pasteText = UIPasteboard.general.string ?? pasteText }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("حفظ") {
                                output = PhoneControl.save(Data(pasteText.utf8))
                                hasPairing = PhoneControl.hasPairing
                                Log.shared("phonectl paste: \(output)")
                                pasting = false
                            }
                            .disabled(pasteText.isEmpty)
                        }
                    }
            }
        }
        .onAppear { hasPairing = PhoneControl.hasPairing }
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

/// منتقي ملفات UIKit مباشر (asCopy) — أثبت من fileImporter مع بعض الإضافات
struct DocPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void

    func makeCoordinator() -> Coord { Coord(done: done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        Log.shared("phonectl picker: presented")
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coord: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Log.shared("phonectl picker: didPick \(urls.count)")
            done(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            done(nil)
        }
    }
}
