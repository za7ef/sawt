import Foundation
import Darwin
import ObjectiveC

#if SAWTCTL
@_silgen_name("sawtctl_xct_authorize") private func c_xct_authorize(_ cfg: UnsafePointer<CChar>, _ pid: UInt32) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_free") private func c_xfree(_ p: UnsafeMutablePointer<CChar>?)
#endif

/// تجربة (M0) لطريقة التحكم XCTest داخل تطبيق صوت نفسه — بدون تطبيق ثاني.
/// نحمّل أطر XCTest من صورة المطوّر المركّبة على الجوال (/System/Developer) وقت التشغيل
/// (ما نربطها وقت البناء، عشان التطبيق يفتح عادي لو الصورة مو موجودة)، وبعدين نطلب لقطة
/// لشجرة الواجهة من SpringBoard عن طريق XCUIApplication. أول طلب يفتح "وضع الأتمتة" في iOS
/// وغالبًا يطلب رمز الجوال. كتابة مستقلة؛ ما فيه كود منسوخ من أي مشروع.
enum XCTestProbe {
    struct Step { let name: String; let ok: Bool; let detail: String }

    /// المسارات المحتملة لكل إطار بالترتيب (المكان يختلف بين الإصدارات)
    private static let frameworks: [(String, [String])] = [
        // الأطر تطلب @rpath/lib_TestingInterop.dylib: نحمّله أول بمساره الكامل (وفيه كمان LC_RPATH للتطبيق)
        ("lib_TestingInterop", ["/System/Developer/usr/lib/lib_TestingInterop.dylib"]),
        ("XCTAutomationSupport", ["/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"]),
        ("XCTestCore", ["/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"]),
        ("XCUnit", ["/System/Developer/Library/PrivateFrameworks/XCUnit.framework/XCUnit"]),
        ("XCTest", ["/System/Developer/Library/Frameworks/XCTest.framework/XCTest"]),
        ("XCUIAutomation", ["/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
                            "/System/Developer/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation"]),
        ("libXCTestSwiftSupport", ["/System/Developer/usr/lib/libXCTestSwiftSupport.dylib"]),
    ]

    /// محتويات /System/Developer/usr/lib (عشان نعرف وش المكتبات الموجودة)
    static func listDevLib() -> Step {
        let dir = "/System/Developer/usr/lib"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return Step(name: "usr/lib", ok: false, detail: "ما قدر يقرأ \(dir)")
        }
        let libs = items.filter { $0.hasSuffix(".dylib") }.sorted()
        return Step(name: "usr/lib", ok: !libs.isEmpty, detail: "\(libs.count): " + libs.joined(separator: ", "))
    }

    /// يجرب تحميل الأطر؛ يرجع خطوة لكل إطار مع نص dlerror لو فشل
    static func loadFrameworks() -> [Step] {
        var out: [Step] = []
        let devExists = FileManager.default.fileExists(atPath: "/System/Developer/Library")
        out.append(Step(name: "ddi", ok: devExists, detail: devExists ? "/System/Developer موجود" : "صورة المطوّر مو مركّبة (أو المسار مخفي)"))
        out.append(listDevLib())
        for (name, paths) in frameworks {
            var done = false
            var errs: [String] = []
            for p in paths {
                if dlopen(p, RTLD_NOW | RTLD_GLOBAL) != nil {
                    out.append(Step(name: name, ok: true, detail: p))
                    done = true
                    break
                }
                let e = dlerror().map { String(cString: $0) } ?? "؟"
                errs.append(String(e.prefix(400)))
            }
            if !done { out.append(Step(name: name, ok: false, detail: errs.joined(separator: " | "))) }
        }
        return out
    }

    /// يرجع true لو الكلاسات المهمة صارت متاحة
    static func classesStep() -> Step {
        let names = ["XCUIApplication", "XCUIDevice", "XCUIElement", "XCUICoordinate"]
        let missing = names.filter { NSClassFromString($0) == nil }
        return Step(name: "classes", ok: missing.isEmpty, detail: missing.isEmpty ? "كلها موجودة" : "ناقص: " + missing.joined(separator: ", "))
    }

    /// ينادي دالة ترجع كائن (بدون وسيط أو بوسيط كائن واحد) داخل @try/@catch.
    /// يرجع (الكائن، نص الاستثناء لو صار)
    private static func call(_ target: AnyObject, _ selName: String, _ arg: AnyObject? = nil) -> (AnyObject?, String?) {
        let sel = NSSelectorFromString(selName)
        guard target.responds(to: sel) else { return (nil, "\(selName) مو مدعوم") }
        var result: AnyObject?
        let exc = SawtTryCatch {
            if let arg {
                result = target.perform(sel, with: arg)?.takeUnretainedValue()
            } else {
                result = target.perform(sel)?.takeUnretainedValue()
            }
        }
        return (result, exc)
    }

    /// جلسة الاختبار: XCUIApplication يطلب جلسة مع testmanagerd (اللي يفتحها Xcode عادة).
    /// هنا نجرّب نجهّزها من داخل التطبيق: إعداد اختبار نشط + جلسة XCTRunnerDaemonSession.
    /// تجريبي: ما نعرف إذا iOS يسمح لتطبيق عادي يكلّم testmanagerd بدون Xcode.
    static func sessionSteps() -> [Step] {
        var out: [Step] = []
        // ١) إعداد الاختبار النشط
        if let cfgCls = NSClassFromString("XCTestConfiguration") {
            let (active, e1) = call(cfgCls as AnyObject, "activeTestConfiguration")
            if let e1 { out.append(Step(name: "config", ok: false, detail: "activeTestConfiguration: " + e1)) }
            else if active != nil { out.append(Step(name: "config", ok: true, detail: "موجود من قبل")) }
            else {
                // نسوي واحد جديد ونحط له التطبيق الهدف
                let (fresh, e2) = call(cfgCls as AnyObject, "new")
                if let fresh {
                    var notes: [String] = []
                    for (sel, val) in [("setTargetApplicationBundleID:", "com.apple.springboard" as NSString)] {
                        let (_, e) = call(fresh, sel, val)
                        notes.append(e == nil ? "\(sel) ✓" : "\(sel) ✗ \(e!)")
                    }
                    // نعلّم الإعداد إنه لاختبار واجهة (الخاصية BOOL، فنستخدم KVC بدل perform)
                    if let fo = fresh as? NSObject {
                        let ek = SawtTryCatch { fo.setValue(true, forKey: "initializeForUITesting") }
                        notes.append(ek == nil ? "initializeForUITesting ✓" : "initializeForUITesting ✗ \(ek!)")
                    }
                    let (_, e3) = call(cfgCls as AnyObject, "setActiveTestConfiguration:", fresh)
                    notes.append(e3 == nil ? "setActiveTestConfiguration ✓" : "setActiveTestConfiguration ✗ \(e3!)")
                    out.append(Step(name: "config", ok: e3 == nil, detail: notes.joined(separator: "؛ ")))
                } else {
                    out.append(Step(name: "config", ok: false, detail: "ما قدر يسوي XCTestConfiguration: " + (e2 ?? "رجع فاضي")))
                }
            }
        } else {
            out.append(Step(name: "config", ok: false, detail: "XCTestConfiguration مو موجود"))
        }
        // ٢) جلسة testmanagerd
        if let sessCls = NSClassFromString("XCTRunnerDaemonSession") {
            let (sess, e) = call(sessCls as AnyObject, "sharedSession")
            if let e { out.append(Step(name: "testmanagerd", ok: false, detail: "sharedSession: " + e)) }
            else if let sess = sess as? NSObject {
                var info: [String] = []
                for key in ["daemonProtocolVersion", "daemonCapabilities"] {
                    var v: Any?
                    let ex = SawtTryCatch { v = sess.value(forKey: key) }
                    info.append(ex == nil ? "\(key)=\(v.map { "\($0)" } ?? "nil")" : "\(key) ✗ \(ex!)")
                }
                out.append(Step(name: "testmanagerd", ok: true, detail: info.joined(separator: "؛ ")))
            } else {
                out.append(Step(name: "testmanagerd", ok: false, detail: "sharedSession رجع فاضي (غالبًا ما فيه اتصال)"))
            }
        } else {
            out.append(Step(name: "testmanagerd", ok: false, detail: "XCTRunnerDaemonSession مو موجود"))
        }
        // ٣) الجهاز
        if let devCls = NSClassFromString("XCUIDevice") {
            let (dev, e) = call(devCls as AnyObject, "sharedDevice")
            out.append(Step(name: "device", ok: e == nil && dev != nil, detail: e ?? (dev == nil ? "sharedDevice رجع فاضي" : "موجود")))
        }
        return out
    }

    /// لقطة شجرة SpringBoard: يرجع عدد العناصر وأول التسميات
    /// (يشتغل على خيط خلفي؛ ممكن يطوّل لين يدخل المستخدم الرمز)
    /// كل نداء لأطر XCTest داخل SawtTryCatch: أي استثناء يصير سطر ✗ بدل كراش
    static func snapshotSpringboard() -> Step {
        guard let cls = NSClassFromString("XCUIApplication") as? NSObject.Type else {
            return Step(name: "snapshot", ok: false, detail: "XCUIApplication مو موجود")
        }
        let initSel = NSSelectorFromString("initWithBundleIdentifier:")
        guard cls.instancesRespond(to: initSel) else {
            return Step(name: "snapshot", ok: false, detail: "initWithBundleIdentifier: مو مدعوم")
        }
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return Step(name: "snapshot", ok: false, detail: "ما لقى تنفيذ initWithBundleIdentifier:")
        }
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)
        var app: NSObject?
        if let exc = SawtTryCatch({
            // alloc يرجع +1 والـinit يستهلكه؛ ناخذه بدون retain عشان ما ينحرر مرتين
            let raw: AnyObject = cls.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            app = initFn(raw, initSel, "com.apple.springboard" as NSString)?.takeRetainedValue() as? NSObject
        }) {
            return Step(name: "init", ok: false, detail: exc)
        }
        guard let app else {
            return Step(name: "init", ok: false, detail: "ما قدر يسوي XCUIApplication(springboard)")
        }
        let snapSel = NSSelectorFromString("snapshotWithError:")
        guard app.responds(to: snapSel), let imp = app.method(for: snapSel) else {
            return Step(name: "snapshot", ok: false, detail: "snapshotWithError: مو مدعوم")
        }
        typealias SnapFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
        let fn = unsafeBitCast(imp, to: SnapFn.self)
        var err: NSError?
        var snap: AnyObject?
        if let exc = SawtTryCatch({ snap = fn(app, snapSel, &err) }) {
            return Step(name: "snapshot", ok: false, detail: exc)
        }
        guard let snapObj = snap as? NSObject else {
            return Step(name: "snapshot", ok: false, detail: "رجع فاضي: " + (err.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "بدون خطأ"))
        }
        var dictAny: Any?
        if let exc = SawtTryCatch({ dictAny = snapObj.value(forKey: "dictionaryRepresentation") }) {
            return Step(name: "snapshot", ok: false, detail: "dictionaryRepresentation: " + exc)
        }
        guard let dict = dictAny as? [AnyHashable: Any] else {
            return Step(name: "snapshot", ok: false, detail: "ما فيه dictionaryRepresentation")
        }
        var count = 0
        var labels: [String] = []
        func walk(_ d: [AnyHashable: Any]) {
            count += 1
            if labels.count < 10, let l = d["label"] as? String, !l.isEmpty { labels.append(l) }
            if let kids = d["children"] as? [[AnyHashable: Any]] { kids.forEach(walk) }
        }
        walk(dict)
        return Step(name: "snapshot", ok: count > 0, detail: "\(count) عنصر؛ " + labels.joined(separator: "، "))
    }

    // MARK: - قائمة الشروط وتفويض الجلسة

    /// بند في قائمة الشروط: ok = nil يعني ما انفحص للحين
    struct Check: Identifiable, Sendable { let id: String; let title: String; var ok: Bool?; var note: String = "" }

    static let checkOrder: [(String, String)] = [
        ("pairing", "ملف الاقتران"),
        ("loopback", "الاتصال المحلي (LocalDevVPN)"),
        ("ddi", "صورة المطوّر مركّبة"),
        ("devmode", "وضع المطوّر + خدمة testmanagerd"),
        ("authorize", "تفويض جلسة اختبار الواجهة"),
    ]

    /// الفحوص المحلية السريعة (بدون اتصال)
    static func localChecks() -> [Check] {
        checkOrder.map { id, title in
            switch id {
            case "pairing": return Check(id: id, title: title, ok: PhoneControl.hasPairing)
            case "ddi": return Check(id: id, title: title, ok: FileManager.default.fileExists(atPath: "/System/Developer/Library"))
            default: return Check(id: id, title: title, ok: nil)
            }
        }
    }

    /// إعداد الاتصال بنفس طريقة الوكيل (المنفذ يُكتشف لو الملف RemotePairing)
    @MainActor static func connectionConfig() async -> String {
        var port: UInt16 = 0
        if PhoneControl.storedInfo().contains("kind=RemotePairing") { port = await PhoneControl.discoverRPPort().port }
        let h = UserDefaults.standard.string(forKey: "pcHost") ?? "10.7.0.1"
        return PhoneControl.config(host: h, rpPort: port, rpHost: PhoneControl.lastRPHost)
    }

    /// يطلب من testmanagerd (عبر الـloopback) تفويض عملية صوت لاختبار الواجهة، ويحدّث القائمة
    static func authorizeSelf(cfg: String, checks: inout [Check]) -> Step {
        #if SAWTCTL
        let pid = UInt32(getpid())
        let raw = cfg.withCString { c_xct_authorize($0, pid) }
        let out = raw.map { String(cString: $0) } ?? "{}"
        c_xfree(raw)
        slog("xct: authorize \(out.prefix(3000))")
        let d = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
        let ok = d["ok"] as? Bool == true
        let steps = d["steps"] as? [[String: Any]] ?? []
        func set(_ id: String, _ v: Bool?, _ note: String = "") {
            if let i = checks.firstIndex(where: { $0.id == id }) { checks[i].ok = v; checks[i].note = note }
        }
        let err = d["error"] as? String ?? ""
        // لو ما وصلنا RSD، الاتصال المحلي هو اللي فشل
        let reachedRSD = steps.contains { $0["step"] as? String == "rsd" }
        set("loopback", reachedRSD, reachedRSD ? "" : err)
        if reachedRSD {
            let tm = steps.first { $0["step"] as? String == "check" && $0["item"] as? String == "testmanagerd" }?["ok"] as? Bool
            set("devmode", tm)
        }
        set("authorize", ok, ok ? "pid \(pid)" : err)
        let detail = ok ? "pid \(pid) مفوّض" : String(err.prefix(500))
        return Step(name: "authorize", ok: ok, detail: detail)
        #else
        return Step(name: "authorize", ok: false, detail: "هالنسخة مبنية بدون sawtctl")
        #endif
    }

    /// يشغّل التجربة كاملة ويكتب كل خطوة في السجل. onWaiting تنادى لو اللقطة طوّلت (غالبًا تنتظر الرمز)
    static func run(cfg: String, onChecks: @escaping @Sendable ([Check]) -> Void, onWaiting: @escaping @Sendable () -> Void) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var lines: [String] = []
                func add(_ s: Step, _ ms: Int) {
                    let line = "\(s.ok ? "✓" : "✗") \(s.name) (\(ms)ms): \(s.detail)"
                    slog("xct: \(line)")
                    lines.append(line)
                }
                var t = Date()
                let loaded = loadFrameworks()
                let loadMs = Int(Date().timeIntervalSince(t) * 1000)
                loaded.forEach { add($0, loadMs) }
                let cs = classesStep()
                add(cs, 0)
                guard cs.ok else {
                    slog("xct: stop (classes missing)")
                    cont.resume(returning: lines)
                    return
                }
                // التفويض أول: XCTest يقرأ حالة الجلسة أول ما تنشأ
                var checks = localChecks()
                onChecks(checks)
                t = Date()
                let auth = authorizeSelf(cfg: cfg, checks: &checks)
                add(auth, Int(Date().timeIntervalSince(t) * 1000))
                onChecks(checks)
                sessionSteps().forEach { add($0, 0) }
                // لو اللقطة طوّلت أكثر من ٥ ثواني غالبًا iOS يطلب الرمز
                let waiting = DispatchWorkItem { slog("xct: snapshot slow → probably waiting for passcode"); onWaiting() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: waiting)
                t = Date()
                let s = snapshotSpringboard()
                waiting.cancel()
                add(s, Int(Date().timeIntervalSince(t) * 1000))
                cont.resume(returning: lines)
            }
        }
    }
}
