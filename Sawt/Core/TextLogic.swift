import Foundation

// منطق نصي خالص (بدون واجهة ولا نماذج) — يُختبر في الـCI بـ Tests/CoreTests.swift.

enum TextCleaner {
    static func hasArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value) }
    }

    /// يشيل التنسيق والرموز اللي ما تنقال.
    static func forSpeech(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#`>|~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        t = String(t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)) })
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// يفصل النص المتدفق لجمل جاهزة للنطق. يرجع (جمل كاملة، الباقي).
    static func splitSentences(_ buffer: String, first: Bool) -> ([String], String) {
        var out: [String] = []
        var current = ""
        let enders: Set<Character> = [".", "!", "?", "؟", "؛", "\n", "…"]
        let soft: Set<Character> = ["،", ",", ":"]
        let chars = Array(buffer)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let words = current.split(separator: " ").count
            // نقطة عشرية (3.5): لا نقطع، ولو آخر حرف وصلنا ننتظر الباقي
            if ch == ".", i > 0, chars[i - 1].isNumber {
                if i + 1 >= chars.count || chars[i + 1].isNumber { continue }
            }
            if enders.contains(ch), current.trimmingCharacters(in: .whitespaces).count > 1 {
                out.append(current); current = ""
            } else if soft.contains(ch), words >= ((first && out.isEmpty) ? 3 : 8) {
                // أول جملة نقطعها بدري عشان يبدأ يتكلم بسرعة
                out.append(current); current = ""
            } else if ch == " ", first, out.isEmpty, words >= 7 {
                // ما فيه علامة ترقيم بعد: نبدأ الكلام بأول سبع كلمات بدل ما نستنى
                out.append(current); current = ""
            } else if ch == " ", current.count >= 150 {
                // جملة طويلة بدون ترقيم: نقطعها عند مسافة عشان الصوت يبدأ بدري (ونماء ما يخرب مع الطويل)
                out.append(current); current = ""
            }
        }
        return (out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, current)
    }
}

enum TurnHeuristics {
    /// كلمات لو انتهى فيها الكلام غالبًا المتكلم ما خلص.
    static let fillers: [String] = [
        "و", "بس", "يعني", "لأن", "لان", "عشان", "اللي", "ثم", "او", "أو", "اذا", "إذا", "لكن",
        "اممم", "امم", "ام", "طيب", "في", "على", "من", "مع", "عن",
        "and", "but", "so", "because", "the", "a", "to", "of", "or", "um", "uh", "like", "with",
    ]

    /// ردود قصيرة كاملة بحد ذاتها
    static let shortComplete: Set<String> = [
        "نعم", "لا", "اي", "إي", "ايه", "إيه", "ايوه", "أيوه", "تمام", "طيب", "اوكي", "شكرا", "شكرًا", "مرحبا", "هلا",
        "السلام", "كمل", "وقف", "خلاص", "صح", "يب", "لا لا", "مشكور",
        "yes", "no", "ok", "okay", "thanks", "hi", "hello", "stop", "continue", "yeah", "yep", "nope",
    ]

    /// كلام ناقص: نستنى بدل ما نرد عليه.
    static func isFragment(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)).lowercased()
        if t.isEmpty { return false }
        if let last = text.trimmingCharacters(in: .whitespaces).last, "؟?".contains(last) { return false }
        if shortComplete.contains(t) { return false }
        let words = t.split(separator: " ")
        if words.count <= 1 { return true }
        return soundsUnfinished(text)
    }

    static func soundsUnfinished(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard let last = t.split(separator: " ").last?.lowercased() else { return false }
        if text.hasSuffix("...") || text.hasSuffix("…") { return true }
        return fillers.contains(String(last))
    }
}

/// نص البحث في الويب.
enum SearchQuery {
    /// يجهّز نص البحث من سؤال المستخدم (بدون نموذج، عشان السرعة).
    /// الكلمات مثل "ابحث" و"search" تنشال ككلمات كاملة بس (research تبقى).
    /// سؤال متابعة قصير يتدمج مع السؤال اللي قبله.
    static func make(from text: String, previous: String? = nil) -> String {
        var words = text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").map(String.init)
        let drop: Set<String> = ["ابحث", "ابحثلي", "دور", "دوّر", "دورلي", "search", "google", "قوقل", "جوجل", "لي", "عن", "for"]
        // نشيل كلمات الأمر من البداية بس
        while let f = words.first, drop.contains(f.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        var q = words.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if let prev = previous, isFollowUp(q) {
            let p = make(from: prev)
            if !p.isEmpty, p != q { q = p + " " + q }
        }
        return String(q.prefix(140))
    }

    /// متابعة؟ قصير وفيه ضمير يرجع لشي قبله.
    static func isFollowUp(_ q: String) -> Bool {
        let words = q.split(separator: " ")
        guard words.count <= 5 else { return false }
        let refs = ["فيه", "عنه", "عنها", "منه", "منها", "هذا", "هذي", "ذا", "هو", "هي", "it", "this", "that", "they", "them", "he", "she"]
        return words.contains { w in
            let l = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return refs.contains(l) || l.hasSuffix("ه") && l.count <= 5
        }
    }

}

/// إشارات "انسَ/غلط" اللي تسمح بحذف معلومة من الذاكرة تلقائيًا.
enum ForgetCues {
    /// كلمات كاملة (مو جزء من كلمة: "الانسان" ما تحسب)، وتقبل و/ف قبلها.
    static let forgetWords: Set<String> = [
        "انس", "انسى", "انسَ", "انسي", "انساه", "انساها", "انسه", "انسها", "انسيها",
        "امسح", "امسحه", "امسحها", "احذف", "احذفه", "احذفها", "غلط", "خطأ", "خطا",
        "forget", "wrong", "incorrect", "delete", "remove",
    ]
    static let forgetPhrases = ["مو صحيح", "مب صحيح", "مش صحيح", "غير صحيح", "مو صح", "مب صح", "لا تتذكر",
                                "لا تحفظ", "ما عاد", "ماعاد", "not true", "no longer", "don't remember"]

    static func matches(_ s: String) -> Bool {
        let l = " " + s.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'\u{064E}")).inverted).joined(separator: " ") + " "
        let words = l.split(separator: " ").map(String.init)
        for w in words {
            if forgetWords.contains(w) { return true }
            if let f = w.first, "وف".contains(f), forgetWords.contains(String(w.dropFirst())) { return true }
        }
        let spaced = words.joined(separator: " ")
        let padded = " " + spaced + " "
        return forgetPhrases.contains { padded.contains(" " + $0) }
    }
}
