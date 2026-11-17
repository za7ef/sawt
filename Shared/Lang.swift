import Foundation
import SwiftUI

/// لغة الواجهة: تتبع لغة الجهاز افتراضيًا، ويمكن تغييرها من الإعدادات (تُطبَّق بعد إعادة فتح التطبيق).
/// النصوص المصدرية بالعربية، والترجمة الإنجليزية في en.lproj/Localizable.strings.
enum AppLang {
    static let key = "appLanguage"   // system | ar | en

    /// اللغة المحفوظة في الإعدادات
    static var choice: String { UserDefaults.standard.string(forKey: key) ?? "system" }

    /// اللغة الفعلية للواجهة الآن (ar أو en)
    static var current: String {
        let l = Bundle.main.preferredLocalizations.first ?? "ar"
        return l.hasPrefix("en") ? "en" : "ar"
    }
    static var isArabic: Bool { current == "ar" }
    static var layout: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }
    static var locale: Locale { Locale(identifier: current) }

    /// يحفظ الاختيار ويضبط لغة التطبيق لدى النظام (تُطبَّق عند التشغيل التالي)
    static func set(_ v: String) {
        let d = UserDefaults.standard
        d.set(v, forKey: key)
        if v == "system" { d.removeObject(forKey: "AppleLanguages") } else { d.set([v], forKey: "AppleLanguages") }
    }
}

/// نص واجهة مترجم (المفتاح هو النص العربي نفسه)
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// نص مترجم بمتغيرات: كل متغير %@ ويُمرَّر نصًا
func L(_ key: String, _ args: String...) -> String {
    String(format: L(key), arguments: args.map { $0 as CVarArg })
}
