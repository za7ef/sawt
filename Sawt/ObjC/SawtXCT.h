#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// يفعّل وضع الأتمتة في جلسة XCTest المشتركة (XCTRunnerDaemonSession) عن طريق
/// enableAutomationModeWithError: فقط. ممكن يطلب iOS رمز الجوال، فالنداء يوقف لين يرد.
/// ينادى من خيط خلفي. يرجع nil لو نجح، وإلا سبب الفشل.
FOUNDATION_EXPORT NSString * _Nullable SawtXCTEnableAutomation(void);

/// يرسل لمسة أو سحبة مركّبة (XCSynthesizedEventRecord + XCPointerEventPath) إلى testmanagerd
/// عبر daemonProxy مباشرة، بدون XCUIApplication وبدون انتظار هدوء التطبيق.
/// points: نقطة وحدة = لمسة، أكثر = سحب يمر عليها بالترتيب. duration بالثواني.
/// ينادى من خيط خلفي (ينتظر الرد بحد timeout). يرجع nil لو انقبل الحدث، وإلا السبب.
FOUNDATION_EXPORT NSString * _Nullable SawtXCTSynthesize(NSArray<NSValue *> *points, double duration, double timeout);

NS_ASSUME_NONNULL_END
