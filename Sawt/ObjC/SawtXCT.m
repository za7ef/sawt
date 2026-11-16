#import "SawtXCT.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// كتابة مستقلة لصوت. الأسماء الخاصة (XCTRunnerDaemonSession، XCSynthesizedEventRecord، XCPointerEventPath،
// _XCT_synthesizeEvent:) من أطر XCTest اللي تنحمّل وقت التشغيل من صورة المطوّر.

static id SawtSharedSession(NSString **why) {
    Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
    if (!cls) { *why = @"XCTRunnerDaemonSession مو موجود"; return nil; }
    SEL s = NSSelectorFromString(@"sharedSession");
    if (![cls respondsToSelector:s]) { *why = @"sharedSession مو مدعوم"; return nil; }
    id session = ((id (*)(id, SEL))objc_msgSend)(cls, s);
    if (!session) *why = @"sharedSession رجع فاضي";
    return session;
}

NSString * _Nullable SawtXCTEnableAutomation(void) {
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        if (!session) return why;
        SEL s = NSSelectorFromString(@"enableAutomationModeWithError:");
        if (![session respondsToSelector:s]) return @"enableAutomationModeWithError: مو مدعوم";
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(session, s, &err);
        if (ok) return nil;
        return err ? [NSString stringWithFormat:@"%@ %ld %@", err.domain, (long)err.code, err.localizedDescription] : @"رجع NO";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}

static BOOL SawtHas(id obj, SEL s) {
    @try { return [obj methodSignatureForSelector:s] != nil; } @catch (__unused NSException *e) { return NO; }
}

NSString *SawtXCTDisableAutomation(void) {
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        if (!session) return [@"✗ " stringByAppendingString:why ?: @"ما فيه جلسة"];
        SEL direct = NSSelectorFromString(@"disableAutomationModeWithError:");
        if ([session respondsToSelector:direct]) {
            NSError *err = nil;
            BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(session, direct, &err);
            return ok ? @"disableAutomationModeWithError:" :
                [NSString stringWithFormat:@"✗ disableAutomationModeWithError: %@", err.localizedDescription ?: @"رجع NO"];
        }
        SEL proxySel = NSSelectorFromString(@"daemonProxy");
        id proxy = [session respondsToSelector:proxySel] ? ((id (*)(id, SEL))objc_msgSend)(session, proxySel) : nil;
        SEL msg = NSSelectorFromString(@"_XCT_disableAutomationModeWithReply:");
        NSMethodSignature *sig = proxy ? [proxy methodSignatureForSelector:msg] : nil;
        if (!sig || sig.numberOfArguments != 3) return @"✗ ما فيه دالة لإطفاء وضع الأتمتة";
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL answered = NO;
        void (^reply)(void) = ^{ answered = YES; dispatch_semaphore_signal(done); };
        ((void (*)(id, SEL, id))objc_msgSend)(proxy, msg, reply);
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        return answered ? @"_XCT_disableAutomationModeWithReply:" : @"✗ _XCT_disableAutomationModeWithReply: ما رد";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"✗ %@: %@", e.name, e.reason ?: @""];
    }
}

NSString * _Nullable SawtXCTSynthesize(NSArray<NSValue *> *points, double duration, double timeout) {
    if (points.count == 0) return @"ما فيه نقاط";
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        if (!session) return why;
        Class recordCls = NSClassFromString(@"XCSynthesizedEventRecord");
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        if (!recordCls || !pathCls) return @"XCSynthesizedEventRecord/XCPointerEventPath مو موجودين";

        // السجل: نفضّل الاتجاه الصريح (1 = عمودي)
        id record = nil;
        SEL initOriented = NSSelectorFromString(@"initWithName:interfaceOrientation:");
        SEL initName = NSSelectorFromString(@"initWithName:");
        id rawRecord = [recordCls alloc];
        if ([recordCls instancesRespondToSelector:initOriented]) {
            record = ((id (*)(id, SEL, id, long long))objc_msgSend)(rawRecord, initOriented, @"Sawt", 1);
        } else if ([recordCls instancesRespondToSelector:initName]) {
            record = ((id (*)(id, SEL, id))objc_msgSend)(rawRecord, initName, @"Sawt");
        } else {
            return @"ما لقيت مُنشئ XCSynthesizedEventRecord";
        }
        if (!record) return @"XCSynthesizedEventRecord رجع فاضي";

        SEL initTouch = NSSelectorFromString(@"initForTouchAtPoint:offset:");
        SEL moveTo = NSSelectorFromString(@"moveToPoint:atOffset:");
        SEL liftUp = NSSelectorFromString(@"liftUpAtOffset:");
        SEL addPath = NSSelectorFromString(@"addPointerEventPath:");
        if (![pathCls instancesRespondToSelector:initTouch] || ![pathCls instancesRespondToSelector:liftUp] ||
            ![record respondsToSelector:addPath]) return @"دوال مسار اللمس مو موجودة";

        CGPoint first = points.firstObject.CGPointValue;
        id path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)([pathCls alloc], initTouch, first, 0.0);
        if (!path) return @"XCPointerEventPath رجع فاضي";
        double total = points.count == 1 ? MAX(duration, 0.05) : MAX(duration, 0.2);
        if (points.count > 1) {
            if (![pathCls instancesRespondToSelector:moveTo]) return @"moveToPoint:atOffset: مو موجود";
            NSUInteger n = points.count - 1;
            for (NSUInteger i = 1; i < points.count; i++) {
                ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, moveTo, points[i].CGPointValue, total * (double)i / (double)n);
            }
            total += 0.05;
        }
        ((void (*)(id, SEL, double))objc_msgSend)(path, liftUp, total);
        ((void (*)(id, SEL, id))objc_msgSend)(record, addPath, path);

        // الإرسال عبر daemonProxy (غير متزامن، بدون انتظار هدوء التطبيق)
        SEL proxySel = NSSelectorFromString(@"daemonProxy");
        id proxy = [session respondsToSelector:proxySel] ? ((id (*)(id, SEL))objc_msgSend)(session, proxySel) : nil;
        if (!proxy) return @"daemonProxy مو موجود";
        __block NSString *reply = nil;
        __block BOOL done = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        void (^completion)(NSError *) = ^(NSError *e) {
            reply = e ? [NSString stringWithFormat:@"%@ %ld %@", e.domain, (long)e.code, e.localizedDescription] : nil;
            done = YES;
            dispatch_semaphore_signal(sem);
        };
        SEL s3 = NSSelectorFromString(@"_XCT_synthesizeEvent:implicitConfirmationInterval:completion:");
        SEL s2 = NSSelectorFromString(@"_XCT_synthesizeEvent:completion:");
        NSString *via;
        if (SawtHas(proxy, s3)) {
            via = @"implicit";
            ((void (*)(id, SEL, id, double, id))objc_msgSend)(proxy, s3, record, 0.0, completion);
        } else if (SawtHas(proxy, s2)) {
            via = @"plain";
            ((void (*)(id, SEL, id, id))objc_msgSend)(proxy, s2, record, completion);
        } else {
            return @"daemonProxy ما فيه _XCT_synthesizeEvent";
        }
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + total) * NSEC_PER_SEC)));
        (void)[record class];   // نخلي السجل حي لين يجي الرد
        if (waited != 0 && !done) return [NSString stringWithFormat:@"ما جا رد خلال %.0f ثانية (%@)", timeout + total, via];
        return reply;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}

// MARK: - قراءة الشاشة عبر عميل الوصول

/// مصدر عميل الوصول اللي لقيناه (للسجل)
static NSString *gSawtAXSource = @"ما انلقى";

/// عميل الوصول: من XCUIDevice.sharedDevice.accessibilityInterface (الطريقة الحالية)، وإلا XCAXClient_iOS.sharedClient
static id SawtAXClient(void) {
    @try {
        Class dev = NSClassFromString(@"XCUIDevice");
        SEL shared = NSSelectorFromString(@"sharedDevice");
        if (dev && [dev respondsToSelector:shared]) {
            id device = ((id (*)(id, SEL))objc_msgSend)(dev, shared);
            for (NSString *name in @[@"accessibilityInterface", @"_accessibilityInterface"]) {
                SEL s = NSSelectorFromString(name);
                if (device && [device respondsToSelector:s]) {
                    id ax = ((id (*)(id, SEL))objc_msgSend)(device, s);
                    if (ax) { gSawtAXSource = [NSString stringWithFormat:@"XCUIDevice.%@ (%@)", name, NSStringFromClass([ax class])]; return ax; }
                }
            }
        }
        Class cls = NSClassFromString(@"XCAXClient_iOS");
        SEL s = NSSelectorFromString(@"sharedClient");
        if (cls && [cls respondsToSelector:s]) {
            id ax = ((id (*)(id, SEL))objc_msgSend)(cls, s);
            if (ax) { gSawtAXSource = @"XCAXClient_iOS.sharedClient"; return ax; }
        }
    } @catch (__unused NSException *e) {}
    gSawtAXSource = @"ما انلقى (لا accessibilityInterface ولا XCAXClient_iOS)";
    return nil;
}

NSString *SawtXCTAXSource(void) {
    (void)SawtAXClient();
    return gSawtAXSource;
}

/// رقم العملية من عنصر الوصول (الدالة ترجع int أو long long حسب الإصدار)
static int SawtPid(id element) {
    SEL s = NSSelectorFromString(@"processIdentifier");
    @try {
        if (!element || ![element respondsToSelector:s]) return 0;
        const char *type = [element methodSignatureForSelector:s].methodReturnType;
        if (type && strcmp(type, @encode(int)) == 0) return ((int (*)(id, SEL))objc_msgSend)(element, s);
        return (int)((long long (*)(id, SEL))objc_msgSend)(element, s);
    } @catch (__unused NSException *e) { return 0; }
}

NSString * _Nullable SawtXCTBundleForPID(int pid, double timeout) {
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        SEL proxySel = NSSelectorFromString(@"daemonProxy");
        id proxy = (session && [session respondsToSelector:proxySel]) ? ((id (*)(id, SEL))objc_msgSend)(session, proxySel) : nil;
        SEL s = NSSelectorFromString(@"_XCT_requestBundleIDForPID:reply:");
        if (!proxy || !SawtHas(proxy, s)) return nil;
        __block NSString *bundle = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        void (^reply)(NSString *, NSError *) = ^(NSString *value, __unused NSError *error) {
            if ([value isKindOfClass:NSString.class]) bundle = value;
            dispatch_semaphore_signal(sem);
        };
        ((void (*)(id, SEL, int, id))objc_msgSend)(proxy, s, pid, reply);
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        return bundle.length ? bundle : nil;
    } @catch (__unused NSException *e) { return nil; }
}

static id SawtKVC(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSArray *SawtActiveElements(id client) {
    SEL s = NSSelectorFromString(@"activeApplications");
    if (!client || ![client respondsToSelector:s]) return @[];
    id list = ((id (*)(id, SEL))objc_msgSend)(client, s);
    return [list isKindOfClass:NSArray.class] ? list : @[];
}

/// عنصر الشاشة الرئيسية (SpringBoard) من عميل الوصول: systemApplication (زي Poki)
static id SawtSystemApp(id client) {
    @try {
        SEL s = NSSelectorFromString(@"systemApplication");
        if (client && [client respondsToSelector:s]) return ((id (*)(id, SEL))objc_msgSend)(client, s);
    } @catch (__unused NSException *e) {}
    return nil;
}

/// النشطة + الشاشة الرئيسية لو مو فيها (لما نكون في الرئيسية activeApplications ممكن ترجع فاضية)
static NSArray *SawtActiveWithSystem(id client) {
    NSMutableArray *all = [NSMutableArray arrayWithArray:SawtActiveElements(client) ?: @[]];
    id sys = SawtSystemApp(client);
    int sp = SawtPid(sys);
    if (sp > 0) {
        BOOL has = NO;
        for (id e in all) if (SawtPid(e) == sp) { has = YES; break; }
        if (!has) [all addObject:sys];
    }
    return all;
}

NSArray<NSDictionary<NSString *, id> *> *SawtXCTActiveApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id client = SawtAXClient();
        int sp = SawtPid(SawtSystemApp(client));
        for (id e in SawtActiveWithSystem(client)) {
            int p = SawtPid(e);
            if (p <= 0) continue;
            NSString *bundle = SawtKVC(e, @"bundleIdentifier") ?: SawtKVC(e, @"bundleID");
            if (p == sp) bundle = @"com.apple.springboard";
            if (![bundle isKindOfClass:NSString.class] || !bundle.length) bundle = SawtXCTBundleForPID(p, 1.0);
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@(p) forKey:@"pid"];
            if ([bundle isKindOfClass:NSString.class] && bundle.length) d[@"bundle"] = bundle;
            [out addObject:d];
        }
    } @catch (__unused NSException *e) {}
    return out;
}

/// ينفّذ الكتلة على خيط خلفي وينتظرها بحد زمني. timedOut = YES لو ما خلصت
static id SawtWithin(double seconds, BOOL *timedOut, id (^work)(void)) {
    __block id result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id r = work();
        result = r;
        dispatch_semaphore_signal(sem);
    });
    BOOL late = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) != 0;
    if (timedOut) *timedOut = late;
    return late ? nil : result;
}

NSString * _Nullable SawtXCTLoadAccessibility(double timeout) {
    id client = SawtAXClient();
    if (!client) return gSawtAXSource;
    SEL s = NSSelectorFromString(@"loadAccessibility:");
    if (![client respondsToSelector:s]) return @"loadAccessibility: مو مدعوم";
    BOOL late = NO;
    NSString *r = SawtWithin(timeout, &late, ^id {
        @try {
            NSError *err = nil;
            BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, s, &err);
            if (ok) return @"";
            return err ? err.localizedDescription : @"رجع NO";
        } @catch (NSException *e) {
            return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
        }
    });
    if (late) return [NSString stringWithFormat:@"ما رد خلال %.0f ثانية", timeout];
    return r.length ? r : nil;
}

/// الخصائص اللي نحتاجها بس (كل خاصية زيادة تكلّف خادم الوصول طلبات أكثر لكل عنصر)
static NSArray *SawtSnapshotAttributes(void) {
    static NSArray *attrs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *keys = @[@"elementType", @"identifier", @"label", @"value", @"placeholderValue", @"frame", @"children"];
        attrs = keys;
        Class snap = NSClassFromString(@"XCElementSnapshot");
        SEL map = NSSelectorFromString(@"axAttributesForElementSnapshotKeyPaths:isMacOS:");
        if (snap && [snap respondsToSelector:map]) {
            @try {
                id mapped = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(snap, map, keys, NO);
                if ([mapped isKindOfClass:NSSet.class]) mapped = [(NSSet *)mapped allObjects];
                if ([mapped isKindOfClass:NSArray.class] && [(NSArray *)mapped count] > 0) attrs = mapped;
            } @catch (__unused NSException *e) {}
        }
    });
    return attrs;
}

static NSMutableDictionary<NSNumber *, NSDate *> *SawtHung(void) {
    static NSMutableDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

NSString * _Nullable SawtXCTWarmSystem(double timeout) {
    id client = SawtAXClient();
    if (!client) return gSawtAXSource;
    int pid = SawtPid(SawtSystemApp(client));
    if (pid <= 0) return @"ما فيه systemApplication";
    NSString *why = nil;
    return SawtXCTAXRead(pid, 1, 1, timeout, &why) ? nil : (why ?: @"فشل");
}

void SawtXCTClearHung(void) {
    @synchronized (SawtHung()) { [SawtHung() removeAllObjects]; }
}

NSObject * _Nullable SawtXCTAXRead(int pid, NSInteger maxDepth, NSInteger maxChildren, double timeout, NSString * _Nullable * _Nullable why) {
    NSString *reason = nil;
    NSObject *root = nil;
    @try {
        NSNumber *key = @(pid);
        // طلب سابق لنفس العملية ما رجع (الجهاز يخدم طلب وصول واحد بالمرة): ننتظره لين يرد بحد المهلة،
        // لأن أي طلب جديد بيقف وراه. العلامة تنمسح لحالها أول ما يرد (مثل Poki)
        NSDate *waitUntil = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while (YES) {
            BOOL marked;
            @synchronized (SawtHung()) { marked = SawtHung()[key] != nil; }
            if (!marked) break;
            if (waitUntil.timeIntervalSinceNow <= 0) {
                if (why) *why = [NSString stringWithFormat:@"العملية معلّقة: طلب سابق ما رد بعد (انتظرنا %.0f ثانية)", timeout];
                return nil;
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        id client = SawtAXClient();
        if (!client) { if (why) *why = gSawtAXSource; return nil; }
        id element = nil;
        for (id e in SawtActiveWithSystem(client)) {
            if (SawtPid(e) == pid) { element = e; break; }
        }
        if (!element) { if (why) *why = @"التطبيق مو ضمن النشطة"; return nil; }
        SEL req = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
        if (![client respondsToSelector:req]) { if (why) *why = @"requestSnapshotForElement مو مدعوم"; return nil; }
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        SEL defSel = NSSelectorFromString(@"defaultParameters");
        if ([client respondsToSelector:defSel]) {
            id defs = ((id (*)(id, SEL))objc_msgSend)(client, defSel);
            if ([defs isKindOfClass:NSDictionary.class]) [params addEntriesFromDictionary:defs];
        }
        if (maxDepth > 0) params[@"maxDepth"] = @(maxDepth);
        if (maxChildren > 0) { params[@"maxChildren"] = @(maxChildren); params[@"maxArrayCount"] = @(maxChildren); }
        params[@"traverseFromParentsToChildren"] = @YES;
        NSDictionary *frozen = params.copy;
        NSArray *attrs = SawtSnapshotAttributes();
        __block NSString *err = nil;
        __block id result = nil;
        __block BOOL finished = NO, abandoned = NO;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id r = nil;
            @try {
                NSError *e = nil;
                r = ((id (*)(id, SEL, id, id, id, NSError **))objc_msgSend)(client, req, element, attrs, frozen, &e);
                if (!r) err = e ? [NSString stringWithFormat:@"%@ %ld %@", e.domain, (long)e.code, e.localizedDescription] : @"رجع فاضي";
            } @catch (NSException *x) {
                err = [NSString stringWithFormat:@"%@: %@", x.name, x.reason ?: @""];
            }
            @synchronized (SawtHung()) {
                finished = YES;
                // رد متأخر: نشيل العلامة عشان نسأله من جديد
                if (abandoned) [SawtHung() removeObjectForKey:key];
                else result = r;
            }
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
            BOOL late = NO;
            @synchronized (SawtHung()) {
                if (!finished) { abandoned = YES; late = YES; SawtHung()[key] = [NSDate date]; }
            }
            if (late) {
                if (why) *why = [NSString stringWithFormat:@"ما رد خلال %.0f ثانية", timeout];
                return nil;
            }
        }
        if (!result) { reason = err ?: @"رجع فاضي"; }
        else {
            // النتيجة أحيانًا غلاف فيه الجذر
            id inner = SawtKVC(result, @"rootElementSnapshot") ?: SawtKVC(result, @"_rootElementSnapshot");
            root = [inner isKindOfClass:NSObject.class] ? inner : result;
        }
    } @catch (NSException *x) {
        reason = [NSString stringWithFormat:@"%@: %@", x.name, x.reason ?: @""];
    }
    if (!root && why) *why = reason;
    return root;
}

BOOL SawtXCTWatchSession(void (^handler)(void)) {
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        SEL s = NSSelectorFromString(@"registerInvalidationHandler:");
        if (!session || ![session respondsToSelector:s]) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(session, s, handler);
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}


NSString * _Nullable SawtXCTTypeText(NSString *text, NSInteger speed, double timeout) {
    if (text.length == 0) return @"النص فاضي";
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        if (!session) return why;
        Class recordCls = NSClassFromString(@"XCSynthesizedEventRecord");
        Class pathCls = NSClassFromString(@"XCPointerEventPath");
        SEL initText = NSSelectorFromString(@"initForTextInput");
        SEL typeSel = NSSelectorFromString(@"typeText:atOffset:typingSpeed:shouldRedact:");
        SEL initName = NSSelectorFromString(@"initWithName:");
        SEL addPath = NSSelectorFromString(@"addPointerEventPath:");
        if (!recordCls || !pathCls || ![pathCls instancesRespondToSelector:initText] ||
            ![pathCls instancesRespondToSelector:typeSel] || ![recordCls instancesRespondToSelector:initName])
            return @"دوال الكتابة (initForTextInput / typeText:atOffset:typingSpeed:shouldRedact:) مو موجودة";
        id path = ((id (*)(id, SEL))objc_msgSend)([pathCls alloc], initText);
        if (!path) return @"مسار الكتابة رجع فاضي";
        long long sp = MIN(240, MAX(1, speed));
        ((void (*)(id, SEL, id, double, long long, BOOL))objc_msgSend)(path, typeSel, text, 0.0, sp, YES);
        id record = ((id (*)(id, SEL, id))objc_msgSend)([recordCls alloc], initName, @"Sawt type");
        if (!record || ![record respondsToSelector:addPath]) return @"سجل الكتابة مو جاهز";
        ((void (*)(id, SEL, id))objc_msgSend)(record, addPath, path);

        SEL proxySel = NSSelectorFromString(@"daemonProxy");
        id proxy = [session respondsToSelector:proxySel] ? ((id (*)(id, SEL))objc_msgSend)(session, proxySel) : nil;
        if (!proxy) return @"daemonProxy مو موجود";
        __block NSString *reply = nil;
        __block BOOL done = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        void (^completion)(NSError *) = ^(NSError *e) {
            reply = e ? [NSString stringWithFormat:@"%@ %ld %@", e.domain, (long)e.code, e.localizedDescription] : nil;
            done = YES;
            dispatch_semaphore_signal(sem);
        };
        SEL s3 = NSSelectorFromString(@"_XCT_synthesizeEvent:implicitConfirmationInterval:completion:");
        SEL s2 = NSSelectorFromString(@"_XCT_synthesizeEvent:completion:");
        if (SawtHas(proxy, s3)) ((void (*)(id, SEL, id, double, id))objc_msgSend)(proxy, s3, record, 0.0, completion);
        else if (SawtHas(proxy, s2)) ((void (*)(id, SEL, id, id))objc_msgSend)(proxy, s2, record, completion);
        else return @"daemonProxy ما فيه _XCT_synthesizeEvent";
        // وقت الكتابة تقريبًا: الحروف ÷ السرعة (حرف بالثانية) + المهلة
        double total = timeout + (double)text.length / (double)sp;
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)));
        (void)[record class];
        if (waited != 0 && !done) return [NSString stringWithFormat:@"ما جا رد للكتابة خلال %.0f ثانية", total];
        return reply;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}


NSString * _Nullable SawtXCTOpenURL(NSURL *url) {
    @try {
        Class dev = NSClassFromString(@"XCUIDevice");
        SEL shared = NSSelectorFromString(@"sharedDevice");
        if (!dev || ![dev respondsToSelector:shared]) return @"XCUIDevice مو موجود";
        id device = ((id (*)(id, SEL))objc_msgSend)(dev, shared);
        SEL sysSel = NSSelectorFromString(@"system");
        if (![device respondsToSelector:sysSel]) return @"XCUIDevice.system مو مدعوم";
        id sys = ((id (*)(id, SEL))objc_msgSend)(device, sysSel);
        SEL open = NSSelectorFromString(@"openURL:error:");
        if (!sys || ![sys respondsToSelector:open]) return @"openURL:error: مو مدعوم";
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sys, open, url, &err);
        if (ok) return nil;
        return err ? [NSString stringWithFormat:@"%@ %ld %@", err.domain, (long)err.code, err.localizedDescription] : @"رجع NO";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}


NSString *SawtXCTCloseSession(void) {
    @try {
        NSString *why = nil;
        id session = SawtSharedSession(&why);
        if (!session) return [@"✗ " stringByAppendingString:why ?: @"ما فيه جلسة"];
        SEL connSel = NSSelectorFromString(@"connection");
        id link = [session respondsToSelector:connSel] ? ((id (*)(id, SEL))objc_msgSend)(session, connSel) : nil;
        SEL inv = NSSelectorFromString(@"invalidate");
        if (!link || ![link respondsToSelector:inv]) return @"✗ ما فيه اتصال نقدر نسكّره";
        ((void (*)(id, SEL))objc_msgSend)(link, inv);
        return [NSString stringWithFormat:@"تسكّر (%@ invalidate)", NSStringFromClass([link class])];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"✗ %@: %@", e.name, e.reason ?: @""];
    }
}
