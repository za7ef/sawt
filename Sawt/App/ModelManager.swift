import Foundation
import SwiftUI

/// يتابع تنزيل وتحميل النماذج.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Phase: Equatable {
        case idle, loading(Double), ready, failed(String)
        var isReady: Bool { self == .ready }
        var progress: Double? { if case .loading(let p) = self { return p }; return nil }
    }

    @Published var llm: Phase = .idle
    @Published var stt: Phase = .idle
    @Published var voiceReady = false
    /// النماذج اللي نزلت كاملة.
    @Published var downloaded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "downloadedLLMs") ?? [])
    /// النموذج اللي ينزل الحين.
    @Published var downloadingID: String?

    private var llmTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?

    var allReady: Bool { llm.isReady && stt.isReady }

    func loadAll() {
        loadLLM()
        loadSTT()
        prepareVoice()
    }

    func loadLLM() { activate(AppSettings.shared.llm) }

    /// ينزّل النموذج (إذا ما نزل) ويشغّله.
    func activate(_ option: LLMOption) {
        AppSettings.shared.llmID = option.id
        llmTask?.cancel()
        llm = .loading(0)
        downloadingID = option.id
        llmTask = Task {
            defer { if downloadingID == option.id { downloadingID = nil } }
            do {
                try await LLMService.shared.load(option) { p in
                    Task { @MainActor in
                        if case .loading = ModelManager.shared.llm { ModelManager.shared.llm = .loading(p) }
                    }
                }
                if Task.isCancelled { return }
                llm = .ready
                downloaded.insert(option.id)
                UserDefaults.standard.set(Array(downloaded), forKey: "downloadedLLMs")
            } catch {
                llm = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    /// يوقف التنزيل مؤقتًا. الملفات اللي نزلت تبقى، والباقي يكمل لما تضغط تنزيل مرة ثانية.
    func pauseDownload() {
        llmTask?.cancel()
        llmTask = nil
        downloadingID = nil
        llm = .idle
    }

    /// يحذف ملفات النموذج من الجهاز.
    func delete(_ option: LLMOption) {
        if AppSettings.shared.llmID == option.id {
            llmTask?.cancel()
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
        stt = .loading(0)
        sttTask = Task {
            do {
                try await SpeechRecognizer.shared.load(variant: variant) { p in
                    Task { @MainActor in
                        if case .loading = ModelManager.shared.stt { ModelManager.shared.stt = .loading(p) }
                    }
                }
                stt = .ready
            } catch {
                stt = .failed(error.localizedDescription)
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
