#import "SawtTryCatch.h"

NSString * _Nullable SawtTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *reason = e.reason ?: @"بدون سبب";
        return [NSString stringWithFormat:@"%@: %@", e.name, reason];
    } @catch (id other) {
        return [NSString stringWithFormat:@"استثناء غير معروف: %@", other];
    }
}
