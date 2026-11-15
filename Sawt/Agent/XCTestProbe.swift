import Foundation
import Darwin
import ObjectiveC

/// تجربة (M0) لطريقة التحكم XCTest داخل تطبيق صوت نفسه — بدون تطبيق ثاني.
/// نحمّل أطر XCTest من صورة المطوّر المركّبة على الجوال (/System/Developer) وقت التشغيل
/// (ما نربطها وقت البناء، عشان التطبيق يفتح عادي لو الصورة مو موجودة)، وبعدين نطلب لقطة
/// لشجرة الواجهة من SpringBoard عن طريق XCUIApplication. أول طلب يفتح "وضع الأتمتة" في iOS
/// وغالبًا يطلب رمز الجوال. كتابة مستقلة؛ ما فيه كود منسوخ من أي مشروع.
enum XCTestProbe {
    struct Step { let name: String; let ok: Bool; let detail: String }

    /// المسارات المحتملة لكل إطار بالترتيب (المكان يختلف بين الإصدارات)
    private static let frameworks: [(String, [String])] = [
        ("XCTAutomationSupport", ["/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"]),
        ("XCTestCore", ["/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"]),
        ("XCUnit", ["/System/Developer/Library/PrivateFrameworks/XCUnit.framework/XCUnit"]),
        ("XCTest", ["/System/Developer/Library/Frameworks/XCTest.framework/XCTest"]),
        ("XCUIAutomation", ["/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
                            "/System/Developer/Library/PrivateFrameworks/XCUIAutomation.framework/XCUIAutomation"]),
    ]

    /// يجرب تحميل الأطر؛ يرجع خطوة لكل إطار مع نص dlerror لو فشل
    static func loadFrameworks() -> [Step] {
        var out: [Step] = []
        let devExists = FileManager.default.fileExists(atPath: "/System/Developer/Library")
        out.append(Step(name: "ddi", ok: devExists, detail: devExists ? "/System/Developer موجود" : "صورة المطوّر مو مركّبة (أو المسار مخفي)"))
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
                errs.append(String(e.prefix(220)))
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

    /// لقطة شجرة SpringBoard: يرجع عدد العناصر وأول التسميات
    /// (يشتغل على خيط خلفي؛ ممكن يطوّل لين يدخل المستخدم الرمز)
    static func snapshotSpringboard() -> Step {
        guard let cls: AnyClass = NSClassFromString("XCUIApplication") else {
            return Step(name: "snapshot", ok: false, detail: "XCUIApplication مو موجود")
        }
        // alloc + initWithBundleIdentifier: عن طريق تنفيذ الدوال مباشرة (نفس اللي يسويه الكومبايلر في ObjC)
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithBundleIdentifier:")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            return Step(name: "snapshot", ok: false, detail: "alloc مو موجود")
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        // alloc يرجع +1 والـinit يستهلكه؛ ناخذه بدون retain عشان ما ينحرر مرتين
        let raw = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)(cls, allocSel).takeUnretainedValue()
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return Step(name: "snapshot", ok: false, detail: "initWithBundleIdentifier: مو موجود")
        }
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)
        guard let app = initFn(raw, initSel, "com.apple.springboard" as NSString)?.takeRetainedValue() as? NSObject else {
            return Step(name: "snapshot", ok: false, detail: "ما قدر يسوي XCUIApplication(springboard)")
        }
        let snapSel = NSSelectorFromString("snapshotWithError:")
        guard app.responds(to: snapSel) else {
            return Step(name: "snapshot", ok: false, detail: "snapshotWithError: مو مدعوم")
        }
        // نمرر مؤشر خطأ حقيقي عشان نعرف السبب لو رجع nil
        var err: NSError?
        typealias SnapFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
        guard let imp = app.method(for: snapSel) else {
            return Step(name: "snapshot", ok: false, detail: "ما لقى تنفيذ snapshotWithError:")
        }
        let fn = unsafeBitCast(imp, to: SnapFn.self)
        let snap = fn(app, snapSel, &err)
        guard let snapObj = snap as? NSObject else {
            return Step(name: "snapshot", ok: false, detail: "رجع فاضي: " + (err.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "بدون خطأ"))
        }
        guard let dict = snapObj.value(forKey: "dictionaryRepresentation") as? [AnyHashable: Any] else {
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

    /// يشغّل التجربة كاملة ويكتب كل خطوة في السجل. onWaiting تنادى لو اللقطة طوّلت (غالبًا تنتظر الرمز)
    static func run(onWaiting: @escaping @Sendable () -> Void) async -> [String] {
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
