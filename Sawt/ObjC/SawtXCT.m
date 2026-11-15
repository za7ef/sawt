#import "SawtXCT.h"
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
