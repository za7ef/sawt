import Foundation
import UIKit
import CoreGraphics
import Darwin
import ObjectiveC

/// طريقة التحكم XCTest للوكيل: نقرأ شجرة التطبيق اللي قدّام ونلمس ونسحب ونضغط الأزرار عن طريق أطر الاختبار
/// (بدون بث الشاشة). كل نداء لأطر XCTest يصير على الخيط الرئيسي (شرط XCTest) عن طريق main.sync
/// من خيط خلفي، فما فيه deadlock، وكل نداء داخل SawtTryCatch عشان أي استثناء يصير خطأ بدل كراش.
/// الجلسة (تحميل الأطر + التفويض + الإعداد) تنجهز مرة وحدة بكل تشغيل للتطبيق، وكائنات التطبيقات تنحفظ.
#if SAWTCTL
@_silgen_name("sawtctl_xct_release") private func c_xct_release_backend()
#endif

/// أول واحد ينادي claim() ياخذها (للحد الزمني: النتيجة أو انتهاء الوقت، مو الاثنين)
final class XCTOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

enum XCTBackend {
    /// عنصر من الشجرة بعد التصفية (الوكيل يحوّله لعنصره)
    struct Node: Sendable { let kind: String; let label: String; let value: String; let frame: CGRect; let secure: Bool }
    /// نتيجة قراءة الشاشة
    struct Screen: Sendable { let name: String; let bundle: String; let isSelf: Bool; let nodes: [Node]; let raw: Int; let ms: Int }

    nonisolated(unsafe) private static var prepared = false
    nonisolated(unsafe) private static var preparing = false
    nonisolated(unsafe) private static var apps: [String: NSObject] = [:]     // حسب المعرّف
    nonisolated(unsafe) private static var pidApps: [Int32: (NSObject, String)] = [:]

    static var isReady: Bool { prepared }
    /// الوكيل مختار XCTest والجلسة جاهزة
    static var active: Bool { prepared && UserDefaults.standard.string(forKey: "agentSee") == "xct" }

    // MARK: - تشغيل على الخيط الرئيسي

    /// يشغّل عمل XCTest على الخيط الرئيسي من خيط خلفي (المنادي ينتظر بدون ما يقفل الخيط الرئيسي)
    private static func onMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = DispatchQueue.main.sync { work() }
                cont.resume(returning: r)
            }
        }
    }

    /// مثل onMain بس بحد زمني: لو الخيط الرئيسي ما خلّص خلال المدة نرجع nil (العمل نفسه يكمّل بس ما ننتظره)
    private static func onMainTimed<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        let once = XCTOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            DispatchQueue.main.async {
                let r = work()
                if once.claim() { cont.resume(returning: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// يوقف انتظار "هدوء التطبيق" حق XCTest (نفس فكرة WebDriverAgent): بدونه XCTest ممكن ينتظر للأبد
    /// لو التطبيق فيه حركة مستمرة أو خيطه الرئيسي مشغول (مثل صوت نفسه وقت الاختبار). يرجع وش انعطّل
    nonisolated(unsafe) private static var quiescenceOff: String?
    /// حالة وضع الأتمتة بعد آخر تجهيز
    nonisolated(unsafe) static var automation: String = "؟"
    /// رقم جيل الجلسة: يزيد مع كل تجهيز ناجح (أي انقطاع من جيل قديم ما يأثر)
    nonisolated(unsafe) static var generation = 0
    nonisolated(unsafe) static var axLoaded: String = "؟"
    nonisolated(unsafe) static var sessionState: String = "مطفية"
    nonisolated(unsafe) private static var keeper: Task<Void, Never>?
    nonisolated(unsafe) private static var bundles: [Int32: String] = [:]
    /// سبب آخر فشل للقراءة السريعة (يطلع في سجل الاختبار)
    nonisolated(unsafe) static var lastAXError = ""

    /// مفتاح «وضع الأتمتة» في صفحة الوكيل
    static var automationOn: Bool { UserDefaults.standard.bool(forKey: "xctAutomation") }

    // MARK: - انتهاء التفويض (خطأ 41)

    /// خطأ 41 = iOS سحب تفويض اختبار الواجهة (معالج الانقطاع ما ينادى في هالحالة)
    static func isAuthLost(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.contains("Not authorized for performing UI testing") || (s.contains("XCTDaemonErrorDomain") && s.contains(" 41 "))
    }

    /// آخر أحداث حالة التطبيق (خلفية/قفل/رجوع) عشان نعرف ليش انتهى التفويض
    nonisolated(unsafe) private static var lifeEvents: [String] = []
    nonisolated(unsafe) private static var lifeObservers = false
    private static func noteLife(_ e: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lifeEvents.append("\(e) \(f.string(from: Date()))")
        if lifeEvents.count > 6 { lifeEvents.removeFirst(lifeEvents.count - 6) }
        slog("xct: life \(e)")
    }
    static func startLifecycleLog() {
        if lifeObservers { return }
        lifeObservers = true
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "خلفية"),
            (UIApplication.willEnterForegroundNotification, "رجع"),
            (UIApplication.willResignActiveNotification, "فقد التركيز"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "قفل الشاشة"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "فتح القفل"),
        ]
        for (n, label) in pairs { nc.addObserver(forName: n, object: nil, queue: nil) { _ in noteLife(label) } }
    }

    /// يعلّم الجلسة منتهية (مرة وحدة لكل جيل) ويسجّل السبب المحتمل
    static func markAuthLost(_ where_: String) {
        guard prepared else { return }
        prepared = false
        automationEnabled = false
        generation += 1
        let recent = lifeEvents.isEmpty ? "ما فيه أحداث خلفية/قفل مسجّلة" : lifeEvents.joined(separator: "، ")
        sessionState = "انتهى التفويض (\(where_)) — آخر الأحداث: \(recent)"
        slog("xct: auth lost at \(where_); recent: \(recent)")
        if automationWanted { postAutomationEnded("انتهى التفويض (\(where_))") }
    }

    /// يعيد التفويض ووضع الأتمتة (ممكن يطلب الرمز). true لو رجعت الجلسة
    static func reauthorize() async -> Bool {
        // وسط مهمة ما نرجّع وضع الأتمتة لحالنا: ممكن هو اللي وقفه بأزرار الصوت. المهمة توقف والمهمة الجاية تجهّز من جديد
        if automationWanted { slog("xct: no auto re-enable mid-task"); return false }
        let cfg = await XCTestProbe.connectionConfig()
        if let e = await prepare(cfg: cfg, force: true) { slog("xct: reauth failed: \(e)"); return false }
        return true
    }

    /// وضع الأتمتة وقف وسط مهمة (غالبًا هو وقفه بأزرار الصوت): المهمة توقف بدون إعادة تفعيل
    static func postAutomationEnded(_ why: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("sawt.automationEnded"), object: why)
        }
    }

    // MARK: - تفعيل وإطفاء وضع الأتمتة (مع المهمة)

    /// وضع الأتمتة مفعّل الحين (الشاشة معتّمة + العلامة)
    nonisolated(unsafe) static var automationEnabled = false
    /// المهمة تبيه مفعّل (عشان إعادة التفويض ترجّعه)
    nonisolated(unsafe) static var automationWanted = false

    /// يفعّل وضع الأتمتة (ممكن يطلب رمز الجوال). nil = تفعّل
    static func enableAutomation() async -> String? {
        automationWanted = true
        if automationEnabled { return nil }
        let e: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTEnableAutomation()) }
        }
        if let e {
            automation = "✗ " + e
            slog("xct: enableAutomation failed: \(e)")
            if isAuthLost(e) { markAuthLost("تفعيل الأتمتة") }
            return "تفعيل وضع الأتمتة: " + e
        }
        automationEnabled = true
        automation = "مفعّل"
        slog("xct: automation enabled")
        return nil
    }

    /// يطفّي وضع الأتمتة بعد المهمة ويخلي الجلسة جاهزة (الشاشة ترجع طبيعية).
    /// نحاول دايمًا (حتى لو حالتنا تقول مطفي، لأن الحالة ممكن تكون غلط)؛ ولو الإطفاء فشل نسكّر الجلسة زي Poki
    static func disableAutomation(force: Bool = false) async {
        automationWanted = false
        guard force || automationEnabled || prepared else { return }
        let how: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: SawtXCTDisableAutomation()) }
        }
        automationEnabled = false
        slog("xct: automation disable: \(how)")
        if !how.hasPrefix("✗") { automation = "مطفي (\(how))"; return }
        let closed: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: SawtXCTCloseSession()) }
        }
        slog("xct: disable failed, close session: \(closed)")
        // الجاية تفتح جلسة جديدة داخل العملية أول؛ لو ما قرت الشاشة بعدها نعيد التشغيل (sessionDead)
        prepared = false
        generation += 1
        automation = "الإطفاء فشل (\(how.prefix(60)))؛ الجلسة: \(closed)"
        sessionState = lightReady ? "جاهز (مفوّض، الجلسة تنفتح مع المهمة)" : "مطفية"
    }

    /// نهاية أي مهمة (نجحت، فشلت، انوقفت، خطأ): نطفّي وضع الأتمتة دايمًا
    static func endTask() async {
        await disableAutomation(force: true)
    }

    // MARK: - وضع الأتمتة (جلسة دائمة)

    /// المشغّل جاهز خفيف: الأطر محمّلة والعملية مفوّضة، بدون إعداد اختبار ولا جلسة ولا وصول (عشان ما تتعتّم الشاشة)
    nonisolated(unsafe) static var lightReady = false
    static var runnerReady: Bool { lightReady || prepared }

    /// تشغيل المشغّل (مثل زر Poki): تحميل الأطر + التفويض بس. وضع الأتمتة والجلسة يجون مع المهمة (beginTask)
    static func startAutomation() async -> String? {
        keeper?.cancel()
        startLifecycleLog()
        if runnerReady { sessionState = prepared ? sessionState : "جاهز (مفوّض، الجلسة تنفتح مع المهمة)"; startKeeper(); return nil }
        if preparing { return "التجهيز شغّال" }
        preparing = true
        let cfg = await XCTestProbe.connectionConfig()
        let t = Date()
        let err: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = XCTestProbe.loadFrameworks()
                slog("runner: step frameworks \(Int(Date().timeIntervalSince(t) * 1000))ms")
                if let bad = loaded.first(where: { !$0.ok && $0.name != "usr/lib" }) {
                    cont.resume(returning: "\(bad.name): \(bad.detail.prefix(200))"); return
                }
                let cs = XCTestProbe.classesStep()
                guard cs.ok else { cont.resume(returning: cs.detail); return }
                var checks = XCTestProbe.localChecks()
                let auth = XCTestProbe.authorizeSelf(cfg: cfg, checks: &checks)
                slog("runner: step authorize \(auth.ok ? "ok" : "failed") \(Int(Date().timeIntervalSince(t) * 1000))ms")
                cont.resume(returning: auth.ok ? nil : "التفويض: " + auth.detail)
            }
        }
        preparing = false
        if let err { sessionState = "فشل: " + String(err.prefix(80)); return err }
        lightReady = true
        sessionState = "جاهز (مفوّض، الجلسة تنفتح مع المهمة)"
        startKeeper()
        return nil
    }

    /// بداية مهمة: إعداد الاختبار والجلسة والوصول، بعدين وضع الأتمتة. كل خطوة بوقتها في السجل (عشان نعرف وش يعتّم)
    nonisolated(unsafe) static var beginning = false
    static func beginTask() async -> String? {
        beginning = true
        defer { beginning = false }
        let cfg = await XCTestProbe.connectionConfig()
        let t = Date()
        if !prepared {
            if let e = await prepare(cfg: cfg, force: true) { return e }
            slog("runner: step session+config ready \(Int(Date().timeIntervalSince(t) * 1000))ms")
        }
        if let e = await enableAutomation() { return e }
        slog("runner: step automation enabled \(Int(Date().timeIntervalSince(t) * 1000))ms")
        // مهمة جديدة: ما نحمل «معلّق» من قبل، ونتأكد إن الوصول محمّل بعد التفعيل، ومهلة قصيرة لين يستقر
        SawtXCTClearHung()
        let ax: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTLoadAccessibility(4)) }
        }
        slog("runner: step accessibility after enable: \(ax ?? "ok") \(Int(Date().timeIntervalSince(t) * 1000))ms")
        // تسخين مثل proveReadable في Poki: أول طلب يدفع كلفة أول لقطة بدل ما تنضرب قراءة المهمة الأولى
        let warm: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTWarmSystem(8)) }
        }
        slog("runner: step warm system read: \(warm ?? "ok") \(Int(Date().timeIntervalSince(t) * 1000))ms [\(SawtXCTSessionInfo())]")
        if let warm, warm.contains("ما رد") || warm.contains("معلّقة") {
            // القراءة ما ترجع أبدًا = عميل الوصول مربوط باتصال ميت. نفتح جلسة جديدة ونبني الجهاز المحلي عليها (بداية المهمة بس)
            let re: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTReopenNow()) }
            }
            slog("runner: step reopen session: \(re ?? "ok") [\(SawtXCTSessionInfo())]")
            if let re { sessionDead = true; return "القراءة ما ترد، وفشل فتح جلسة جديدة: \(re)" }
            automationEnabled = false  // الجلسة الجديدة تحتاج تفعيل من جديد
            if let e = await enableAutomation() { return e }
            let ax2: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTLoadAccessibility(4)) }
            }
            let warm2: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTWarmSystem(8)) }
            }
            slog("runner: step after reopen: ax=\(ax2 ?? "ok") warm=\(warm2 ?? "ok") \(Int(Date().timeIntervalSince(t) * 1000))ms")
            if let warm2 { sessionDead = true; return "قراءة الشاشة ما ترد حتى بعد جلسة جديدة: \(warm2)" }
            sessionDead = false
        }
        return nil
    }

    /// المراقب: يفحص الجلسة بس وقت المهمة (ما نقرأ شي والمشغّل نايم)
    private static func startKeeper() {
        keeper?.cancel()
        keeper = Task.detached(priority: .utility) {
            while !Task.isCancelled && automationOn {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled || !automationOn { break }
                if automationWanted { checkHealth() }
            }
        }
    }

    /// يوقف الجلسة الدائمة ويفك التفويض
    static func stopAutomation() {
        keeper?.cancel(); keeper = nil
        prepared = false
        lightReady = false
        automationEnabled = false
        generation += 1   // أي معالج انقطاع قديم يتجاهل
        #if SAWTCTL
        c_xct_release_backend()
        #endif
        sessionState = "مطفية"
        slog("xct: automation stopped")
    }
    private static func disableQuiescence() -> String {
        if let q = quiescenceOff { return q }
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { quiescenceOff = "XCUIApplicationProcess مو موجود"; return quiescenceOff! }
        var done: [String] = []
        let s1 = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if let m = class_getInstanceMethod(cls, s1) {
            let blk: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
            method_setImplementation(m, imp_implementationWithBlock(blk))
            done.append("idle")
        }
        let s2 = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let m = class_getInstanceMethod(cls, s2) {
            let blk: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(m, imp_implementationWithBlock(blk))
            done.append("idle+preEvent")
        }
        quiescenceOff = done.isEmpty ? "ما لقيت دوال الانتظار" : "انعطّل: " + done.joined(separator: "، ")
        slog("xct: quiescence \(quiescenceOff!)")
        return quiescenceOff!
    }

    // MARK: - تجهيز الجلسة

    /// يحمّل الأطر ويفوّض العملية ويجهّز إعداد الاختبار (مرة وحدة). يرجع nil لو جاهز، وإلا سبب الفشل
    static func prepare(cfg: String, force: Bool = false, onChecks: (@Sendable ([XCTestProbe.Check]) -> Void)? = nil) async -> String? {
        if prepared && !force { return nil }
        if force { prepared = false }
        if preparing { return "التجهيز شغّال" }
        preparing = true
        defer { preparing = false }
        let t = Date()
        let err: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = XCTestProbe.loadFrameworks()
                if let bad = loaded.first(where: { !$0.ok && $0.name != "usr/lib" }) {
                    cont.resume(returning: "\(bad.name): \(bad.detail.prefix(200))"); return
                }
                let cs = XCTestProbe.classesStep()
                guard cs.ok else { cont.resume(returning: cs.detail); return }
                var checks = XCTestProbe.localChecks()
                onChecks?(checks)
                let auth = XCTestProbe.authorizeSelf(cfg: cfg, checks: &checks)
                onChecks?(checks)
                guard auth.ok else { cont.resume(returning: "التفويض: " + auth.detail); return }
                let session: [XCTestProbe.Step] = DispatchQueue.main.sync { () -> [XCTestProbe.Step] in
                    _ = disableQuiescence()
                    return XCTestProbe.sessionSteps()
                }
                if let c = session.first(where: { $0.name == "config" }), !c.ok {
                    cont.resume(returning: "الإعداد: " + c.detail); return
                }
                // وضع الأتمتة ما يتفعّل هنا: يتفعّل لما تبدأ مهمة (enableAutomation) مثل Poki
                automationEnabled = false
                automation = "مطفي (يتفعّل مع المهمة)"
                cont.resume(returning: nil)
            }
        }
        if err == nil {
            prepared = true
            generation += 1
            let gen = generation
            axLoaded = (SawtXCTLoadAccessibility(4).map { "✗ " + $0 } ?? "محمّل") + " عبر " + SawtXCTAXSource()
            let watched = SawtXCTWatchSession {
                // الجلسة انقطعت: نعلّمها، والمراقب يعيد بناءها لو وضع الأتمتة شغّال
                guard gen == generation else { return }
                prepared = false
                automationEnabled = false
                sessionState = "انقطعت (جيل \(gen))"
                if automationWanted { postAutomationEnded("الجلسة انقطعت") }
                slog("xct: session invalidated gen \(gen)")
            }
            sessionState = "شغّالة (جيل \(gen))" + (watched ? "" : "؛ بدون مراقبة انقطاع")
        }
        slog("xct: prepare \(err == nil ? "ok" : "failed: \(err!)") \(Int(Date().timeIntervalSince(t) * 1000))ms")
        return err
    }

    // MARK: - أدوات Objective-C

    private static func send0(_ target: AnyObject, _ selName: String) -> AnyObject? {
        let sel = NSSelectorFromString(selName)
        guard target.responds(to: sel) else { return nil }
        return target.perform(sel)?.takeUnretainedValue()
    }

    private static func kvc(_ o: NSObject, _ key: String) -> Any? {
        var v: Any?
        _ = SawtTryCatch { v = o.value(forKey: key) }
        return v
    }

    /// XCUIApplication بمعرّف الحزمة (محفوظ)
    private static func app(bundle: String) -> NSObject? {
        if let a = apps[bundle] { return a }
        guard let cls = NSClassFromString("XCUIApplication") as? NSObject.Type else { return nil }
        let initSel = NSSelectorFromString("initWithBundleIdentifier:")
        guard let m = class_getInstanceMethod(cls, initSel) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let initFn = unsafeBitCast(method_getImplementation(m), to: InitFn.self)
        var out: NSObject?
        let exc = SawtTryCatch {
            // alloc يرجع +1 والـinit يستهلكه (نفس طريقة التجربة اللي اشتغلت)
            let raw: AnyObject = cls.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            out = initFn(raw, initSel, bundle as NSString)?.takeRetainedValue() as? NSObject
        }
        if let exc { slog("xct: app(\(bundle)) \(exc)") }
        if let out { apps[bundle] = out }
        return out
    }

    /// XCUIApplication برقم العملية (محفوظ) + معرّف الحزمة
    private static func app(pid: Int32) -> (NSObject, String)? {
        if let a = pidApps[pid] { return a }
        guard let cls = NSClassFromString("XCUIApplication") else { return nil }
        typealias PidFn = @convention(c) (AnyObject, Selector, Int32) -> Unmanaged<AnyObject>?
        for name in ["applicationWithPID:", "appWithPID:"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getClassMethod(cls, sel) else { continue }
            let fn = unsafeBitCast(method_getImplementation(m), to: PidFn.self)
            var obj: NSObject?
            if let exc = SawtTryCatch({ obj = fn(cls as AnyObject, sel, pid)?.takeUnretainedValue() as? NSObject }) {
                slog("xct: \(name) \(exc)"); continue
            }
            guard let obj else { continue }
            let bundle = (kvc(obj, "bundleID") as? String) ?? (kvc(obj, "bundleIdentifier") as? String) ?? ""
            pidApps[pid] = (obj, bundle)
            return (obj, bundle)
        }
        return nil
    }

    /// أرقام عمليات التطبيقات النشطة (اللي قدّام) من عميل الوصول حق XCTest
    private static func activePIDs() -> [Int32] {
        SawtXCTActiveApps().compactMap { ($0["pid"] as? NSNumber)?.int32Value }
    }

    /// التطبيق اللي قدّام: نفضّل أي تطبيق غير SpringBoard
    private static func frontApp() -> (NSObject, Int32, String)? {
        var found: [(NSObject, Int32, String)] = []
        for pid in activePIDs() {
            if let ab = app(pid: pid) { found.append((ab.0, pid, ab.1)) }
        }
        if let f = found.first(where: { $0.2 != "com.apple.springboard" }) { return f }
        if let f = found.first { return f }
        // ما قدرنا نعرف: الشاشة الرئيسية
        if let sb = app(bundle: "com.apple.springboard") { return (sb, 0, "com.apple.springboard") }
        return nil
    }

    // MARK: - اللقطة

    private static func snapshot(_ app: NSObject) -> (NSObject?, String?) {
        let sel = NSSelectorFromString("snapshotWithError:")
        guard app.responds(to: sel), let imp = app.method(for: sel) else { return (nil, "snapshotWithError: مو مدعوم") }
        typealias SnapFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
        let fn = unsafeBitCast(imp, to: SnapFn.self)
        var err: NSError?
        var snap: AnyObject?
        if let exc = SawtTryCatch({ snap = fn(app, sel, &err) }) { return (nil, exc) }
        guard let s = snap as? NSObject else {
            return (nil, err.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "رجع فاضي")
        }
        return (s, nil)
    }

    /// أنواع XCUIElementType → أسماء عناصر الوكيل
    static func kind(_ t: Int) -> String? {
        switch t {
        case 9, 14, 16, 17, 44, 80: return "button"
        case 49, 52: return "field"
        case 50: return "field"
        case 45: return "search"
        case 48: return "text"
        case 40, 41, 12: return "switch"
        case 42: return "link"
        case 43: return "image"
        case 20: return "key"
        case 75, 27, 30: return "cell"
        case 33, 39, 37: return "control"
        default: return nil
        }
    }

    /// أنواع حاويات نتجاهلها (نمشي على أولادها بس)
    /// Other(1) وGroup(3) مو منها: لو لها اسم نخليها (عناصر قابلة للضغط في تطبيقات كثيرة)
    private static let containers: Set<Int> = [0, 2, 4, 19, 21, 24, 26, 32, 46, 64, 76]

    private static func frame(_ v: Any?) -> CGRect? {
        if let v = v as? NSValue { return v.cgRectValue }
        if let d = v as? NSDictionary { return CGRect(dictionaryRepresentation: d as CFDictionary) }
        if let s = v as? String { return NSCoder.cgRect(for: s) }
        return nil
    }

    private static func text(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// يحوّل شجرة اللقطة لعناصر: العناصر اللي لها نص أو قابلة للتفاعل، بدون تكرار نص الأب
    private static func flatten(_ root: NSObject, screen: CGSize) -> (name: String, nodes: [Node], raw: Int) {
        var nodes: [Node] = []
        var raw = 0
        let b = CGRect(origin: .zero, size: screen)
        let rootName = text(kvc(root, "label"))
        func walk(_ s: NSObject, parentLabel: String, depth: Int) {
            raw += 1
            guard raw < 1500, depth < 60 else { return }
            let type = (kvc(s, "elementType") as? NSNumber)?.intValue ?? 0
            if type == 25 { return }   // شريط الحالة: الوقت والبطارية بس
            var label = text(kvc(s, "label"))
            var value = text(kvc(s, "value"))
            if value.isEmpty { value = text(kvc(s, "placeholderValue")) }
            var idOnly = false
            if label.isEmpty && value.isEmpty { label = text(kvc(s, "identifier")); idOnly = !label.isEmpty }
            let f = frame(kvc(s, "frame")) ?? .zero
            var myLabel = parentLabel
            let visible = f.width > 1 && f.height > 1 && f.intersects(b)
            if visible {
                // Other/Group: بس لو لها اسم أو قيمة حقيقية (مو معرّف برمجي بس، يزيد ضجيج)
                let k = kind(type) ?? ((label.isEmpty && value.isEmpty) || containers.contains(type) || ((type == 1 || type == 3) && idOnly) ? nil : "other")
                // نص داخل زر/صف بنفس الاسم: تكرار
                let dup = type == 48 && !label.isEmpty && label == parentLabel
                // بدون أي نص: نخلي بس الخانات والمفاتيح والمفاتيح الثنائية (الباقي ما يقدر النموذج يميّزه)
                let blank = label.isEmpty && value.isEmpty && !["field", "search", "switch", "key"].contains(k ?? "")
                if let k, !dup, !blank {
                    nodes.append(Node(kind: k, label: label, value: value, frame: f, secure: type == 50))
                    if !label.isEmpty { myLabel = label }
                }
            }
            if let kids = kvc(s, "children") as? [NSObject] {
                for c in kids { walk(c, parentLabel: myLabel, depth: depth + 1) }
            }
        }
        if let exc = SawtTryCatch({ walk(root, parentLabel: "", depth: 0) }) { slog("xct: walk \(exc)") }
        return (rootName, nodes, raw)
    }

    /// معرّف حزمة لرقم عملية: من عميل الوصول، وإلا من XCUIApplication (محفوظ)
    private static func bundleFor(_ pid: Int32, hint: String?) async -> String {
        if let b = bundles[pid] { return b }
        if let hint, !hint.isEmpty { bundles[pid] = hint; return hint }
        let b: String? = await onMainTimed(3) { () -> String in app(pid: pid)?.1 ?? "" }
        if let b, !b.isEmpty { bundles[pid] = b }
        return b ?? ""
    }

    /// قراءة سريعة عبر عميل الوصول مباشرة (بدون الخيط الرئيسي). nil = نرجع للطريقة القديمة
    /// skipSelf: نتجاهل صوت نفسه ونقرأ أول تطبيق ثاني نشط (للاختبار وصوت قدّام)
    static func readFrontAX(screen: CGSize, maxDepth: Int = 60, maxChildren: Int = 300, timeout: Double = 6, skipSelf: Bool = false) async -> Screen? {
        let t = Date()
        let me = Bundle.main.bundleIdentifier ?? "com.za7ef.sawt"
        let myPid = getpid()
        // صوت يبقى «نشط» عند عميل الوصول وهو بالخلفية (الصوت الصامت يخليه صاحي)، فما نحسبه إلا لو هو فعلًا قدّام
        let selfFront = await MainActor.run { UIApplication.shared.applicationState == .active }
        var list: [(Int32, String)] = []
        for d in SawtXCTActiveApps() {
            guard let n = d["pid"] as? NSNumber else { continue }
            let pid = n.int32Value
            if pid == myPid && (skipSelf || !selfFront) { continue }
            list.append((pid, await bundleFor(pid, hint: d["bundle"] as? String)))
        }
        slog("xct: active \(list.map { "\($0.1)#\($0.0)" }.joined(separator: ",")) selfFront=\(selfFront)")
        // شاشة النوم تبقى ضمن النشطة والجوال مفتوح (Poki: PKLockScreenOnlyBundles)؛ ما نختارها إلا لو ما فيه غيرها
        let overlays: Set<String> = ["com.apple.springboard", "com.apple.SleepLockScreen"]
        guard let front = list.first(where: { !overlays.contains($0.1) && !$0.1.isEmpty }) ?? list.first(where: { $0.1 == "com.apple.springboard" }) ?? list.first else {
            lastAXError = "ما فيه تطبيقات نشطة"
            slog("xct: ax no active apps"); return nil
        }
        let (pid, bundle) = front
        if pid == myPid || bundle == me {
            return Screen(name: "صوت", bundle: me, isSelf: true, nodes: [], raw: 0, ms: Int(Date().timeIntervalSince(t) * 1000))
        }
        func attempt(_ depth: Int, _ kids: Int, _ secs: Double) async -> (NSObject?, String) {
            readInFlight = true
            defer { readInFlight = false }
            let t0 = Date()
            return await withCheckedContinuation { (cont: CheckedContinuation<(NSObject?, String), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var why: NSString?
                    let r = SawtXCTAXRead(pid, depth, kids, secs, &why)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    slog("xct: ax read \(bundle) depth=\(depth) kids=\(kids) deadline=\(Int(secs))s → \(r == nil ? "failed: \(why ?? "")" : "ok") \(ms)ms")
                    cont.resume(returning: (r, (why as String?) ?? ""))
                }
            }
        }
        var (snap, why) = await attempt(maxDepth, maxChildren, timeout)
        // انتهى الوقت: نعيد مرة بحدود أصغر (الشجرة الكاملة للشاشة الرئيسية ممكن تكون كبيرة)
        if snap == nil && why.contains("ما رد خلال") {
            (snap, why) = await attempt(25, 100, timeout + 2)
        }
        if snap == nil { lastAXError = "\(bundle): \(why)" } else { lastReadOK = Date() }
        guard let snap else { return nil }
        let (name, nodes, raw) = flatten(snap, screen: screen)
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        let shown = bundle == "com.apple.springboard" ? "الشاشة الرئيسية" : (name.isEmpty ? bundle : name)
        slog("xct: ax read \(bundle) raw=\(raw) els=\(nodes.count) \(ms)ms")
        return Screen(name: shown, bundle: bundle, isSelf: false, nodes: nodes, raw: raw, ms: ms)
    }

    /// يقرأ التطبيق اللي قدّام عبر عميل الوصول فقط (بدون رجوع لطريقة ثانية). لو التفويض انتهى نعيده ونحاول مرة.
    /// الفشل: nil والسبب في lastAXError
    static func readFront(screen: CGSize) async -> Screen? {
        if !prepared && !preparing {
            guard await reauthorize() else { lastAXError = "الجلسة مو جاهزة وفشلت إعادة التفويض"; return nil }
        }
        guard prepared else { lastAXError = "الجلسة مو جاهزة"; return nil }
        if let s = await readFrontAX(screen: screen) { return s }
        if isAuthLost(lastAXError) {
            markAuthLost("قراءة")
            guard await reauthorize() else { lastAXError = "انتهى التفويض وفشلت إعادته"; return nil }
            return await readFrontAX(screen: screen)
        }
        return nil
    }

    nonisolated(unsafe) static var readInFlight = false
    /// انسكّرت جلسة في هذا التشغيل أو ما ترد القراءة حتى بعد جلسة جديدة
    nonisolated(unsafe) static var sessionDead = false
    nonisolated(unsafe) static var lastReadOK = Date.distantPast

    /// فحص صحة سريع للجلسة (قراءة بعمق ١). لو رجع 41 نعلّمها منتهية.
    /// ما نفحص وقت قراءة شغّالة أو بعد قراءة ناجحة قريبة (الفحص المتزامن كان يعلّق الشاشة الرئيسية ويخليها «معلّقة»)
    static func checkHealth() {
        guard prepared, !preparing, !readInFlight, !beginning, Date().timeIntervalSince(lastReadOK) > 10 else { return }
        // مثل Poki: الفحص على الشاشة الرئيسية بعمق ١ (مو أول تطبيق بالقائمة اللي ممكن يكون صوت أو تطبيق مشغول)
        let why = SawtXCTWarmSystem(3)
        if let why { slog("xct: health check: \(why)") }
        if isAuthLost(why) { markAuthLost("فحص الصحة") }
    }

    // MARK: - الأفعال

    private typealias VecFn = @convention(c) (AnyObject, Selector, CGVector) -> Unmanaged<AnyObject>?
    private typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void

    /// إحداثية مطلقة على الشاشة (بالنقاط) عن طريق عنصر SpringBoard
    private static func coordinate(_ p: CGPoint) -> NSObject? {
        guard let sb = app(bundle: "com.apple.springboard") else { return nil }
        let s1 = NSSelectorFromString("coordinateWithNormalizedOffset:")
        guard sb.responds(to: s1), let i1 = sb.method(for: s1) else { return nil }
        guard let origin = unsafeBitCast(i1, to: VecFn.self)(sb, s1, CGVector(dx: 0, dy: 0))?.takeUnretainedValue() as? NSObject else { return nil }
        let s2 = NSSelectorFromString("coordinateWithOffset:")
        guard origin.responds(to: s2), let i2 = origin.method(for: s2) else { return nil }
        return unsafeBitCast(i2, to: VecFn.self)(origin, s2, CGVector(dx: p.x, dy: p.y))?.takeUnretainedValue() as? NSObject
    }

    private static func callVoid(_ o: NSObject, _ name: String) -> String? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let imp = o.method(for: sel) else { return "\(name) مو مدعوم" }
        return SawtTryCatch { unsafeBitCast(imp, to: VoidFn.self)(o, sel) }
    }

    private static func result(_ err: String?, _ what: String, _ t: Date) -> String {
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        slog("xct: \(what) \(err == nil ? "ok" : "failed: \(err!)") \(ms)ms")
        if let err {
            let e = err.replacingOccurrences(of: "\"", with: "'")
            return "{\"ok\":false,\"via\":\"xct\",\"error\":\"\(e.prefix(200))\"}"
        }
        return "{\"ok\":true,\"via\":\"xct\",\"ms\":\(ms)}"
    }

    /// يرسل حدث لمس مركّب عبر daemonProxy من خيط خلفي (بدون الخيط الرئيسي وبدون انتظار الهدوء). nil = انقبل
    private static func synth(_ pts: [CGPoint], duration: Double, timeout: Double) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: SawtXCTSynthesize(pts.map { NSValue(cgPoint: $0) }, duration, timeout))
            }
        }
    }

    /// لمسة على نقطة بالنقاط (إحداثيات الشاشة) بحدث مركّب. لو التفويض انتهى (41) نعيده ونحاول مرة وحدة.
    /// ما فيه رجوع لأي طريقة ثانية: الفشل يرجع بسببه
    static func tap(_ p: CGPoint) async -> String {
        let t = Date()
        var err = await synth([p], duration: 0.05, timeout: 5)
        if isAuthLost(err) {
            markAuthLost("لمس")
            if await reauthorize() { err = await synth([p], duration: 0.05, timeout: 5) }
            else { err = "انتهى التفويض وفشلت إعادته: \(err ?? "")" }
        }
        return result(err.map { "اللمس المركّب فشل: \($0)" }, "tap \(Int(p.x)),\(Int(p.y))", t)
    }

    /// يكتب نص (أو "\n" للإدخال) بحدث كتابة مركّب في الحقل اللي عليه التركيز. نفس قواعد اللمس: 41 = إعادة تفويض ومحاولة وحدة
    static func type(_ text: String, what: String) async -> String {
        let t = Date()
        func run() async -> String? {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTTypeText(text, 60, 5)) }
            }
        }
        var err = await run()
        if isAuthLost(err) {
            markAuthLost("كتابة")
            if await reauthorize() { err = await run() }
            else { err = "انتهى التفويض وفشلت إعادته: \(err ?? "")" }
        }
        // ما نسجّل النص نفسه (ممكن كلمة سر)، بس الطول
        return result(err.map { "الكتابة المركّبة فشلت: \($0)" }, "\(what) \(text.count) حرف", t)
    }

    /// ضغط مطوّل (ثانية) بحدث مركّب
    static func longPress(_ p: CGPoint) async -> String {
        let t = Date()
        if !prepared { return result("جلسة XCTest مو جاهزة", "longpress", t) }
        let err = await synth([p], duration: 1.0, timeout: 6)
        if isAuthLost(err) { markAuthLost("ضغط مطوّل") }
        return result(err.map { "الضغط المطوّل فشل: \($0)" }, "longpress \(Int(p.x)),\(Int(p.y))", t)
    }

    /// يفتح رابط مباشرة عبر XCUIDevice.sharedDevice.system openURL:error: (iOS 16.4+)
    static func openURL(_ u: URL) async -> String {
        let t = Date()
        if !prepared { return result("جلسة XCTest مو جاهزة", "openURL", t) }
        let err: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTOpenURL(u)) }
        }
        return result(err, "openURL", t)
    }

    /// سحب من نقطة لنقطة بحدث مركّب (نفس قواعد اللمس)
    static func drag(_ a: CGPoint, _ b: CGPoint) async -> String {
        let t = Date()
        var err = await synth([a, b], duration: 0.3, timeout: 5)
        if isAuthLost(err) {
            markAuthLost("سحب")
            if await reauthorize() { err = await synth([a, b], duration: 0.3, timeout: 5) }
            else { err = "انتهى التفويض وفشلت إعادته: \(err ?? "")" }
        }
        return result(err.map { "السحب المركّب فشل: \($0)" }, "drag \(Int(a.x)),\(Int(a.y))→\(Int(b.x)),\(Int(b.y))", t)
    }

    /// زر الهوم (حدث HID على خيط خلفي، مثل Poki؛ pressButton على الخيط الرئيسي كان يضيّع الرفض بصمت)
    static func home() async -> String {
        let t = Date()
        let err: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTPressHome()) }
        }
        return result(err, "home", t)
    }

    /// يفتح تطبيق بمعرّف الحزمة عبر testmanagerd (مثل Poki)
    static func open(bundle: String) async -> String {
        let t = Date()
        let err: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: SawtXCTLaunch(bundle, 15)) }
        }
        return result(err, "open \(bundle)", t)
    }

    /// معرّف حزمة؟ (com.apple.x) — بدون مسافات وفيه نقطتين على الأقل
    static func looksLikeBundle(_ s: String) -> Bool {
        !s.contains(" ") && s.split(separator: ".").count >= 3 && s.allSatisfy { $0.isASCII }
    }

    /// ينفّذ أوامر اللمس والسحب والهوم وفتح التطبيق بالمعرّف بـXCTest، ويرجع النتيجة نجحت أو فشلت (بدون رجوع لـsawtctl).
    /// nil = نوع أمر ما تسويه XCTest (مثل الكتابة)
    static func handle(_ op: PhoneControl.Op, screen: CGSize) async -> String? {
        func den(_ x: UInt16, _ y: UInt16) -> CGPoint {
            CGPoint(x: Double(x) / 65535 * screen.width, y: Double(y) / 65535 * screen.height)
        }
        switch op {
        case .tap, .drag, .keys("home"), .keys("return"): break
        case .keys(let w) where w.hasPrefix("paste:"): break
        case .launch(let q) where looksLikeBundle(q): break
        default: return nil
        }
        if !prepared && !preparing {
            let ok = await reauthorize()
            if !ok { return result("جلسة XCTest مو جاهزة وفشلت إعادة التفويض", "op", Date()) }
        }
        switch op {
        case .tap(let x, let y): return await tap(den(x, y))
        case .drag(let a, let b, let x, let y): return await drag(den(a, b), den(x, y))
        case .launch(let q): return await open(bundle: q)
        case .keys("return"): return await type("\n", what: "return")
        case .keys(let w) where w.hasPrefix("paste:"): return await type(String(w.dropFirst(6)), what: "type")
        default: return await home()
        }
    }

    // MARK: - اختبار الضغط

    /// يجهّز الجلسة من جديد (تفويض جديد كل مرة)، يقيس لقطة SpringBoard، يعرف اللي قدّام، ويلمس الهدف.
    /// كل خطوة لها حد زمني وتنكتب في السجل أول ما تبدأ وأول ما تخلص (onLine)، فلو علّقت نعرف وين.
    /// يرجع false لو وقف بسبب خطأ أو انتهاء وقت.
    static func tapTest(cfg: String, target: CGPoint, screen: CGSize,
                        onLine: @escaping @Sendable (String) -> Void,
                        onChecks: @escaping @Sendable ([XCTestProbe.Check]) -> Void) async -> Bool {
        func add(_ ok: Bool, _ name: String, _ t: Date, _ d: String) {
            let l = "\(ok ? "✓" : "✗") \(name) (\(Int(Date().timeIntervalSince(t) * 1000))ms): \(d)"
            slog("xct: tapTest \(l)"); onLine(l)
        }
        func start(_ name: String) { slog("xct: tapTest start \(name)"); onLine("… \(name): بدأ") }

        startLifecycleLog()
        // ١) التجهيز مع تفويض جديد (الجلسة القديمة ممكن تنرفض: XCTDaemonErrorDomain 41)
        var t = Date()
        start("prepare")
        let keep = automationOn && prepared
        let prep: String?? = await withTimeout(90) { await prepare(cfg: cfg, force: !keep, onChecks: onChecks) }
        guard let prepRes = prep else { add(false, "prepare", t, "انتهى الوقت (٩٠ ثانية)؛ غالبًا الاتصال المحلي أو رمز الجوال"); return false }
        if let e = prepRes { add(false, "prepare", t, e); return false }
        add(true, "prepare", t, "\(keep ? "الجلسة الدائمة" : "تفويض جديد")؛ \(sessionState)؛ وضع الأتمتة: \(automation)؛ الوصول: \(axLoaded)؛ انتظار الهدوء: \(quiescenceOff ?? "؟")")
        t = Date()
        start("automation")
        if let e = await enableAutomation() { add(false, "automation", t, e); return false }
        add(true, "automation", t, "وضع الأتمتة مفعّل (ينطفي آخر الاختبار)")
        defer { Task { await disableAutomation() } }

        // ٢أ) القراءة السريعة عبر عميل الوصول (مرتين: الثانية ساخنة)
        for i in 1...2 {
            t = Date()
            start("read-ax\(i)")
            let r: Screen?? = await withTimeout(12) { await readFrontAX(screen: screen, skipSelf: true) }
            switch r {
            case .none: add(false, "read-ax\(i)", t, "انتهى الوقت (١٢ ثانية)")
            case .some(.none): add(false, "read-ax\(i)", t, "فشلت: \(lastAXError.prefix(200))")
            case .some(.some(let sc)):
                let sample = sc.nodes.prefix(5).map { "\($0.kind):\($0.label.prefix(18))" }.joined(separator: "، ")
                add(true, "read-ax\(i)", t, sc.isSelf ? "صوت نفسه قدّام (ما نقرأه)" : "\(sc.name)؛ \(sc.raw) عقدة، \(sc.nodes.count) عنصر؛ \(sample)")
            }
        }

        // ٢ب) للمقارنة: لقطة SpringBoard بالطريقة القديمة (XCUIApplication) مرة وحدة
        for i in 1...1 {
            t = Date()
            start("snapshot\(i)")
            let s: (Bool, String)? = await onMainTimed(20) { () -> (Bool, String) in
                guard let sb = app(bundle: "com.apple.springboard") else { return (false, "XCUIApplication") }
                let (snap, err) = snapshot(sb)
                guard let snap else { return (false, err ?? "؟") }
                let fl = flatten(snap, screen: screen)
                let sample = fl.nodes.prefix(6).map { "\($0.kind):\($0.label.prefix(20))" }.joined(separator: "، ")
                return (true, "\(fl.raw) عقدة، \(fl.nodes.count) عنصر؛ \(sample)")
            }
            guard var s else { add(false, "snapshot\(i)", t, "انتهى الوقت (٢٠ ثانية)"); return false }
            if !s.0 && isAuthLost(s.1) {
                add(false, "snapshot\(i)", t, s.1)
                markAuthLost("اختبار")
                onLine("… التفويض انتهى: \(sessionState)؛ نعيد التفويض")
                t = Date()
                guard await reauthorize() else { add(false, "reauth", t, "فشل إعادة التفويض"); return false }
                add(true, "reauth", t, "\(sessionState)؛ وضع الأتمتة: \(automation)")
                t = Date()
                s = await onMainTimed(20) { () -> (Bool, String) in
                    guard let sb = app(bundle: "com.apple.springboard") else { return (false, "XCUIApplication") }
                    let (snap, err) = snapshot(sb)
                    guard let snap else { return (false, err ?? "؟") }
                    let fl = flatten(snap, screen: screen)
                    return (true, "\(fl.raw) عقدة، \(fl.nodes.count) عنصر (بعد إعادة التفويض)")
                } ?? (false, "انتهى الوقت")
            }
            add(s.0, "snapshot\(i)", t, s.1)   // فشلها ما يوقف الاختبار (مقارنة بس)
        }

        // ٣) التطبيق اللي قدّام
        t = Date()
        start("front")
        let front: String? = await onMainTimed(10) { () -> String in
            let pids = activePIDs()
            guard let f = frontApp() else { return "ما عرف (\(pids.count) نشط)" }
            return "\(f.2) pid \(f.1)؛ نشط: \(pids.count)"
        }
        if let front { add(!front.hasPrefix("ما"), "front", t, front) } else { add(false, "front", t, "انتهى الوقت (١٠ ثواني)") }

        // ٤) اللمس (حدث مركّب عبر daemonProxy، ولو ما انقبل XCUICoordinate بحد زمني)
        t = Date()
        start("tap")
        let r: String? = await withTimeout(25) { await tap(target) }
        guard let r else { add(false, "tap", t, "انتهى الوقت (٢٥ ثانية)"); return false }
        let ok = r.contains("\"ok\":true")
        add(ok, "tap", t, "(\(Int(target.x)), \(Int(target.y))) " + r)
        return ok
    }

    /// ينتظر عمل async بحد زمني. nil = انتهى الوقت
    /// يرجع أول اللي يخلص: الشغل أو المهلة. ما ننتظر الشغل لو ما يحترم الإلغاء (withTaskGroup كان ينتظر الأولاد)
    private static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = SawtOnce()
            Task { let v = await work(); if once.take() { c.resume(returning: v) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if once.take() { c.resume(returning: nil) } }
        }
    }
}


/// علم «مرة وحدة» آمن بين الخيوط
final class SawtOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
