import Foundation

/// مصدر من البحث يظهر تحت الرد.
struct WebSource: Codable, Equatable, Hashable {
    var title: String
    var url: String
}

/// بحث ويب بدون مفتاح ولا حساب: DuckDuckGo (نسخة HTML الخفيفة) وويكيبيديا كبديل.
/// ما نرسل إلا نص البحث؛ بدون كوكيز ولا معرّفات (جلسة مؤقتة).
enum WebSearch {
    struct Page { var title: String; var url: String; var text: String }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "ar,en;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    /// يجهّز نص البحث من سؤال المستخدم (بدون نموذج، عشان السرعة).
    static func query(from text: String) -> String {
        var q = text.replacingOccurrences(of: "\n", with: " ")
        for w in ["ابحث عن", "ابحث", "دور لي", "دوّر", "search for", "search", "google", "قوقل"] {
            q = q.replacingOccurrences(of: w, with: " ", options: .caseInsensitive)
        }
        q = q.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return String(q.prefix(120))
    }

    static func isArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0600 ... 0x06FF).contains($0.value) }
    }

    /// يرجع أفضل الصفحات مع نصها. يرمي خطأ مفهوم إذا ما فيه إنترنت.
    static func search(_ q: String, maxPages: Int = 4) async throws -> [Page] {
        var links: [(String, String)] = []
        do { links = try await duck(q) } catch { slog("web: ddg failed \(error)") }
        if links.isEmpty {
            do { return try await wikipedia(q) } catch {
                throw SawtError.failed(offline(error) ? "ما فيه اتصال بالإنترنت، فما قدرت أبحث." : "ما قدرت أوصل لمحرك البحث الحين.")
            }
        }
        let top = Array(links.prefix(maxPages))
        let pages: [Page] = await withTaskGroup(of: (Int, Page?).self) { g in
            for (i, l) in top.enumerated() {
                g.addTask { (i, try? await fetch(title: l.0, url: l.1)) }
            }
            var out: [(Int, Page)] = []
            for await (i, p) in g { if let p, p.text.count > 200 { out.append((i, p)) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        if pages.isEmpty, let w = try? await wikipedia(q), !w.isEmpty { return w }
        return pages
    }

    static func offline(_ e: Error) -> Bool {
        let code = (e as? URLError)?.code
        return code == .notConnectedToInternet || code == .networkConnectionLost || code == .dataNotAllowed
    }

    // MARK: DuckDuckGo

    static func duck(_ q: String) async throws -> [(String, String)] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "q=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            + "&kl=" + (isArabic(q) ? "xa-ar" : "wt-wt")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        // <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=...">Title</a>
        let re = try NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
                                         options: [.dotMatchesLineSeparators])
        var out: [(String, String)] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let hr = Range(m.range(at: 1), in: html), let tr = Range(m.range(at: 2), in: html) else { continue }
            var href = decodeEntities(String(html[hr]))
            if let c = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let u = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = u
            }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js"),
                  let host = URL(string: href)?.host, !seen.contains(host) else { continue }
            seen.insert(host)
            out.append((plain(String(html[tr])), href))
            if out.count >= 6 { break }
        }
        return out
    }

    // MARK: Wikipedia

    static func wikipedia(_ q: String) async throws -> [Page] {
        let lang = isArabic(q) ? "ar" : "en"
        var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: q),
            .init(name: "gsrlimit", value: "3"), .init(name: "prop", value: "extracts|info"),
            .init(name: "inprop", value: "url"), .init(name: "explaintext", value: "1"),
            .init(name: "exlimit", value: "3"), .init(name: "exchars", value: "6000"),
        ]
        let (data, _) = try await session.data(from: c.url!)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (j["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        return pages.values.compactMap { v -> (Int, Page)? in
            guard let p = v as? [String: Any], let t = p["title"] as? String,
                  let ex = p["extract"] as? String, let u = p["fullurl"] as? String else { return nil }
            return ((p["index"] as? Int) ?? 0, Page(title: t, url: u, text: ex))
        }.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    // MARK: الصفحات

    static func fetch(title: String, url: String) async throws -> Page {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        let (bytes, resp) = try await session.bytes(from: u)
        if let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), !ct.contains("html"), !ct.contains("text") {
            throw URLError(.cannotDecodeContentData)
        }
        // نقرأ أول 1.5MB بس (ذاكرة)
        var data = Data()
        data.reserveCapacity(256_000)
        for try await b in bytes {
            data.append(b)
            if data.count > 1_500_000 { break }
        }
        let html = String(decoding: data, as: UTF8.self)
        return Page(title: title, url: url, text: readable(html))
    }

    /// نص مقروء من HTML: نشيل السكربتات والقوائم والوسوم.
    static func readable(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "aside"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = plain(s)
        let lines = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 40 }   // نشيل القوائم والأزرار القصيرة
        return String(lines.joined(separator: "\n").prefix(40_000))
    }

    static func plain(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(t)
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"),
                       ("&gt;", ">"), ("&nbsp;", " "), ("&#x2F;", "/")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// يبني سياق البحث للنموذج ضمن حد الحروف، ويرجع المصادر المستخدمة بالترتيب.
    static func context(_ pages: [Page], query: String, budget: Int = 5000) -> (String, [WebSource]) {
        guard !pages.isEmpty else { return ("", []) }
        let each = max(800, budget / pages.count)
        var parts: [String] = []
        var sources: [WebSource] = []
        for p in pages {
            let (ctx, _) = Attachments.context(for: p.text, query: query, budget: each)
            guard !ctx.isEmpty else { continue }
            sources.append(WebSource(title: p.title.isEmpty ? (URL(string: p.url)?.host ?? p.url) : p.title, url: p.url))
            parts.append("[\(sources.count)] \(p.title)\n\(ctx)")
        }
        return (parts.joined(separator: "\n\n"), sources)
    }
}
