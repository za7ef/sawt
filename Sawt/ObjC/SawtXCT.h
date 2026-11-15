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

/// وش مصدر عميل الوصول اللي انلقى (للسجل)
FOUNDATION_EXPORT NSString *SawtXCTAXSource(void);

/// معرّف الحزمة لرقم عملية عبر daemonProxy (_XCT_requestBundleIDForPID:reply:). nil لو ما عرف
FOUNDATION_EXPORT NSString * _Nullable SawtXCTBundleForPID(int pid, double timeout);

/// التطبيقات النشطة من عميل الوصول حق XCTest: مصفوفة قواميس {pid, bundle (لو معروف)}.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *SawtXCTActiveApps(void);

/// يحمّل الوصول (loadAccessibility:) في عميل XCTest، بحد زمني. لازم مرة لكل جلسة عشان تطبيقات الطرف الثالث.
FOUNDATION_EXPORT NSString * _Nullable SawtXCTLoadAccessibility(double timeout);

/// يقرأ شجرة عناصر التطبيق برقم العملية مباشرة من عميل الوصول (requestSnapshotForElement:attributes:parameters:error:)
/// بخصائص قليلة وحدود للعمق وعدد الأولاد، على خيط مستقل بحد زمني. لو ما رد، العملية تنعلّم "معلّقة"
/// وما ننسألها لمدة قصيرة. maxDepth/maxChildren = 0 يعني بدون حد. يرجع جذر اللقطة أو nil مع السبب.
FOUNDATION_EXPORT NSObject * _Nullable SawtXCTAXRead(int pid, NSInteger maxDepth, NSInteger maxChildren, double timeout, NSString * _Nullable * _Nullable why);

/// يسجّل معالج انقطاع على جلسة XCTest المشتركة. يرجع NO لو الجلسة ما تدعمه.
FOUNDATION_EXPORT BOOL SawtXCTWatchSession(void (^handler)(void));

NS_ASSUME_NONNULL_END
