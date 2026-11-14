import UIKit
import ObjectiveC

/// إصلاح منتقي الملفات في التطبيقات المثبّتة من برا المتجر (نفس فكرة أداة FilePickerFix، كتابة مستقلة):
/// الشهادات المجانية ما فيها صلاحيات فتح الملفات «في مكانها»، فيضغط المستخدم على الملف وما يصير شي.
/// الحل: نجبر كل منتقي (بما فيها fileImporter حق SwiftUI) يشتغل بوضع النسخ/الاستيراد،
/// فيوصلنا الملف منسوخ داخل صندوق التطبيق.
enum PickerFix {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIDocumentPickerViewController.self

        // initForOpeningContentTypes:asCopy: → asCopy دائمًا
        let s1 = NSSelectorFromString("initForOpeningContentTypes:asCopy:")
        if let m = class_getInstanceMethod(cls, s1) {
            typealias F = @convention(c) (AnyObject, Selector, NSArray, Bool) -> AnyObject?
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, NSArray, Bool) -> AnyObject? = { me, types, _ in
                orig(me, s1, types, true)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        // initWithDocumentTypes:inMode: → Open يصير Import
        let s2 = NSSelectorFromString("initWithDocumentTypes:inMode:")
        if let m = class_getInstanceMethod(cls, s2) {
            typealias F = @convention(c) (AnyObject, Selector, NSArray, UInt) -> AnyObject?
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, NSArray, UInt) -> AnyObject? = { me, types, mode in
                let open = UInt(UIDocumentPickerMode.open.rawValue)
                let imp = UInt(UIDocumentPickerMode.import.rawValue)
                return orig(me, s2, types, mode == open ? imp : mode)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        slog("picker fix installed")
    }
}
