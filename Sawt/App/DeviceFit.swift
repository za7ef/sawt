import Foundation

/// أي آيفونات تشغّل النموذج براحة، حسب ذاكرة الجهاز.
/// الذاكرة: 4GB = آيفون 12 و12 ميني و13 و13 ميني • 6GB = 12 Pro و13 Pro و14 و14 Plus و14 Pro و15 و15 Plus
/// 8GB = 15 Pro وكل سلسلة 16 (ومنها 16e) و17 • 12GB = 17 Pro و17 Pro Max و17 Air.
enum DeviceFit {
    struct Tier { let ramGB: Int; let budgetGB: Double; let label: String }

    /// الميزانية = اللي يقدر التطبيق يستخدمه فعليًا قبل ما يقفله النظام (تقريبي ومتحفظ).
    static let tiers: [Tier] = [
        Tier(ramGB: 4, budgetGB: 2.0, label: "آيفون 12 وأحدث"),
        Tier(ramGB: 6, budgetGB: 3.2, label: "آيفون 13 Pro و14 وأحدث"),
        Tier(ramGB: 8, budgetGB: 4.6, label: "آيفون 15 Pro و16 وأحدث"),
        Tier(ramGB: 12, budgetGB: 7.5, label: "آيفون 17 Pro وأحدث"),
    ]

    /// المكالمة تحتاج زيادة للصوت والمايك.
    static let callExtraGB = 0.5

    static func minTier(needGB: Double) -> Tier? { tiers.first { $0.budgetGB >= needGB } }

    static func textNeed(_ m: LLMOption) -> Double { m.ramGB }
    static func callNeed(_ m: LLMOption) -> Double { m.ramGB + callExtraGB }

    /// ذاكرة هالجوال مقرّبة لأقرب فئة.
    static let deviceTier: Tier = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return tiers.last { Double($0.ramGB) - 1.0 <= gb } ?? tiers[0]
    }()

    static var modelIdentifier: String {
        var s = utsname()
        uname(&s)
        return withUnsafeBytes(of: &s.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    enum Fit { case both, textOnly, none, unknown }

    static func fitHere(_ m: LLMOption) -> Fit {
        guard m.ramGB > 0 else { return .unknown }
        if deviceTier.budgetGB >= callNeed(m) { return .both }
        if deviceTier.budgetGB >= textNeed(m) { return .textOnly }
        return .none
    }
}
