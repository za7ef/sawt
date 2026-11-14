import Foundation

// اختبارات المنطق النصي الخالص. تُشغَّل في الـCI:
// swiftc Sawt/Core/*.swift Tests/main.swift -o /tmp/coretests && /tmp/coretests

var failures = 0
func check(_ ok: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if ok { print("✓ \(name)") } else { failures += 1; print("✗ \(name) (\(line))") }
}

// splitSentences
do {
    let (s, rest) = TextCleaner.splitSentences("مرحبا. كيف حالك؟ ", first: false)
    check(s == ["مرحبا.", "كيف حالك؟"], "splitSentences: يفصل عند النقطة وعلامة الاستفهام")
    check(rest.trimmingCharacters(in: .whitespaces).isEmpty, "splitSentences: ما يبقى شي")
    let (d, _) = TextCleaner.splitSentences("السعر 3.5 ريال.", first: false)
    check(d == ["السعر 3.5 ريال."], "splitSentences: ما يقطع الرقم العشري")
    let long = String(repeating: "كلمة ", count: 60)
    let (l, r) = TextCleaner.splitSentences(long, first: false)
    check(!l.isEmpty && l.allSatisfy { $0.count <= 151 }, "splitSentences: يقطع الطويل بدون ترقيم عند ≤150")
    check((l.joined(separator: " ") + " " + r).split(separator: " ").count == 60, "splitSentences: ما تضيع كلمات")
    let (f, _) = TextCleaner.splitSentences("واحد اثنين ثلاثة أربعة خمسة ستة سبعة ثمانية", first: true)
    check(f.count == 1, "splitSentences: أول جملة تبدأ بعد سبع كلمات")
}

// TurnHeuristics
check(TurnHeuristics.isFragment("و"), "TurnHeuristics: كلمة وحدة ناقصة")
check(!TurnHeuristics.isFragment("نعم"), "TurnHeuristics: نعم كاملة")
check(!TurnHeuristics.isFragment("كيف حالك؟"), "TurnHeuristics: سؤال كامل")
check(TurnHeuristics.soundsUnfinished("أبي أروح بس"), "TurnHeuristics: ينتهي بكلمة حشو")
check(!TurnHeuristics.soundsUnfinished("أبي أروح البيت"), "TurnHeuristics: جملة كاملة")

// SearchQuery
check(SearchQuery.make(from: "ابحث عن أسعار الذهب اليوم") == "أسعار الذهب اليوم", "SearchQuery: يشيل ابحث عن")
check(SearchQuery.make(from: "research on google ranking") == "research on google ranking", "SearchQuery: research ما تنقص")
let follow = SearchQuery.make(from: "وش رأيك فيه؟", previous: "ابحث عن آيفون 17")
check(follow.contains("آيفون 17") && follow.contains("رأيك"), "SearchQuery: سؤال المتابعة ياخذ السياق")
check(SearchQuery.make(from: "أسعار الذهب", previous: "الطقس") == "أسعار الذهب", "SearchQuery: سؤال مستقل ما يتدمج")
check(SearchQuery.make(from: String(repeating: "ا ", count: 200)).count <= 140, "SearchQuery: الحد 140")

// ForgetCues
check(ForgetCues.matches("انسَ إني أحب القهوة"), "ForgetCues: انسَ")
check(ForgetCues.matches("هذا غلط"), "ForgetCues: غلط")
check(ForgetCues.matches("وانساها خلاص"), "ForgetCues: و + انساها")
check(ForgetCues.matches("it's no longer true"), "ForgetCues: no longer")
check(!ForgetCues.matches("الانسان مخلوق عجيب"), "ForgetCues: الانسان مو إشارة")
check(!ForgetCues.matches("I love research"), "ForgetCues: كلام عادي")

// firstWords
check(TextCleaner.splitSentences("هلا والله كيفك اليوم ", first: true, firstWords: 3).0.first == "هلا والله كيفك", "splitSentences: أول قطعة 3 كلمات")
check(TextCleaner.splitSentences("هلا والله كيفك اليوم ", first: true).0.isEmpty, "splitSentences: الافتراضي 7")

// FillerPicker
check(FillerPicker.needsThought("كيف أسوي حساب جديد"), "Filler: كيف = تفكير")
check(!FillerPicker.needsThought("هلا والله"), "Filler: سوالف = عادي")
check(FillerPicker.needsThought("عندي 3 طلبات"), "Filler: أرقام = تفكير")
check(FillerPicker.casual.contains(FillerPicker.pick(for: "هلا", last: nil)!), "Filler: عادي من القائمة العادية")
for _ in 0 ..< 20 { check(FillerPicker.pick(for: "هلا", last: "طيب") != "طيب", "Filler: بدون تكرار") }
check(FillerPicker.pick(for: "اشرح لي", last: nil, available: ["دقيقة أفكر"]) == "دقيقة أفكر", "Filler: من الجاهز بس")
check(FillerPicker.pick(for: "اشرح لي", last: nil, available: []) == nil, "Filler: ما فيه جاهز")

// MemoryLine
let now0 = Date(timeIntervalSince1970: 1_800_000_000)
if case .add(let t, let imp, let cat, let exp)? = MemoryLine.parse("+ 4 | ناس | دائم | أخته اسمها سميرة", now: now0) {
    check(t == "أخته اسمها سميرة" && imp == 4 && cat == "ناس" && exp == nil, "MemoryLine: إضافة كاملة")
} else { check(false, "MemoryLine: إضافة كاملة") }
if case .add(_, let imp, _, let exp)? = MemoryLine.parse("+ ٢ | خطط | مؤقت | عنده موعد بكرة", now: now0) {
    check(imp == 2 && exp == now0.addingTimeInterval(14 * 86_400), "MemoryLine: مؤقت + أرقام عربية")
} else { check(false, "MemoryLine: مؤقت") }
if case .add(_, _, _, let exp)? = MemoryLine.parse("+ 3 | خطط | 2026-12-01 | مسافر جدة", now: now0) {
    check(exp != nil, "MemoryLine: تاريخ انتهاء")
} else { check(false, "MemoryLine: تاريخ") }
if case .add(let t, let imp, _, _)? = MemoryLine.parse("+ يحب القهوة بدون سكر") {
    check(t == "يحب القهوة بدون سكر" && imp == 3, "MemoryLine: الصيغة القديمة")
} else { check(false, "MemoryLine: القديمة") }
check(MemoryLine.parse("~ 3: صار يشتغل في الرياض") == .update(index: 3, text: "صار يشتغل في الرياض", importance: nil), "MemoryLine: تحديث")
check(MemoryLine.parse("~ 2 | 5 | اسم ولده أيان") == .update(index: 2, text: "اسم ولده أيان", importance: 5), "MemoryLine: تحديث بأهمية")
check(MemoryLine.parse("x ٤") == .delete(index: 4), "MemoryLine: حذف")
check(MemoryLine.parse("لا شيء") == nil, "MemoryLine: لا شيء")
check(MemoryLine.hasRememberCue("تذكر إني ما أحب البصل"), "MemoryLine: تذكر")

print(failures == 0 ? "كل الاختبارات نجحت" : "فشل \(failures)")
exit(failures == 0 ? 0 : 1)
