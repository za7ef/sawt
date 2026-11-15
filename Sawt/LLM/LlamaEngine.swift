import Foundation
import MLXLMCommon
#if LLAMA
import llama
#endif

/// محرك المعالج: llama.cpp مع Gemma 4 E2B (GGUF). يشتغل على المعالج بس (بدون Metal)
/// عشان يقدر يكمل والتطبيق في الخلفية.
struct GGUFSpec: Sendable {
    enum Template: Sendable { case gemma, chatml }
    let name: String
    let repo: String
    let file: String
    let bytes: Int64
    let template: Template

    static let gemma = GGUFSpec(name: "Gemma 4 E2B", repo: "unsloth/gemma-4-E2B-it-GGUF", file: "gemma-4-E2B-it-Q4_K_M.gguf",
                                bytes: 3_106_738_272, template: .gemma)
    /// Qwen3.5-4B (هجين Gated DeltaNet) — مدعوم في llama.cpp b12387
    static let qwen = GGUFSpec(name: "Qwen3.5-4B", repo: "unsloth/Qwen3.5-4B-GGUF", file: "Qwen3.5-4B-Q4_K_M.gguf",
                               bytes: 2_740_937_888, template: .chatml)

    var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gguf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(file)
    }
    var remote: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var isDownloaded: Bool {
        let s = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return s == bytes
    }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum LlamaModelFile {
    static let spec = GGUFSpec.gemma
    static var url: URL { spec.url }
    static var remote: URL { spec.remote }
    static var isDownloaded: Bool { spec.isDownloaded }
    static var bytes: Int64 { spec.bytes }
    static var freeBytes: Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    static var sizeText: String { spec.sizeText }
}

/// تنزيل ملف النموذج مع التقدم
@MainActor
final class LlamaDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LlamaDownloader(spec: .gemma)
    static let qwen = LlamaDownloader(spec: .qwen)
    let spec: GGUFSpec
    init(spec: GGUFSpec) { self.spec = spec; super.init(); downloaded = spec.isDownloaded }
    @Published var progress: Double = 0
    @Published var running = false
    @Published var message = ""
    @Published var downloaded = false
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func start() {
        guard !running else { return }
        let need = spec.bytes + 300_000_000
        if LlamaModelFile.freeBytes < need {
            message = "المساحة ما تكفي: تحتاج \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) فاضية، والمتوفر \(ByteCountFormatter.string(fromByteCount: LlamaModelFile.freeBytes, countStyle: .file))"
            return
        }
        running = true; progress = 0; message = "ينزّل…"
        slog("llama: download start \(spec.remote)")
        task = session.downloadTask(with: spec.remote)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil; running = false; message = "انلغى" }

    func delete() {
        try? FileManager.default.removeItem(at: spec.url)
        let eng = spec.template == .chatml ? LlamaEngine.qwen : LlamaEngine.shared
        Task { await eng.unload() }
        downloaded = false; message = "انحذف"
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : spec.bytes
        let p = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated { self.progress = p }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dst = spec.url
        try? FileManager.default.removeItem(at: dst)
        var err: String?
        do { try FileManager.default.moveItem(at: location, to: dst) } catch { err = error.localizedDescription }
        var u = dst
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        MainActor.assumeIsolated {
            self.running = false
            self.downloaded = self.spec.isDownloaded
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
    static let shared = LlamaEngine(spec: .gemma)
    /// نموذج الوكيل الثاني (يتحمّل عند الطلب)
    static let qwen = LlamaEngine(spec: .qwen)
    let spec: GGUFSpec
    init(spec: GGUFSpec) { self.spec = spec }

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

    /// خيوط التوليد: من اختبار الخيوط لو انحفظ، وإلا عدد الأنوية القوية
    private func genThreads() -> Int32 {
        let v = UserDefaults.standard.integer(forKey: "llamaThreads")
        return v > 0 ? Int32(v) : perfCores()
    }

    /// يجرب ٢/٤/٦ خيوط على نفس السؤال ويحفظ الأسرع
    func benchThreads() throws -> String {
        #if LLAMA
        try load()
        guard let ctx else { throw SawtError.notReady("نموذج المعالج") }
        let all = Int32(ProcessInfo.processInfo.activeProcessorCount)
        var best: (Int32, Double) = (perfCores(), 0)
        var lines: [String] = []
        for n in [Int32(2), 4, 6] where n <= all {
            llama_set_n_threads(ctx, n, max(n, all - 1))
            let t0 = Date()
            let k = try generate(system: "جاوب باختصار.", history: [], user: "عدّ من ١ إلى ٣٠ بالكلمات.", maxTokens: 40,
                                 temperature: 0.1, topP: 0.9, emit: { _ in true }, trimForCPU: false)
            let rate = Double(k) / max(Date().timeIntervalSince(t0), 0.001)
            lines.append("\(n): \(String(format: "%.1f", rate))")
            slog("llama: bench threads=\(n) \(String(format: "%.2f", rate)) tok/s (incl. prefill)")
            if rate > best.1 { best = (n, rate) }
        }
        UserDefaults.standard.set(Int(best.0), forKey: "llamaThreads")
        llama_set_n_threads(ctx, best.0, max(best.0, all - 1))
        return "الأسرع \(best.0) خيوط — " + lines.joined(separator: "، ") + " رمز/ث"
        #else
        throw SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة")
        #endif
    }

    /// تسخين: يحمّل النموذج ويعالج التعليمات مسبقًا عشان أول رد يكون أسرع
    func prewarm(system: String) {
        #if LLAMA
        do {
            try load()
            let t0 = Date()
            _ = try generate(system: system, history: [], user: ".", maxTokens: 1, temperature: 0.1, topP: 0.9,
                             emit: { _ in false }, trimForCPU: false)
            slog("llama: prewarm \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch { slog("llama: prewarm failed \(error)") }
        #endif
    }

    func load() throws {
        #if LLAMA
        if ctx != nil { return }
        guard spec.isDownloaded else { throw SawtError.notReady("\(spec.name) (نزّله أول)") }
        let t0 = Date()
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 0
        // المعالج بس: ما نلمس Metal أبدًا (ممنوع في الخلفية)
        var devs: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
        let m: OpaquePointer? = devs.withUnsafeMutableBufferPointer { buf in
            mp.devices = buf.baseAddress
            return llama_model_load_from_file(spec.url.path, mp)
        }
        guard let m else { throw SawtError.failed("ما قدرت أحمّل نموذج المعالج") }
        var cp = llama_context_default_params()
        cp.n_ctx = nCtx
        cp.n_batch = 512
        cp.n_ubatch = 512
        let p = genThreads()
        let all = Int32(ProcessInfo.processInfo.activeProcessorCount)
        cp.n_threads = p
        cp.n_threads_batch = max(p, all - 1)
        cp.type_k = GGML_TYPE_Q8_0
        cp.type_v = GGML_TYPE_Q8_0
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        cp.offload_kqv = false
        cp.op_offload = false
        cp.swa_full = true   // عشان نقدر نقص الكاش ونعيد استخدام البداية
        if spec.template == .chatml { cp.n_ctx = 3072 }   // الوكيل ما يحتاج سياق طويل
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw SawtError.failed("ما قدرت أجهّز سياق نموذج المعالج")
        }
        model = m; ctx = c; vocab = llama_model_get_vocab(m); cached = []
        slog("llama: [\(spec.name)] loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms threads=\(p)/\(cp.n_threads_batch) ctx=\(nCtx) kv=q8_0 avail=\(RAM.availableMB)MB")
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

    /// قالب ChatML (Qwen). بدون تفكير: نحط كتلة تفكير فاضية بعد بداية دور المساعد
    static func chatml(system: String, history: [Chat.Message], user: String, think: Bool) -> String {
        var s = "<|im_start|>system\n\(system)<|im_end|>\n"
        for m in history {
            let role = m.role == .assistant ? "assistant" : (m.role == .system ? "system" : "user")
            s += "<|im_start|>\(role)\n\(m.content)<|im_end|>\n"
        }
        s += "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        if !think { s += "<think>\n\n</think>\n\n" }
        return s
    }

    private func render(system: String, history: [Chat.Message], user: String) -> String {
        spec.template == .chatml ? Self.chatml(system: system, history: history, user: user, think: false)
                                 : Self.prompt(system: system, history: history, user: user)
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
                  temperature: Float, topP: Float, emit: @Sendable (String) -> Bool, trimForCPU: Bool = true,
                  grammar: String? = nil) throws -> Int {
        #if LLAMA
        try load()
        guard let ctx, let vocab else { throw SawtError.notReady("نموذج المعالج") }
        // على المعالج: آخر ٦ رسائل بس، وكل رسالة قديمة مقصوصة (الـprefill هو أبطأ جزء)
        var history = history
        if trimForCPU {
            history = Array(history.suffix(6)).map { m in
                m.content.count > 600 ? Chat.Message(role: m.role, content: String(m.content.prefix(600))) : m
            }
        }
        let tp = Date()
        var toks = tokenize(render(system: system, history: history, user: user))
        // لو طويل: نقص من بداية السجل (نخلي التعليمات وآخر الكلام)
        let budget = Int(llama_n_ctx(ctx)) - maxTokens - 8
        if toks.count > budget {
            slog("llama: prompt \(toks.count) > budget \(budget), trimming history")
            var h = history
            while !h.isEmpty, toks.count > budget {
                h.removeFirst()
                toks = tokenize(render(system: system, history: h, user: user))
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
        let newTok = toks.count - common
        slog("llama: prefill \(newTok) new tok (cached \(common)/\(toks.count)) in \(prefillMs)ms ≈ \(String(format: "%.0f", Double(newTok) / max(Double(prefillMs) / 1000, 0.001))) tok/s tokenize=\(Int(t0.timeIntervalSince(tp) * 1000))ms threads=\(llama_n_threads(ctx))")

        let sp = llama_sampler_chain_default_params()
        let smpl = llama_sampler_chain_init(sp)
        defer { llama_sampler_free(smpl) }
        // قيود GBNF: النموذج ما يقدر يطلع إلا JSON صالح بالشكل المطلوب
        if let grammar {
            if let g = llama_sampler_init_grammar(vocab, grammar, "root") { llama_sampler_chain_add(smpl, g) }
            else { slog("llama: grammar parse failed — unconstrained") }
        }
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
                if text.contains("<turn|>") || text.contains("<|im_end|>") { break }
                if !emit(s) { break }
            }
            var one = [t]
            let r = one.withUnsafeMutableBufferPointer { b in llama_decode(ctx, llama_batch_get_one(b.baseAddress, 1)) }
            if r != 0 { slog("llama: decode step failed \(r)"); break }
            cached.append(t)
        }
        let dt = Date().timeIntervalSince(tg)
        slog("llama: [\(spec.name)] gen \(n) tok in \(Int(dt * 1000))ms ≈ \(String(format: "%.1f", Double(n) / max(dt, 0.001))) tok/s first=\(firstID) prefill=\(prefillMs)ms")
        return n
        #else
        throw SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة")
        #endif
    }

    /// للوكيل: يولّد رد كامل (مع قيود اختيارية) ويرجّعه نص
    func complete(system: String, user: String, maxTokens: Int, grammar: String?) throws -> String {
        let box = TextBox()
        _ = try generate(system: system, history: [], user: user, maxTokens: maxTokens, temperature: 0.2, topP: 0.9,
                         emit: { s in box.append(s); return !Task.isCancelled }, trimForCPU: false, grammar: grammar)
        return box.text.replacingOccurrences(of: "<|im_end|>", with: "").replacingOccurrences(of: "<turn|>", with: "")
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
final class TextBox: @unchecked Sendable {
    private let l = NSLock(); private var t = ""
    func append(_ s: String) { l.lock(); t += s; l.unlock() }
    var text: String { l.lock(); defer { l.unlock() }; return t }
}
