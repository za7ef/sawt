import SwiftUI
import UniformTypeIdentifiers
import Network

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

    /// ينظّف البيانات (BOM، مسافات، base64) ويحوّلها لـplist XML موحّد
    static func normalize(_ raw: Data) -> (data: Data?, info: String) {
        var d = raw
        var fmt: [String] = []
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3); fmt.append("bom") }
        if d.starts(with: Array("bplist".utf8)) { fmt.append("binary") }
        else if let t = String(data: d, encoding: .utf8) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if trimmed.hasPrefix("<") { fmt.append("xml"); d = Data(trimmed.utf8) }
            else if let b = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters), !b.isEmpty {
                fmt.append("base64"); d = b
                if d.starts(with: Array("bplist".utf8)) { fmt.append("binary") } else { fmt.append("xml") }
            } else { fmt.append("text?") }
        } else { fmt.append("unknown") }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: &format) else {
            return (nil, "format=\(fmt.joined(separator: "+")) size=\(raw.count) parse=failed")
        }
        guard let dict = obj as? [String: Any] else {
            return (nil, "format=\(fmt.joined(separator: "+")) top=\(type(of: obj)) (مو قاموس)")
        }
        let keys = dict.keys.sorted().joined(separator: ",")
        let kind: String
        if dict["public_key"] != nil && dict["private_key"] != nil && dict["identifier"] != nil { kind = "RemotePairing" }
        else if dict["HostID"] != nil || dict["DeviceCertificate"] != nil { kind = "lockdown" }
        else { kind = "غير معروف" }
        let xml = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return (xml, "format=\(fmt.joined(separator: "+")) kind=\(kind) size=\(raw.count) keys=[\(keys)]")
    }

    static func save(_ data: Data) -> String {
        let (norm, info) = normalize(data)
        Log.shared("phonectl pairing: \(info)")
        guard let norm else { return "الملف مو plist صالح — \(info)" }
        do {
            let dest = pairingURL
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try norm.write(to: dest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return "تم حفظ ملف الاقتران — \(info)"
        } catch {
            return "فشل الحفظ: \(error.localizedDescription)"
        }
    }

    /// معلومات الملف المحفوظ (بدون أسرار) — ونعيد توحيده لو انحفظ بنسخة قديمة
    static func storedInfo() -> String {
        guard let d = try? Data(contentsOf: pairingURL) else { return "لا يوجد ملف" }
        let (norm, info) = normalize(d)
        if let norm, norm != d { try? norm.write(to: pairingURL, options: .atomic) }
        return info
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

    static func config(host: String, rpPort: UInt16) -> String {
        let d: [String: Any] = ["pairing_file": pairingURL.path, "host": host, "rp_port": Int(rpPort)]
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    enum Op: Sendable { case probe, ax(UInt32), tap(UInt16, UInt16), keys(String) }

    /// يكتشف منفذ _remotepairing._tcp عبر Bonjour (يفضّل واجهة loopback/الـVPN)
    @MainActor
    static func discoverRPPort(timeout: Double = 4) async -> (port: UInt16, info: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(port: UInt16, info: String), Never>) in
            let q = DispatchQueue(label: "sawt.bonjour")
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: params)
            final class Box: @unchecked Sendable { var done = false; var conn: NWConnection?; var seen: [String] = [] }
            let box = Box()
            let finish: @Sendable (UInt16, String) -> Void = { p, i in
                q.async {
                    guard !box.done else { return }
                    box.done = true
                    browser.cancel(); box.conn?.cancel()
                    cont.resume(returning: (p, i))
                }
            }
            browser.stateUpdateHandler = { st in
                if case .failed(let e) = st { finish(0, "bonjour failed: \(e)") }
            }
            browser.browseResultsChangedHandler = { results, _ in
                guard box.conn == nil else { return }
                let list = results.map { r in (r, r.interfaces.contains { $0.name.hasPrefix("lo") || $0.name.hasPrefix("utun") }) }
                box.seen = list.map { "\($0.0.endpoint) [\($0.0.interfaces.map(\.name).joined(separator: ","))]" }
                guard let pick = list.first(where: { $0.1 }) ?? list.first else { return }
                let c = NWConnection(to: pick.0.endpoint, using: params)
                box.conn = c
                c.stateUpdateHandler = { st in
                    switch st {
                    case .ready, .waiting:
                        if case .hostPort(let h, let p) = c.currentPath?.remoteEndpoint, p.rawValue != 0 {
                            finish(p.rawValue, "bonjour \(h):\(p.rawValue) seen=\(box.seen)")
                        }
                    case .failed(let e): finish(0, "resolve failed: \(e) seen=\(box.seen)")
                    default: break
                    }
                }
                c.start(queue: q)
            }
            browser.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(0, "bonjour timeout seen=\(box.seen)") }
        }
    }

    /// يشغّل العملية في خيط خلفي (الدوال متزامنة وتحجز الخيط)
    static func run(_ op: Op, host: String, rpPort: UInt16 = 0) async -> String {
        let cfg = config(host: host, rpPort: rpPort)
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
            let info = PhoneControl.storedInfo()
            Log.shared("phonectl pairing: \(info)")
            var rp: (port: UInt16, info: String) = (0, "lockdown")
            if info.contains("kind=RemotePairing") { rp = await PhoneControl.discoverRPPort() }
            Log.shared("phonectl rp port: \(rp.port) \(rp.info)")
            var r = await PhoneControl.run(op, host: h, rpPort: rp.port)
            r = "pairing: \(info)\nrp: \(rp.port) \(rp.info)\n" + r
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
