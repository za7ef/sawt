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
    static func splitSentences(_ buffer: String, first: Bool, firstWords: Int = 7) -> ([String], String) {
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
            } else if soft.contains(ch), words >= ((first && out.isEmpty) ? min(3, firstWords) : 8) {
                // أول جملة نقطعها بدري عشان يبدأ يتكلم بسرعة
                out.append(current); current = ""
            } else if ch == " ", first, out.isEmpty, words >= firstWords {
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

/// سطر من مخرجات استخراج الذاكرة.
/// الصيغة: `+ أهمية | فئة | مدة | النص` حيث المدة: دائم، أو مؤقت، أو تاريخ YYYY-MM-DD (ينتهي بعده).
/// تحديث: `~ رقم | أهمية | النص` أو `~ رقم: النص`. حذف: `x رقم`.
enum MemoryLine: Equatable {
    case add(text: String, importance: Int, category: String, expires: Date?)
    case update(index: Int, text: String, importance: Int?)
    case delete(index: Int)

    static let categories = ["هوية", "تفضيلات", "ناس", "خطط", "صحة", "شغل", "أخرى"]

    static func parse(_ raw: String, now: Date = Date()) -> MemoryLine? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let first = line.first else { return nil }
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        if body.contains("لا شيء") { return nil }
        switch first {
        case "+", "-", "•":
            let parts = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            var importance = 3, category = "أخرى", expires: Date? = nil, text = body
            if parts.count >= 4 {
                importance = Int(parts[0].filter(\.isNumber).prefix(1)) ?? Int(arabicDigits(parts[0]).prefix(1)) ?? 3
                category = categories.first { parts[1].contains($0) } ?? "أخرى"
                expires = expiry(parts[2], now: now)
                text = parts[3...].joined(separator: " ")
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard text.count >= 4, text.count <= 140 else { return nil }
            return .add(text: text, importance: min(max(importance, 1), 5), category: category, expires: expires)
        case "~":
            if body.contains("|") {
                let p = body.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard p.count >= 3, let n = Int(arabicDigits(p[0])) else { return nil }
                let t = p[2...].joined(separator: " ")
                guard t.count >= 4, t.count <= 140 else { return nil }
                return .update(index: n, text: t, importance: Int(arabicDigits(p[1]).prefix(1)).map { min(max($0, 1), 5) })
            }
            let p = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count == 2, let n = Int(arabicDigits(p[0])), p[1].count >= 4, p[1].count <= 140 else { return nil }
            return .update(index: n, text: p[1], importance: nil)
        case "x", "X", "×":
            guard let n = Int(arabicDigits(body).filter(\.isNumber)) else { return nil }
            return .delete(index: n)
        default:
            return nil
        }
    }

    static func arabicDigits(_ s: String) -> String {
        String(s.map { c -> Character in
            if let v = c.unicodeScalars.first?.value, (0x0660...0x0669).contains(v) {
                return Character(String(v - 0x0660))
            }
            return c
        })
    }

    /// المدة: "دائم" = nil، "مؤقت" = بعد 14 يوم، أو تاريخ = نهاية ذاك اليوم.
    static func expiry(_ s: String, now: Date) -> Date? {
        let t = arabicDigits(s)
        if let r = t.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(t[r])) { return d.addingTimeInterval(86_400) }
        }
        if t.contains("مؤقت") { return now.addingTimeInterval(14 * 86_400) }
        return nil
    }

    /// المستخدم طلب صراحة يتذكر شي.
    static func hasRememberCue(_ s: String) -> Bool {
        let t = s.lowercased()
        return ["تذكر", "تذكّر", "احفظ", "لا تنسى", "لا تنس", "remember"].contains { t.contains($0) }
    }
}

/// كلمة انتظار قصيرة تنقال لو الرد تأخر، حسب نوع السؤال (بدون نداء إضافي للنموذج).
enum FillerPicker {
    static let casual = ["طيب", "ممم", "اها"]
    static let think = ["دقيقة أفكر", "خلني أشوف", "دقيقة أشيك"]
    /// ترتيب التجهيز: وحدة من كل نوع أول، بعدين الباقي
    static let renderOrder = ["طيب", "دقيقة أفكر", "ممم", "خلني أشوف", "اها", "دقيقة أشيك"]

    static let thinkCues = ["كيف", "ليش", "ليه", "لماذا", "اشرح", "وضح", "وضّح", "فسر", "فسّر", "احسب",
                            "كم ", "ابحث", "دور", "قارن", "الفرق", "وش رأيك", "ايش رأيك", "why", "how", "explain",
                            "calculate", "compare", "search"]

    static func needsThought(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        if text.split(separator: " ").count >= 12 { return true }
        if text.contains(where: { $0.isNumber }) { return true }
        return thinkCues.contains { t.contains($0) }
    }

    /// يختار من القائمة المناسبة، بدون تكرار آخر واحدة، ومن الجاهز بس إذا انعطت قائمة الجاهز
    static func pick(for text: String, last: String?, available: Set<String>? = nil, random: (Int) -> Int = { Int.random(in: 0 ..< max($0, 1)) }) -> String? {
        var pool = needsThought(text) ? think : casual
        if let available { pool = pool.filter { available.contains($0) } }
        if pool.count > 1, let last { pool.removeAll { $0 == last } }
        guard !pool.isEmpty else { return nil }
        return pool[random(pool.count)]
    }
}

/// وضع التفكير التلقائي: يقرر لكل رسالة إذا تستاهل تفكير عميق (بدون نداء إضافي للنموذج).
enum ThinkHeuristic {
    static let cues = ["ليش", "ليه", "لماذا", "كيف أ", "كيف ا", "كيف ن", "اشرح", "وضح", "وضّح", "فسر", "فسّر", "قارن", "الفرق بين",
                       "خطة", "خطط", "خطوات", "رتب لي", "حلل", "حلّل", "احسب", "برهن", "اثبت", "أثبت", "صحح", "صحّح",
                       "لغز", "فزورة", "فوازير", "حزورة", "احجية", "أحجية", "ما هو الشيء", "ما هو الشي", "وش الشي", "ايش الشي",
                       "شيء إذا", "شيء اذا", "شي اذا", "شي إذا", "خمن", "خمّن", "منطق", "استنتج",
                       "why", "explain", "compare", "plan", "step by step", "prove", "calculate", "debug", "analy",
                       "riddle", "puzzle", "guess", "logic"]
    static let smallTalk = ["كيفك", "كيف حالك", "شلونك", "وش اخبارك", "وش أخبارك", "ايش اخبارك", "وش تسوي", "وينك",
                            "how are you", "what's up", "whats up"]

    enum Verdict { case yes, no, unsure }

    /// نعم/لا واضحة من القواعد، و"مو متأكد" لسؤال عادي (ينتهي بعلامة استفهام) يقرره مصنّف سريع
    static func verdict(_ text: String, hasAttachment: Bool = false) -> Verdict {
        if shouldThink(text, hasAttachment: hasAttachment) { return .yes }
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = t.split(separator: " ").count
        if words <= 3 || smallTalk.contains(where: { t.contains($0) }) { return .no }
        if t.hasSuffix("?") || t.hasSuffix("؟") || words >= 12 { return .unsure }
        return .no
    }
    static let codeMarks = ["```", "func ", "def ", "class ", "error:", "exception", "{", "};", "import ", "console.", "print("]

    static func shouldThink(_ text: String, hasAttachment: Bool = false) -> Bool {
        let t = text.lowercased()
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if words <= 3 { return false }   // تحيات وردود قصيرة
        // رياضيات: رقمين أو أكثر مع عملية
        let digits = text.filter { $0.isNumber }.count
        if digits >= 2, text.contains(where: { "+-×÷*/=^%".contains($0) }) { return true }
        if codeMarks.contains(where: { t.contains($0) }) { return true }
        if cues.contains(where: { t.contains($0) }) { return true }
        if words >= 30 { return true }
        if hasAttachment, words >= 6, t.contains("?") || t.contains("؟") { return true }
        return false
    }
}
