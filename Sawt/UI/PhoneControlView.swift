import SwiftUI
import UniformTypeIdentifiers
import Network
import Security

// تجربة «تحكم بالجوال»: يتصل بخدمات المطوّر في نفس الجوال (عبر LocalDevVPN على 10.7.0.1)
// بملف الاقتران، ويقرأ شجرة الوصول ويرسل لمسة/كتابة. للاختبار فقط قبل بناء الوكيل.

#if SAWTCTL
@_silgen_name("sawtctl_probe") private func c_probe(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_tap") private func c_tap(_ cfg: UnsafePointer<CChar>, _ x: UInt16, _ y: UInt16) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_keys") private func c_keys(_ cfg: UnsafePointer<CChar>, _ what: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_ax") private func c_ax(_ cfg: UnsafePointer<CChar>, _ waitMs: UInt32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_pair") private func c_pair(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_screen") private func c_screen(_ cfg: UnsafePointer<CChar>, _ waitMs: UInt32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_drag") private func c_drag(_ cfg: UnsafePointer<CChar>, _ x1: UInt16, _ y1: UInt16, _ x2: UInt16, _ y2: UInt16) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_launch") private func c_launch(_ cfg: UnsafePointer<CChar>, _ q: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_shot") private func c_shot(_ cfg: UnsafePointer<CChar>, _ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_live_open") private func c_live_open(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_live_close") private func c_live_close() -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_live") private func c_live(_ cfg: UnsafePointer<CChar>, _ op: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_free") private func c_free(_ p: UnsafeMutablePointer<CChar>?)
@_silgen_name("sawtctl_ddi_status") private func c_ddi_status(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_ddi_mount") private func c_ddi_mount(_ cfg: UnsafePointer<CChar>, _ dir: UnsafePointer<CChar>, _ ios: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
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

    static var hasPairing: Bool {
        ensurePairing()
        return FileManager.default.fileExists(atPath: pairingURL.path)
    }

    // نسخة احتياطية في Keychain: لو اختفى الملف نرجّعه بنفس البايتات بالضبط
    private static let kcService = "sawt.pairing"
    private static let kcAccount = "rp_pairing_file"

    static func keychainLoad() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: kcService,
                                kSecAttrAccount as String: kcAccount, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func keychainStore(_ d: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: kcService,
                                kSecAttrAccount as String: kcAccount]
        let attrs: [String: Any] = [kSecValueData as String: d,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let st = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = q; attrs.forEach { add[$0.key] = $0.value }
            let a = SecItemAdd(add as CFDictionary, nil)
            Log.shared("phonectl keychain: add \(a)")
        } else {
            Log.shared("phonectl keychain: update \(st)")
        }
    }

    /// بصمة المفتاح العام (أول ٤ بايت) — بدون أسرار
    static func fingerprint(_ d: Data) -> String {
        guard let o = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
              let pk = o["public_key"] as? Data else { return "?" }
        return pk.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func writePairing(_ d: Data) throws {
        let dest = pairingURL
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: dest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = dest
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    /// الملف هو المصدر. لو ناقص نرجعه من Keychain، ولو موجود ونسخة Keychain تختلف نحدّثها.
    static func ensurePairing() {
        let path = pairingURL.path
        if let d = try? Data(contentsOf: pairingURL) {
            if keychainLoad() != d { keychainStore(d) }
            Log.shared("phonectl pairing load: \(path) fp=\(fingerprint(d)) size=\(d.count)")
        } else if let k = keychainLoad() {
            do {
                try writePairing(k)
                Log.shared("phonectl pairing restored from keychain: \(path) fp=\(fingerprint(k))")
            } catch {
                Log.shared("phonectl pairing restore failed: \(error.localizedDescription)")
            }
        } else {
            Log.shared("phonectl pairing: none at \(path)")
        }
    }

    /// يُستدعى بعد ما يكتب Rust ملف اقتران جديد (اقتران ناجح فقط)
    static func pairingWritten() {
        guard let d = try? Data(contentsOf: pairingURL) else { Log.shared("phonectl pairing: written but unreadable"); return }
        var u = pairingURL
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        // النسخة الاحتياطية .bak اللي يكتبها Rust: برضه برا النسخ الاحتياطي
        var bak = pairingURL.deletingPathExtension().appendingPathExtension("plist.bak")
        if FileManager.default.fileExists(atPath: bak.path) { try? bak.setResourceValues(rv) }
        keychainStore(d)
        Log.shared("phonectl pairing saved: \(pairingURL.path) fp=\(fingerprint(d))")
    }

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
            return (nil, "format=\(fmt.joined(separator: "+")) top=\(type(of: obj)) " + L("(ليس قاموسًا)"))
        }
        let keys = dict.keys.sorted().joined(separator: ",")
        let kind: String
        if dict["public_key"] != nil && dict["private_key"] != nil && dict["identifier"] != nil { kind = "RemotePairing" }
        else if dict["HostID"] != nil || dict["DeviceCertificate"] != nil { kind = "lockdown" }
        else { kind = L("غير معروف") }
        // نحفظ البايتات الأصلية كما هي (مثل StikDebug)؛ نحوّل بس لو كانت base64 أو فيها BOM
        let original = !fmt.contains("base64") && !fmt.contains("bom")
        let xml = original ? d : (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
        return (xml, "format=\(fmt.joined(separator: "+")) kind=\(kind) size=\(raw.count) keys=[\(keys)]")
    }

    static func save(_ data: Data) -> String {
        let (norm, info) = normalize(data)
        Log.shared("phonectl pairing: \(info)")
        guard let norm else { return L("الملف ليس plist صالحًا — %@", info) }
        do {
            try writePairing(norm)
            keychainStore(norm)
            return L("تم حفظ ملف الاقتران — %@", info) + " fp=\(fingerprint(norm))"
        } catch {
            return L("فشل الحفظ: %@", error.localizedDescription)
        }
    }

    /// معلومات الملف المحفوظ (بدون أسرار) — ونعيد توحيده لو انحفظ بنسخة قديمة
    static func storedInfo() -> String {
        ensurePairing()
        guard let d = try? Data(contentsOf: pairingURL) else { return L("لا يوجد ملف") }
        // ما نعيد كتابة الملف هنا أبدًا — نقرأ بس
        let (_, info) = normalize(d)
        return info + " fp=\(fingerprint(d))"
    }

    static func importFile(_ url: URL) -> String {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        var readErr: NSError?
        var out = ""
        // NSFileCoordinator عشان الملفات اللي في iCloud أو عند مزوّد ثاني
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &readErr) { u in
            do { out = save(try Data(contentsOf: u)) } catch { out = L("فشلت القراءة: %@", error.localizedDescription) }
        }
        if let readErr, out.isEmpty { out = L("فشلت القراءة: %@", readErr.localizedDescription) }
        return out
    }

    static func config(host: String, rpPort: UInt16, rpHost: String) -> String {
        let d: [String: Any] = ["pairing_file": pairingURL.path, "host": host, "rp_port": Int(rpPort), "rp_host": rpHost]
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    enum Op: Sendable { case probe, pair, ax(UInt32), tap(UInt16, UInt16), keys(String), screen(UInt32), drag(UInt16, UInt16, UInt16, UInt16), launch(String), shot(String), liveOpen, liveClose, live(String), ddiStatus, ddiMount(String, String) }

    nonisolated(unsafe) static var lastRPHost = ""

    /// يكتشف منفذ _remotepairing._tcp عبر Bonjour (يفضّل واجهة loopback/الـVPN)
    @MainActor
    static func discoverRPPort(timeout: Double = 4) async -> (port: UInt16, info: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(port: UInt16, info: String), Never>) in
            let q = DispatchQueue(label: "sawt.bonjour")
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: params)
            final class Box: @unchecked Sendable { var host = ""; var done = false; var conn: NWConnection?; var seen: [String] = [] }
            let box = Box()
            let finish: @Sendable (UInt16, String) -> Void = { p, i in
                q.async {
                    guard !box.done else { return }
                    box.done = true
                    browser.cancel(); box.conn?.cancel()
                    PhoneControl.lastRPHost = box.host
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
                            box.host = "\(h)"
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
    static func run(_ op: Op, host: String, rpPort: UInt16 = 0, rpHost: String = "") async -> String {
        let cfg = config(host: host, rpPort: rpPort, rpHost: rpHost)
        return await Task.detached(priority: .userInitiated) { () -> String in
            #if SAWTCTL
            let p: UnsafeMutablePointer<CChar>? = cfg.withCString { c in
                switch op {
                case .probe: return c_probe(c)
                case .pair: return c_pair(c)
                case .ax(let ms): return c_ax(c, ms)
                case .tap(let x, let y): return c_tap(c, x, y)
                case .keys(let w): return w.withCString { c_keys(c, $0) }
                case .screen(let ms): return c_screen(c, ms)
                case .drag(let a, let b, let x, let y): return c_drag(c, a, b, x, y)
                case .launch(let q): return q.withCString { c_launch(c, $0) }
                case .shot(let path): return path.withCString { c_shot(c, $0) }
                case .liveOpen: return c_live_open(c)
                case .liveClose: return c_live_close()
                case .live(let j): return j.withCString { c_live(c, $0) }
                case .ddiStatus: return c_ddi_status(c)
                case .ddiMount(let dir, let ios): return dir.withCString { d in ios.withCString { c_ddi_mount(c, d, $0) } }
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
    @ObservedObject private var hostPair = HostPairing.shared
    @State private var countdown = 0
    @State private var output = ""
    @State private var repairing = false
    @ObservedObject private var ddi = DDIStore.shared

    var body: some View {
        Form {
            Section {
                NavigationLink { PhoneAgentView() } label: { Label("الوكيل (تجريبي)", systemImage: "wand.and.stars") }
                    .disabled(!hasPairing)
            }
            Section {
                LabeledContent("الأداة", value: PhoneControl.available ? L("مبنية") : L("غير مبنية"))
                LabeledContent("ملف الاقتران", value: hasPairing ? L("موجود") : L("ناقص"))
                Button("استيراد ملف الاقتران") { importing = true }
                Button("الصق محتوى الملف") { pasting = true }
                TextField("العنوان", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("يجب أن يكون LocalDevVPN قيد التشغيل. تُنزَّل صورة المطوّر (DDI) وتُركَّب تلقائيًا عند الحاجة، ويلزم وضع المطوّر واتصال بالإنترنت عند أول تركيب بعد كل تشغيل للجهاز. يمكنك استيراد ملف اقتران من StikDebug، أو إنشاء ملف جديد من الجهاز (وافق إذا ظهر لك طلب ثقة، وتُحفظ نسخة من الملف القديم).")
            }

            Section {
                if hostPair.running {
                    if !hostPair.pin.isEmpty {
                        Text(hostPair.pin).font(.system(size: 40, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                    }
                    Text(hostPair.status)
                    Button("إلغاء", role: .destructive) { hostPair.cancel() }
                } else if hasPairing && !repairing {
                    LabeledContent("الحالة", value: L("مقترن ✅"))
                    if !hostPair.result.isEmpty { Text(hostPair.result).font(.footnote).textSelection(.enabled) }
                    Button("إعادة الاقتران") { repairing = true }.font(.footnote)
                } else {
                    Button("أنشئ ملف اقتران من الجهاز") { hostPair.start() }
                    if !hostPair.result.isEmpty { Text(hostPair.result).font(.footnote).textSelection(.enabled) }
                    Button("اقتران مباشر (الطريقة القديمة)") { go(.pair, delay: false, label: "pair") }
                    if hasPairing { Button("رجوع", role: .cancel) { repairing = false } }
                }
            } header: {
                Text("الاقتران من الجهاز (iOS 27)")
            } footer: {
                Text("شغّل LocalDevVPN، واضغط الزر، ثم اذهب إلى الإعدادات واختر «Sawt» من الأجهزة القريبة. سيظهر لك رمز من ٦ أرقام هنا وفي إشعار، اكتبه في الجهاز. يبقى Sowtly يعمل في الخلفية ٥ دقائق.")
            }

            Section {
                Button("فحص الاتصال") { go(.probe, delay: false, label: "probe", mountFirst: true) }
                Button("تركيب صورة المطوّر") { mountDDI(redownload: false) }
                Button("إعادة تنزيل صورة المطوّر") { mountDDI(redownload: true) }.font(.footnote)
                if ddi.busy, !ddi.status.isEmpty { HStack { ProgressView(); Text(ddi.status).font(.footnote) } }
            } header: {
                Text("اختبارات")
            } footer: {
                Text(DDIStore.versionLine)
            }
            .disabled(busy || ddi.busy || !PhoneControl.available || !hasPairing)

            if countdown > 0 {
                Section { Text(L("يبدأ بعد %@…", String(countdown))) }
            }
            if busy && countdown == 0 {
                Section { HStack { ProgressView(); Text("جارٍ التنفيذ…") } }
            }
            if !output.isEmpty {
                Section("النتيجة") {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    Button("نسخ") { UIPasteboard.general.string = output }
                }
            }
        }
        .navigationTitle("التحكم بالجهاز (تجريبي)")
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
        .onAppear { hasPairing = PhoneControl.hasPairing; repairing = false }
        .onChange(of: hostPair.running) { _, r in
            if !r { hasPairing = PhoneControl.hasPairing; if hostPair.result.contains("✅") { repairing = false } }
        }
    }

    /// تركيب يدوي لصورة المطوّر (مع إعادة التنزيل إن طُلب)
    private func mountDDI(redownload: Bool) {
        busy = true
        output = ""
        Task { @MainActor in
            var lines = [DDIStore.versionLine]
            if redownload, let e = await ddi.download(force: true) {
                lines.append("✗ " + e)
            } else if let e = await ddi.ensureMounted(force: true, permitted: redownload) {
                lines.append("✗ " + e)
            } else {
                lines.append(L("✓ صورة المطوّر مركّبة"))
            }
            lines[0] = DDIStore.versionLine
            output = lines.joined(separator: "\n")
            Log.shared("phonectl ddi: \(output)")
            busy = false
        }
    }

    private func go(_ op: PhoneControl.Op, delay: Bool, label: String, stay: Bool = false, mountFirst: Bool = false, after: (@MainActor () -> String)? = nil) {
        busy = true
        output = ""
        let h = host
        Task { @MainActor in
            // فحص الاتصال: نتأكد من صورة المطوّر أول ونكتب سطرها في النتيجة
            var ddiLine = ""
            if mountFirst {
                let e = await DDIStore.shared.ensureMounted(force: true)
                ddiLine = DDIStore.versionLine + "\n" + (e.map { "✗ " + $0 } ?? L("✓ صورة المطوّر مركّبة")) + "\n"
            }
            // لما تطلع من التطبيق iOS يوقفه، فالأوامر ما توصل لين ترجع؛ نخليه صاحي بصوت صامت + وقت خلفية
            var bg: BGTask?
            if delay {
                HostPairing.shared.keepAlive(true)
                bg = BGTask("phonectl")
            }
            defer {
                if delay {
                    HostPairing.shared.keepAlive(false)
                    bg?.end()
                }
            }
            if delay {
                for i in stride(from: stay ? 3 : 5, through: 1, by: -1) {
                    countdown = i
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = 0
            }
            let info = PhoneControl.storedInfo()
            Log.shared("phonectl pairing: \(info)")
            var rp: (port: UInt16, info: String) = (0, "lockdown")
            if info.contains("kind=RemotePairing") || label == "pair" { rp = await PhoneControl.discoverRPPort() }
            Log.shared("phonectl rp port: \(rp.port) \(rp.info)")
            var r = await PhoneControl.run(op, host: h, rpPort: rp.port, rpHost: PhoneControl.lastRPHost)
            if label == "pair" {
                if r.contains("\"paired\":true") { PhoneControl.pairingWritten() }
                r = "new pairing: \(PhoneControl.storedInfo())\n" + r
            }
            r = ddiLine + "pairing: \(info)\nrp: \(rp.port) \(rp.info)\n" + r
            if let after {
                try? await Task.sleep(nanoseconds: 400_000_000)
                r += after()
            }
            Log.shared("phonectl \(label): \(r.prefix(6000))")
            // ما ننسخ تلقائيًا (فيه معلومات اقتران)؛ زر «نسخ» موجود
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
