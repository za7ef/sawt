import Foundation
import SwiftUI

/// يتابع تنزيل وتحميل النماذج.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Phase: Equatable {
        /// loading = ينزل (مع النسبة)، preparing = يجهّز النموذج في الذاكرة.
        case idle, loading(Double), preparing, ready, failed(String)
        var isReady: Bool { self == .ready }
        var isBusy: Bool { if case .loading = self { return true }; return self == .preparing }
        var progress: Double? { if case .loading(let p) = self { return p }; return nil }
    }

    @Published var llm: Phase = .idle
    @Published var stt: Phase = .idle
    @Published var voiceReady = false
    /// النماذج اللي نزلت كاملة.
    @Published var downloaded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "downloadedLLMs") ?? [])
    @Published var downloadedSTT: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "downloadedSTT") ?? [])
    /// النموذج اللي ينزل الحين.
    @Published var downloadingID: String?

    private var llmTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?
    private var llmToken = 0
    private var sttToken = 0

    var allReady: Bool { llm.isReady && stt.isReady }

    /// عند فتح التطبيق: نشغّل بس النماذج اللي نزلت قبل. ما ننزّل شي تلقائيًا.
    func loadAll() {
        if llm == .idle, downloaded.contains(AppSettings.shared.llmID) { activate(AppSettings.shared.llm) }
        if stt == .idle, downloadedSTT.contains(AppSettings.shared.sttID) { loadSTT() }
        prepareVoice()
    }

    func loadLLM() { activate(AppSettings.shared.llm) }

    private func markDownloaded(_ id: String) {
        guard !downloaded.contains(id) else { return }
        downloaded.insert(id)
        UserDefaults.standard.set(Array(downloaded), forKey: "downloadedLLMs")
    }

    /// ينزّل النموذج (إذا ما نزل) ويشغّله.
    func activate(_ option: LLMOption) {
        AppSettings.shared.llmID = option.id
        llmTask?.cancel()
        llmToken += 1
        let token = llmToken
        llm = downloaded.contains(option.id) ? .preparing : .loading(0)
        downloadingID = downloaded.contains(option.id) ? nil : option.id
        llmTask = Task {
            do {
                try await withTimeout(seconds: 1_800, what: "تنزيل النموذج") {
                    try await LLMService.shared.load(option) { p in
                        Task { @MainActor in
                            let mm = ModelManager.shared
                            guard mm.llmToken == token else { return }
                            if p >= 0.999 {
                                mm.markDownloaded(option.id)
                                mm.downloadingID = nil
                                mm.llm = .preparing
                            } else if mm.llm != .preparing {
                                mm.llm = .loading(p)
                            }
                        }
                    }
                }
                guard llmToken == token else { return }
                markDownloaded(option.id)
                downloadingID = nil
                llm = .ready
            } catch {
                guard llmToken == token else { return }
                downloadingID = nil
                llm = Task.isCancelled ? .idle : .failed(SawtError.friendly(error).localizedDescription)
            }
        }
    }

    /// يوقف التنزيل مؤقتًا. الملفات اللي نزلت تبقى، والباقي يكمل لما تضغط تنزيل مرة ثانية.
    func pauseDownload() {
        llmTask?.cancel()
        llmTask = nil
        llmToken += 1
        downloadingID = nil
        llm = .idle
    }

    /// يحذف ملفات النموذج من الجهاز.
    func delete(_ option: LLMOption) {
        if AppSettings.shared.llmID == option.id {
            llmTask?.cancel()
            llmToken += 1
            llm = .idle
            Task { await LLMService.shared.unload() }
        }
        ModelFiles.remove(repo: option.id)
        downloaded.remove(option.id)
        UserDefaults.standard.set(Array(downloaded), forKey: "downloadedLLMs")
    }

    func loadSTT() {
        let variant = AppSettings.shared.sttID
        sttTask?.cancel()
        sttToken += 1
        let token = sttToken
        stt = downloadedSTT.contains(variant) ? .preparing : .loading(0)
        sttTask = Task {
            do {
                try await withTimeout(seconds: 1_800, what: "نموذج السمع") {
                    try await SpeechRecognizer.shared.load(variant: variant) { p, preparing in
                        Task { @MainActor in
                            let mm = ModelManager.shared
                            guard mm.sttToken == token else { return }
                            if preparing {
                                if !mm.downloadedSTT.contains(variant) {
                                    mm.downloadedSTT.insert(variant)
                                    UserDefaults.standard.set(Array(mm.downloadedSTT), forKey: "downloadedSTT")
                                }
                                mm.stt = .preparing
                            } else if mm.stt != .preparing {
                                mm.stt = .loading(p)
                            }
                        }
                    }
                }
                guard sttToken == token else { return }
                stt = .ready
            } catch {
                guard sttToken == token else { return }
                stt = .failed(SawtError.friendly(error).localizedDescription)
            }
        }
    }

    func prepareVoice() {
        voiceReady = false
        let v = AppSettings.shared.voice
        Task.detached(priority: .userInitiated) {
            SpeechSynth.shared.prepare(v)
            await MainActor.run { ModelManager.shared.voiceReady = true }
        }
    }
}

/// يدوّر على ملفات نموذج Hugging Face في مجلدات التطبيق.
enum ModelFiles {
    static var roots: [URL] {
        let fm = FileManager.default
        var r: [URL] = []
        for d in [FileManager.SearchPathDirectory.cachesDirectory, .documentDirectory, .applicationSupportDirectory] {
            r += fm.urls(for: d, in: .userDomainMask)
        }
        r.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache"))
        return r
    }

    static func matches(repo: String) -> [URL] {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        let hubName = "models--\(parts[0])--\(parts[1])"
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if en.level > 6 { en.skipDescendants(); continue }
                let name = url.lastPathComponent
                if name == hubName || (name == parts[1] && url.deletingLastPathComponent().lastPathComponent == parts[0]) {
                    found.append(url)
                    en.skipDescendants()
                }
            }
        }
        return found
    }

    static func remove(repo: String) {
        for u in matches(repo: repo) { try? FileManager.default.removeItem(at: u) }
    }
}

/// يوقف العملية إذا طوّلت أكثر من اللازم.
func withTimeout<T: Sendable>(seconds: Double, what: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SawtError.timeout(what)
        }
        guard let first = try await group.next() else { throw SawtError.timeout(what) }
        group.cancelAll()
        return first
    }
}
