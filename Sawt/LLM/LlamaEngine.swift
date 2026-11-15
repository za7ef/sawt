import Foundation
import MLXLMCommon
#if LLAMA
import llama
#endif

/// محرك المعالج: llama.cpp مع Gemma 4 E2B (GGUF). يشتغل على المعالج بس (بدون Metal)
/// عشان يقدر يكمل والتطبيق في الخلفية.
enum LlamaModelFile {
    static let repo = "unsloth/gemma-4-E2B-it-GGUF"
    static let file = "gemma-4-E2B-it-Q4_K_M.gguf"
    static let bytes: Int64 = 3_106_738_272
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gguf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(file)
    }
    static var remote: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    static var isDownloaded: Bool {
        let s = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return s == bytes
    }
    static var freeBytes: Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    static var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// تنزيل ملف النموذج مع التقدم
@MainActor
final class LlamaDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LlamaDownloader()
    @Published var progress: Double = 0
    @Published var running = false
    @Published var message = ""
    @Published var downloaded = LlamaModelFile.isDownloaded
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func start() {
        guard !running else { return }
        let need = LlamaModelFile.bytes + 300_000_000
        if LlamaModelFile.freeBytes < need {
            message = "المساحة ما تكفي: تحتاج \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) فاضية، والمتوفر \(ByteCountFormatter.string(fromByteCount: LlamaModelFile.freeBytes, countStyle: .file))"
            return
        }
        running = true; progress = 0; message = "ينزّل…"
        slog("llama: download start \(LlamaModelFile.remote)")
        task = session.downloadTask(with: LlamaModelFile.remote)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil; running = false; message = "انلغى" }

    func delete() {
        try? FileManager.default.removeItem(at: LlamaModelFile.url)
        Task { await LlamaEngine.shared.unload() }
        downloaded = false; message = "انحذف"
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : LlamaModelFile.bytes
        let p = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated { self.progress = p }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dst = LlamaModelFile.url
        try? FileManager.default.removeItem(at: dst)
        var err: String?
        do { try FileManager.default.moveItem(at: location, to: dst) } catch { err = error.localizedDescription }
        var u = dst
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        MainActor.assumeIsolated {
            self.running = false
            self.downloaded = LlamaModelFile.isDownloaded
            self.message = err.map { "فشل الحفظ: \($0)" } ?? (self.downloaded ? "جاهز ✅" : "الملف ناقص، نزّله مرة ثانية")
            slog("llama: download finished ok=\(self.downloaded) \(err ?? "")")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            self.running = false
            if (error as NSError).code != NSURLErrorCancelled { self.message = "فشل التنزيل: \(error.localizedDescription)" }
            slog("llama: download error \(error)")
        }
    }
}

/// llama.cpp على المعالج. نخلي السياق محمّل ونعيد استخدام بداية المحادثة (prompt cache).
actor LlamaEngine {
    static let shared = LlamaEngine()

    #if LLAMA
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    #endif
    /// الرموز اللي في الكاش الحين (عشان نعيد استخدام البداية المشتركة)
    private var cached: [Int32] = []
    private let nCtx: UInt32 = 4096

    var isLoaded: Bool {
        #if LLAMA
        return ctx != nil
        #else
        return false
        #endif
    }

    func unload() {
        #if LLAMA
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; cached = []
        slog("llama: unloaded")
        #endif
    }

    private func perfCores() -> Int32 {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
        return 2
    }

    func load() throws {
        #if LLAMA
        if ctx != nil { return }
        guard LlamaModelFile.isDownloaded else { throw SawtError.notReady("نموذج المعالج (نزّله من الإعدادات)") }
        let t0 = Date()
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 0
        // المعالج بس: ما نلمس Metal أبدًا (ممنوع في الخلفية)
        var devs: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
        let m: OpaquePointer? = devs.withUnsafeMutableBufferPointer { buf in
            mp.devices = buf.baseAddress
            return llama_model_load_from_file(LlamaModelFile.url.path, mp)
        }
        guard let m else { throw SawtError.failed("ما قدرت أحمّل نموذج المعالج") }
        var cp = llama_context_default_params()
        cp.n_ctx = nCtx
        cp.n_batch = 512
        cp.n_ubatch = 512
        let p = perfCores()
        let all = Int32(ProcessInfo.processInfo.activeProcessorCount)
        cp.n_threads = p
        cp.n_threads_batch = max(p, all - 1)
        cp.type_k = GGML_TYPE_Q8_0
        cp.type_v = GGML_TYPE_Q8_0
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        cp.offload_kqv = false
        cp.op_offload = false
        cp.swa_full = true   // عشان نقدر نقص الكاش ونعيد استخدام البداية
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw SawtError.failed("ما قدرت أجهّز سياق نموذج المعالج")
        }
        model = m; ctx = c; vocab = llama_model_get_vocab(m); cached = []
        slog("llama: loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms threads=\(p)/\(cp.n_threads_batch) ctx=\(nCtx) kv=q8_0 avail=\(RAM.availableMB)MB")
        #else
        throw SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة")
        #endif
    }

    /// صيغة Gemma 4 (نفس قالب النموذج): <|turn>role\n...<turn|>\n
    static func prompt(system: String, history: [Chat.Message], user: String) -> String {
        var s = "<|turn>system\n\(system)<turn|>\n"
        for m in history {
            let role: String
            switch m.role {
            case .assistant: role = "model"
            case .system: role = "system"
            default: role = "user"
            }
            s += "<|turn>\(role)\n\(m.content)<turn|>\n"
        }
        s += "<|turn>user\n\(user)<turn|>\n<|turn>model\n"
        return s
    }

    #if LLAMA
    private func tokenize(_ text: String) -> [Int32] {
        let utf8 = Array(text.utf8CString)
        var toks = [Int32](repeating: 0, count: utf8.count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &toks, Int32(toks.count), true, true)
        if n < 0 {
            toks = [Int32](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &toks, Int32(toks.count), true, true)
        }
        return Array(toks.prefix(Int(max(n, 0))))
    }

    private func piece(_ t: Int32) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    private func decode(_ toks: [Int32]) -> Bool {
        var i = 0
        while i < toks.count {
            var chunk = Array(toks[i..<min(i + 512, toks.count)])
            let r = chunk.withUnsafeMutableBufferPointer { b in
                llama_decode(ctx, llama_batch_get_one(b.baseAddress, Int32(b.count)))
            }
            if r != 0 { slog("llama: decode failed \(r)"); return false }
            i += chunk.count
        }
        return true
    }
    #endif

    /// يولّد ويرجّع القطع وحدة وحدة. شغّال كله داخل الـactor (خيط واحد).
    func generate(system: String, history: [Chat.Message], user: String, maxTokens: Int,
                  temperature: Float, topP: Float, emit: @Sendable (String) -> Bool) throws -> Int {
        #if LLAMA
        try load()
        guard let ctx, let vocab else { throw SawtError.notReady("نموذج المعالج") }
        var toks = tokenize(Self.prompt(system: system, history: history, user: user))
        // لو طويل: نقص من بداية السجل (نخلي التعليمات وآخر الكلام)
        let budget = Int(nCtx) - maxTokens - 8
        if toks.count > budget {
            slog("llama: prompt \(toks.count) > budget \(budget), trimming history")
            var h = history
            while !h.isEmpty, toks.count > budget {
                h.removeFirst()
                toks = tokenize(Self.prompt(system: system, history: h, user: user))
            }
        }
        // كاش البداية المشتركة
        var common = 0
        while common < min(cached.count, toks.count - 1), cached[common] == toks[common] { common += 1 }
        let mem = llama_get_memory(ctx)
        if common < cached.count {
            if !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
                llama_memory_clear(mem, true); common = 0
            }
        }
        let t0 = Date()
        guard decode(Array(toks[common...])) else {
            llama_memory_clear(mem, true); cached = []
            throw SawtError.failed("llama: فشل معالجة الرسالة")
        }
        let prefillMs = Int(Date().timeIntervalSince(t0) * 1000)
        cached = toks
        slog("llama: prefill \(toks.count - common) new tok (cached \(common)) in \(prefillMs)ms")

        let sp = llama_sampler_chain_default_params()
        let smpl = llama_sampler_chain_init(sp)
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(64))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        let tg = Date()
        var n = 0
        var pending: [UInt8] = []
        var text = ""
        var firstID: Int32 = -1
        while n < maxTokens {
            if Task.isCancelled { break }
            let t = llama_sampler_sample(smpl, ctx, -1)
            if n == 0 { firstID = t }
            if llama_vocab_is_eog(vocab, t) { break }
            n += 1
            pending += piece(t)
            if let s = String(validating: pending, as: UTF8.self) {
                pending = []
                text += s
                // نهاية الدور بصيغة نصية
                if text.contains("<turn|>") { break }
                if !emit(s) { break }
            }
            var one = [t]
            let r = one.withUnsafeMutableBufferPointer { b in llama_decode(ctx, llama_batch_get_one(b.baseAddress, 1)) }
            if r != 0 { slog("llama: decode step failed \(r)"); break }
            cached.append(t)
        }
        let dt = Date().timeIntervalSince(tg)
        slog("llama: gen \(n) tok in \(Int(dt * 1000))ms ≈ \(String(format: "%.1f", Double(n) / max(dt, 0.001))) tok/s first=\(firstID) prefill=\(prefillMs)ms")
        return n
        #else
        throw SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة")
        #endif
    }

    /// غلاف بث مثل LLMService
    nonisolated func stream(system: String, history: [Chat.Message], user: String, maxTokens: Int,
                            temperature: Float = 0.7, topP: Float = 0.9) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task(priority: .userInitiated) {
                do {
                    let flag = FlagBox()
                    _ = try await self.generate(system: system, history: history, user: user, maxTokens: maxTokens,
                                                temperature: temperature, topP: topP) { s in
                        // نخفي قناة التفكير لو طلعت
                        if s.contains("<|channel>") { flag.on = true }
                        if flag.on { if s.contains("<channel|>") { flag.on = false }; return true }
                        cont.yield(s.replacingOccurrences(of: "<turn|>", with: ""))
                        return !Task.isCancelled
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

final class FlagBox: @unchecked Sendable { var on = false }
