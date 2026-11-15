#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ينفّذ الكتلة داخل @try/@catch. يرجع nil لو ما صار استثناء،
/// وإلا يرجع "الاسم: السبب" بدل ما يطيح التطبيق (Swift ما يقدر يمسك NSException).
FOUNDATION_EXPORT NSString * _Nullable SawtTryCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
