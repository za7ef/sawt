import Foundation

/// حساب وحذف الملفات المخزنة.
enum Storage {
    static let fm = FileManager.default
    /// فيه تنزيل شغال (نموذج أو صوت نماء): لا نلمس الملفات المؤقتة
    nonisolated(unsafe) static var downloadActive = false
    /// تنزيلات ثانية (أصوات، ملفات llama) — مسح الكاش ما يلمس المؤقت وهي شغالة
    nonisolated(unsafe) static var otherDownloads = 0
    static var anyDownload: Bool { downloadActive || otherDownloads > 0 }

    /// ملفات النماذج تنزل من جديد، فما لها داعي تدخل نسخة iCloud الاحتياطية.
    static func excludeModelsFromBackup() {
        var dirs: [URL] = []
        for d in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            guard let base = fm.urls(for: d, in: .userDomainMask).first else { continue }
            for name in ["huggingface", "models", "Namaa"] {
                dirs.append(base.appendingPathComponent(name))
            }
        }
        for var u in dirs where fm.fileExists(atPath: u.path) {
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
    }
    static var caches: URL { fm.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// مكان نماذج MLX (مكتبة Hugging Face).
    static var hubDir: URL { caches.appendingPathComponent("huggingface/hub") }

    static func size(_ url: URL) -> Int64 {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// المساحة الفاضية المتاحة (بالبايت).
    static var freeBytes: Int64 {
        let v = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// يكفي المكان لتنزيل بهالحجم + هامش 1GB للنظام؟ يرجع رسالة إذا ما يكفي.
    static func spaceProblem(forGB gb: Double) -> String? {
        let need = Int64((gb + 1.0) * 1_073_741_824)
        let free = freeBytes
        guard free < need else { return nil }
        return String(format: "المساحة ما تكفي: يحتاج تقريبًا %.1f GB وفاضي %.1f GB. فضّي مساحة وجرّب.",
                      gb + 1.0, Double(free) / 1_073_741_824)
    }

    static func llmDir(_ repo: String) -> URL {
        hubDir.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }

    /// مجلد نموذج نازل كامل على الجهاز (عشان نحمّله بدون أي اتصال بالإنترنت).
    /// نتأكد إن config.json موجود وكل ملفات الأوزان المذكورة في الفهرس موجودة.
    static func llmLocalSnapshot(_ repo: String) -> URL? {
        let snaps = llmDir(repo).appendingPathComponent("snapshots")
        guard let dirs = try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            guard fm.fileExists(atPath: d.appendingPathComponent("config.json").path) else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            guard files.contains(where: { $0.hasSuffix(".safetensors") }),
                  files.contains(where: { $0.hasPrefix("tokenizer") }) else { continue }
            let index = d.appendingPathComponent("model.safetensors.index.json")
            if let data = try? Data(contentsOf: index),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let map = j["weight_map"] as? [String: String] {
                guard Set(map.values).allSatisfy({ fm.fileExists(atPath: d.appendingPathComponent($0).path) }) else { continue }
            }
            return d
        }
        return nil
    }

    struct Usage {
        var models: Int64 = 0
        var cache: Int64 = 0
    }

    static func usage() -> Usage {
        var u = Usage()
        u.models = size(hubDir)
        let tmp = size(fm.temporaryDirectory)
        let otherCaches = ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "huggingface" }
            .reduce(Int64(0)) { $0 + size($1) }
        u.cache = tmp + otherCaches + partialSize()
        return u
    }

    /// ملفات تنزيل ناقصة داخل مجلد النماذج.
    private static func partials() -> [URL] {
        var out: [URL] = []
        for root in [hubDir] {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en {
                let n = f.lastPathComponent
                if n.hasSuffix(".incomplete") || n.hasSuffix(".lock") || n == ".locks" || n.hasSuffix(".part") {
                    out.append(f)
                }
            }
        }
        return out
    }

    private static func partialSize() -> Int64 { partials().reduce(0) { $0 + size($1) + fileSize($1) } }

    private static func fileSize(_ f: URL) -> Int64 {
        Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }

    /// يحذف الكاش: الملفات المؤقتة، كاش الشبكة، والتنزيلات الناقصة. ما يلمس النماذج الكاملة.
    static func clearCache() {
        let busy = anyDownload
        for f in (busy ? [] : (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []) {
            try? fm.removeItem(at: f)
        }
        for f in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent != "huggingface" {
            try? fm.removeItem(at: f)
        }
        // التنزيلات الناقصة نحذفها بس إذا ما فيه تنزيل شغال الحين
        if !busy { for f in partials() { try? fm.removeItem(at: f) } }
        URLCache.shared.removeAllCachedResponses()
        slog("cache cleared")
    }

    static func deleteLLM(_ repo: String) {
        try? fm.removeItem(at: llmDir(repo))
        ModelFiles.remove(repo: repo)
        slog("deleted llm \(repo)")
    }

    static func deleteAllModels() {
        try? fm.removeItem(at: hubDir)
        try? fm.removeItem(at: documents.appendingPathComponent("huggingface"))
        clearCache()
        slog("deleted all models")
    }

    struct ModelFolder: Identifiable, Sendable {
        enum Kind: Sendable { case llm(String) }
        var id: String { url.path }
        let url: URL
        let name: String
        let kind: Kind
        let bytes: Int64
        let incomplete: Bool
        let known: Bool
        var isOrphan: Bool { incomplete || !known }
        var statusText: String {
            if incomplete { return "تنزيل ناقص" }
            if !known { return "ملفات قديمة غير مستخدمة" }
            return "نموذج لغوي"
        }
    }

    /// كل مجلدات النماذج الموجودة فعليًا.
    static func modelFolders(downloaded: Set<String>) -> [ModelFolder] {
        var out: [ModelFolder] = []
        for d in (try? fm.contentsOfDirectory(at: hubDir, includingPropertiesForKeys: nil)) ?? []
        where d.lastPathComponent.hasPrefix("models--") {
            let parts = d.lastPathComponent.dropFirst("models--".count).components(separatedBy: "--")
            let repo = parts.count >= 2 ? parts[0] + "/" + parts.dropFirst().joined(separator: "--") : d.lastPathComponent
            out.append(ModelFolder(url: d, name: repo, kind: .llm(repo), bytes: size(d),
                                   incomplete: hasPartial(d), known: downloaded.contains(repo)))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func hasPartial(_ dir: URL) -> Bool {
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let f as URL in en where f.lastPathComponent.hasSuffix(".incomplete") || f.lastPathComponent.hasSuffix(".part") {
            return true
        }
        return false
    }

    private static let dismissedKey = "storage.dismissedOrphans"

    /// المجلدات اللي قال عنها "خلها": ما نسأل عنها مرة ثانية.
    static func dismissOrphans(_ list: [ModelFolder]) {
        var s = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        for f in list { s.insert(f.url.lastPathComponent) }
        UserDefaults.standard.set(Array(s), forKey: dismissedKey)
    }

    static func isDismissed(_ f: ModelFolder) -> Bool {
        (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).contains(f.url.lastPathComponent)
    }

    static func remove(_ folder: ModelFolder) {
        try? fm.removeItem(at: folder.url)
        slog("deleted folder \(folder.name)")
    }

    static func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
