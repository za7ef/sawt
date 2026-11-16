import Foundation
import MLX
#if LLAMA
import llama
#endif

/// أصوات «أودار» (Audar-TTS-V1-Flash من AudarAI، رخصة AudarAI Open License v1.0).
/// نموذج لغوي صغير (Qwen2.5، ‏553M) يكتب رموز صوت NeuCodec (50 رمز/ث) يشغّله llama.cpp على المعالج،
/// ومفكك NeuCodec (Apache-2.0) على MLX يحوّلها لصوت 24kHz.
/// الأصوات الستة: مراجع جاهزة (نص + رموز) رمّزناها مسبقًا من عينات النموذج الرسمية، فما نحتاج مرمّز الصوت الثقيل على الجوال.
@MainActor
final class AudarVoice: ObservableObject {
    static let shared = AudarVoice()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published var state: State = .notDownloaded {
        didSet { ModelManager.shared.refreshDownloadFlag() }
    }
    var isBusy: Bool { if case .downloading = state { return true }; return false }
    @Published var testing = false
    @Published var lastTest: String?

    /// النموذج من مستودعه الرسمي، مثبّت على نسخة محددة
    static let revision = "addf2d80538edab4de2103843678825bc11ddce1"
    static let releaseBase = "https://github.com/za7ef/sawt-releases/releases/download/voices/"
    /// كل ملف: روابط أجزائه بالترتيب (تنضم في ملف واحد) + اسمه + حجمه
    static let files: [(urls: [String], name: String, bytes: Int64)] = [
        (["https://huggingface.co/audarai/Audar-TTS-V1-Flash/resolve/\(revision)/Audar-TTS-V1-Flash-Q4_K_M.gguf"],
         "audar-flash-q4_k_m.gguf", 462_208_928),
        // مفكك NeuCodec فقط (من neuphonic/neucodec نسخة a940021، Apache-2.0)، محوّل لـfloat16 وتخطيط MLX.
        // المستودع الأصلي يطلب تسجيل دخول، فننشر المفكك (مع الرخصة والإشعار) في إصدار الأصوات العام، مقسوم 40 جزء.
        ((0 ..< 40).map { releaseBase + String(format: "neucodec-decoder-f16.safetensors.part%02d", $0) },
         "neucodec-decoder-f16.safetensors", 375_295_836),
    ]

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audar", isDirectory: true)
    }
    nonisolated static var ggufURL: URL { dir.appendingPathComponent(files[0].name) }
    nonisolated static var decoderURL: URL { dir.appendingPathComponent(files[1].name) }
    nonisolated static var isInstalled: Bool {
        files.allSatisfy { f in
            let p = dir.appendingPathComponent(f.name).path
            return ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0) == f.bytes
        }
    }

    static let testSentence = "هلا والله، كيف حالك اليوم؟ إن شاء الله أمورك طيبة والشغل ماشي تمام."

    private var task: Task<Void, Never>?

    private init() {
        _state = Published(initialValue: AudarVoice.isInstalled ? .ready : .notDownloaded)
    }

    var sizeOnDisk: Int64 { Storage.size(AudarVoice.dir) }

    func download() {
        guard task == nil else { return }
        task = Task {
            if let why = Storage.spaceProblem(forGB: 0.9) { state = .failed(why); task = nil; return }
            guard await NetworkGate.shared.permit("تنزيل أصوات أودار") else { task = nil; return }
            do {
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var d = Self.dir; try? d.setResourceValues(excluded)
                let total = Self.files.reduce(Int64(0)) { $0 + $1.bytes }
                var done: Int64 = 0
                state = .downloading(0)
                for f in Self.files {
                    let dest = Self.dir.appendingPathComponent(f.name)
                    let have = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                    if have != f.bytes {
                        try? FileManager.default.removeItem(at: dest)
                        let base = done
                        if f.urls.count == 1 {
                            try await Downloader.fetch(URL(string: f.urls[0])!, to: dest) { got in
                                Task { @MainActor in self.state = .downloading(Double(base + got) / Double(total)) }
                            }
                        } else {
                            // الأجزاء: كل جزء لملف مؤقت ثم يُلصق في آخر الملف
                            FileManager.default.createFile(atPath: dest.path, contents: nil)
                            let out = try FileHandle(forWritingTo: dest)
                            defer { try? out.close() }
                            var partBase = base
                            for u in f.urls {
                                try Task.checkCancellation()
                                let tmp = Self.dir.appendingPathComponent("part.tmp")
                                try? FileManager.default.removeItem(at: tmp)
                                let pb = partBase
                                try await Downloader.fetch(URL(string: u)!, to: tmp) { got in
                                    Task { @MainActor in self.state = .downloading(Double(pb + got) / Double(total)) }
                                }
                                let data = try Data(contentsOf: tmp, options: .alwaysMapped)
                                try out.write(contentsOf: data)
                                partBase += Int64(data.count)
                                try? FileManager.default.removeItem(at: tmp)
                            }
                        }
                        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                        guard size == f.bytes else {
                            try? FileManager.default.removeItem(at: dest)
                            throw SawtError.failed("حجم \(f.name) غير متوقع (\(size))")
                        }
                    }
                    done += f.bytes
                }
                state = .ready
                slog("audar: installed \(Storage.format(sizeOnDisk))")
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                slog("audar: install failed \(error)")
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = AudarVoice.isInstalled ? .ready : .notDownloaded
    }

    func delete() {
        cancel()
        Task { await AudarEngine.shared.unload() }
        try? FileManager.default.removeItem(at: Self.dir)
        state = .notDownloaded
        lastTest = nil
        if case .audar = AppSettings.shared.voice.kind {
            AppSettings.shared.voiceID = Catalog.voices.first?.id ?? "apple"
        }
    }

    /// يولّد الجملة التجريبية بالصوت المختار (أو أول صوت أودار) ويشغلها، مع الوقت ونسبة الوقت الحقيقي.
    func test() {
        guard !testing else { return }
        testing = true
        lastTest = nil
        let voiceKey: String
        if case .audar(let k) = AppSettings.shared.voice.kind { voiceKey = k } else { voiceKey = AudarRefs.all[0].key }
        Task {
            let r = await AudarEngine.shared.synthesizeTimed(Self.testSentence, voice: voiceKey)
            testing = false
            switch r {
            case .failure(let e):
                lastTest = "ما زبط: \(e.localizedDescription)"
            case .success(let out):
                let rtf = out.genSeconds / max(out.audioSeconds, 0.01)
                lastTest = String(format: "التوليد: %.1f ث (%.0f رمز/ث) • طول الصوت: %.1f ث • النسبة: %.2f× (أقل من 1 يعني أسرع من الكلام)",
                                  out.genSeconds, out.tokensPerSecond, out.audioSeconds, rtf)
                if out.loadSeconds > 0.05 {
                    lastTest! += String(format: "\nالتحميل للذاكرة أول مرة: %.1f ث", out.loadSeconds)
                }
                Speaker.shared.play(samples: out.samples, sampleRate: 24_000)
            }
        }
    }
}

/// المحرّك: llama.cpp للنموذج اللغوي + مفكك NeuCodec على MLX.
/// التطبيق قدّام: llama على كرت الشاشة (Metal)، وبالخلفية على المعالج (Metal ممنوع هناك) — يتبدّل تلقائيًا ويكمل نفس الجملة.
/// الصوت يطلع على دفعات وهو يتولّد (أول دفعة بعد ~0.6 ث صوت)، بدل ما ننتظر الجملة كاملة.
actor AudarEngine {
    static let shared = AudarEngine()

    struct Output {
        let samples: [Float]
        let genSeconds: Double
        let audioSeconds: Double
        let loadSeconds: Double
        let tokensPerSecond: Double
    }

    /// أول رمز صوت في المفردات (<|speech_0|>) — متحقق منه من ملف GGUF: 151671 … 217206 متتالية
    static let speechBase: Int32 = 151_671
    static let speechCount: Int32 = 65_536
    /// <|TARGET_CODES_END|>
    static let codesEnd: Int32 = 217_659
    /// حد أعلى للجملة الوحدة: 30 ثانية صوت
    static let maxCodes = 1_500

    #if LLAMA
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    #endif
    private var decoder: NeuCodecDecoder?
    /// النموذج محمّل على كرت الشاشة
    private var onGPU = false
    /// الرموز اللي في الكاش (بداية الطلب مع المرجع تتكرر لكل جملة، فنعيد استخدامها)
    private var cached: [Int32] = []
    private let nCtx: UInt32 = 2_560

    var isLoaded: Bool { decoder != nil }

    func unload() {
        #if LLAMA
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil
        #endif
        cached = []
        if decoder != nil { decoder = nil; MLX.Memory.clearCache(); slog("audar: unloaded") }
    }

    /// يحمّل بالخلفية ويسخّن بصوت المستخدم المختار (يعالج المرجع مسبقًا عشان أول جملة تطلع أسرع)
    func preload(voice: String) {
        do {
            try load()
            #if LLAMA
            if let ref = AudarRefs.find(voice) {
                let t0 = Date()
                _ = try prefill(Self.prompt(ref: ref, text: "."))
                slog("audar: prewarm \(voice) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            #endif
        } catch { slog("audar: preload failed \(error)") }
    }

    private func load() throws {
        #if LLAMA
        // الجهاز المطلوب تغيّر (قدّام ↔ خلفية): نعيد تحميل llama بس (المفكك يبقى)
        let wantGPU = AppPhase.active
        if ctx != nil, onGPU != wantGPU {
            slog("audar: switch llama to \(wantGPU ? "gpu" : "cpu")")
            if let ctx { llama_free(ctx) }
            if let model { llama_model_free(model) }
            ctx = nil; model = nil; vocab = nil; cached = []
        }
        if ctx != nil, decoder != nil { return }
        guard AudarVoice.isInstalled else { throw SawtError.notReady("أصوات أودار (نزّلها أول)") }
        let t0 = Date()
        if ctx == nil {
            llama_backend_init()
            var mp = llama_model_default_params()
            let m: OpaquePointer?
            if wantGPU {
                // كرت الشاشة: كل الطبقات (النموذج صغير ~460 ميقا)، أسرع بكثير من المعالج
                mp.n_gpu_layers = 999
                m = llama_model_load_from_file(AudarVoice.ggufURL.path, mp)
            } else {
                // المعالج بس: Metal ممنوع والتطبيق بالخلفية، والمكالمة تكمل بالخلفية
                mp.n_gpu_layers = 0
                var devs: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
                m = devs.withUnsafeMutableBufferPointer { buf in
                    mp.devices = buf.baseAddress
                    return llama_model_load_from_file(AudarVoice.ggufURL.path, mp)
                }
            }
            guard let m else { throw SawtError.failed("ما قدرت أحمّل نموذج أودار") }
            var cp = llama_context_default_params()
            cp.n_ctx = nCtx
            cp.n_batch = 512
            cp.n_ubatch = 512
            let all = Int32(ProcessInfo.processInfo.activeProcessorCount)
            // ٤ خيوط: النموذج صغير، ونخلي نواة للنموذج اللغوي اللي يكتب الرد بنفس الوقت
            let threads = ThermalWatch.isHot ? Int32(2) : min(Int32(4), max(Int32(2), all - 2))
            cp.n_threads = threads
            cp.n_threads_batch = max(threads, all - 1)
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
            cp.offload_kqv = wantGPU
            cp.op_offload = wantGPU
            guard let c = llama_init_from_model(m, cp) else {
                llama_model_free(m)
                throw SawtError.failed("ما قدرت أجهّز سياق أودار")
            }
            model = m; ctx = c; vocab = llama_model_get_vocab(m); cached = []; onGPU = wantGPU
            // تحقق: رموز الصوت في مكانها المتوقع
            let check = tokenize("<|speech_0|><|TARGET_CODES_END|>")
            guard check == [Self.speechBase, Self.codesEnd] else {
                unload()
                throw SawtError.failed("مفردات أودار غير متوقعة \(check)")
            }
            slog("audar: llama loaded \(wantGPU ? "gpu" : "cpu") threads=\(threads) ctx=\(nCtx)")
        }
        if decoder == nil {
            decoder = try NeuCodecDecoder(file: AudarVoice.decoderURL)
        }
        slog("audar: loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms ram=\(RAM.footprintMB)MB avail=\(RAM.availableMB)MB")
        #else
        throw SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة")
        #endif
    }

    /// نفس صيغة الطلب في بطاقة النموذج الرسمية
    static func prompt(ref: AudarRefs.Ref, text: String) -> String {
        "user: Convert the text to speech:"
            + "<|REF_TEXT_START|>\(ref.text)<|REF_TEXT_END|>"
            + "<|REF_SPEECH_START|>" + ref.codes.map { "<|speech_\($0)|>" }.joined() + "<|REF_SPEECH_END|>"
            + "<|TARGET_TEXT_START|>\(text)<|TARGET_TEXT_END|>"
            + "\nassistant:<|TARGET_CODES_START|>"
    }

    #if LLAMA
    private func tokenize(_ text: String) -> [Int32] {
        let utf8 = Array(text.utf8CString)
        var toks = [Int32](repeating: 0, count: utf8.count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &toks, Int32(toks.count), false, true)
        if n < 0 {
            toks = [Int32](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &toks, Int32(toks.count), false, true)
        }
        return Array(toks.prefix(Int(max(n, 0))))
    }

    /// يعالج الطلب ويعيد استخدام البداية المشتركة مع الطلب السابق (المرجع). يرجع عدد الرموز الجديدة.
    private func prefill(_ prompt: String) throws -> Int {
        guard let ctx else { throw SawtError.notReady("أودار") }
        let toks = tokenize(prompt)
        guard toks.count + Self.maxCodes + 8 < Int(nCtx) else {
            throw SawtError.failed("الجملة أطول من سياق أودار (\(toks.count))")
        }
        var common = 0
        while common < min(cached.count, toks.count - 1), cached[common] == toks[common] { common += 1 }
        let mem = llama_get_memory(ctx)
        if common < cached.count, !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
            llama_memory_clear(mem, true); common = 0
        }
        var i = common
        while i < toks.count {
            var chunk = Array(toks[i ..< min(i + 512, toks.count)])
            let r = chunk.withUnsafeMutableBufferPointer { b in
                llama_decode(ctx, llama_batch_get_one(b.baseAddress, Int32(b.count)))
            }
            if r != 0 { llama_memory_clear(mem, true); cached = []; throw SawtError.failed("أودار: فشل معالجة الطلب (\(r))") }
            i += chunk.count
        }
        cached = toks
        return toks.count - common
    }

    /// التطبيق راح للخلفية والنموذج على كرت الشاشة: نوقف ونكمل على المعالج
    struct MovedToBackground: Error {}

    /// يكتب رموز الصوت لين رمز النهاية. أي رمز غير صوتي نعتبره نهاية.
    /// codes: الرموز اللي انكتبت قبل (نكمل بعدها بعد تبديل الجهاز)، onCodes: يُستدعى كل ما زادت الرموز
    private func generateCodes(maxCodes: Int, codes start: [Int] = [], onCodes: ([Int], Bool) -> Void = { _, _ in }) throws -> [Int] {
        guard let ctx, let vocab else { throw SawtError.notReady("أودار") }
        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        // إعدادات البطاقة الرسمية (repeat 1.1، top_k 40، top_p 0.9) مع حرارة 0.7 لإلقاء أهدأ وأثبت
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1 ... UInt32.max)))
        var codes = start
        // نعطي المُعاقِب الرموز السابقة عشان يكمل بنفس الحالة
        for c in start.suffix(64) { llama_sampler_accept(smpl, Self.speechBase + Int32(c)) }
        while codes.count < maxCodes {
            if Task.isCancelled { break }
            if onGPU, !AppPhase.active { throw MovedToBackground() }
            let t = llama_sampler_sample(smpl, ctx, -1)
            if t == Self.codesEnd || llama_vocab_is_eog(vocab, t) { break }
            guard t >= Self.speechBase, t < Self.speechBase + Self.speechCount else {
                slog("audar: non-speech token \(t) → stop"); break
            }
            codes.append(Int(t - Self.speechBase))
            var one = [t]
            let r = one.withUnsafeMutableBufferPointer { b in llama_decode(ctx, llama_batch_get_one(b.baseAddress, 1)) }
            if r != 0 { slog("audar: decode step failed \(r)"); break }
            cached.append(t)
            onCodes(codes, false)
        }
        onCodes(codes, true)
        return codes
    }

    /// يكمّل بعد إعادة التحميل: يعالج الطلب + الرموز اللي انكتبت
    private func prefillResume(_ prompt: String, codes: [Int]) throws {
        _ = try prefill(prompt)
        guard let ctx, !codes.isEmpty else { return }
        var toks = codes.map { Self.speechBase + Int32($0) }
        var i = 0
        while i < toks.count {
            let n = min(512, toks.count - i)
            let r = toks.withUnsafeMutableBufferPointer { b in
                llama_decode(ctx, llama_batch_get_one(b.baseAddress! + i, Int32(n)))
            }
            if r != 0 { throw SawtError.failed("أودار: فشل الاستئناف (\(r))") }
            i += n
        }
        cached += toks
    }
    #endif

    /// للتجربة: يرجع العينات كاملة (فاضي لو فشل)
    func synthesize(_ text: String, voice: String) async -> [Float] {
        switch await synthesizeTimed(text, voice: voice) {
        case .success(let o): return o.samples
        case .failure(let e): slog("audar: synth failed \(e)"); return []
        }
    }

    /// تقسيم المفكك: أول دفعة بعد firstChunk رمز (0.6 ث صوت) عشان الصوت يبدأ بسرعة، وبعدها كل step.
    /// كل نافذة تاخذ left رمز قبلها كسياق، ونمسك آخر hold رموز لين يجي اللي بعدها (حدود أنظف)،
    /// ونليّن الوصلة بـxfade عينة. اختبار على السيرفر (npdec): ارتباط الطيف مع فك الجملة كاملة ≈ 0.99.
    static let firstChunk = 30, step = 75, left = 50, hold = 15
    static let spc = 480          // عينات لكل رمز (24k / 50)
    static let xfade = 240        // 10 ملي ثانية

    func synthesizeTimed(_ text: String, voice: String) async -> Result<Output, Error> {
        var all: [Float] = []
        let r = await synthesizeStream(text, voice: voice) { all += $0 }
        return r.map { o in Output(samples: all, genSeconds: o.genSeconds, audioSeconds: o.audioSeconds,
                                   loadSeconds: o.loadSeconds, tokensPerSecond: o.tokensPerSecond) }
    }

    /// يولّد ويرسل الصوت على دفعات وهو يتولّد. onAudio يُستدعى بالترتيب (على خيط المحرك).
    func synthesizeStream(_ text: String, voice: String, onAudio: @escaping ([Float]) -> Void) async -> Result<Output, Error> {
        #if LLAMA
        do {
            guard let ref = AudarRefs.find(voice) ?? AudarRefs.all.first else { throw SawtError.failed("صوت أودار غير معروف") }
            let tl = Date()
            let wasLoaded = isLoaded
            try load()
            let loadS = wasLoaded ? 0 : Date().timeIntervalSince(tl)
            let t0 = Date()
            let prompt = Self.prompt(ref: ref, text: text)
            let fresh = try prefill(prompt)
            let tp = Date()
            // تقدير سخي لطول الجملة: ~15 رمز لكل حرف كحد أعلى، عشان لو النموذج ما وقف ما يطوّل
            let cap = min(Self.maxCodes, max(150, text.count * 15))

            var emitted = 0          // كم رمز طلع صوته
            var tail: [Float] = []   // ذيل الدفعة السابقة للتليين
            var total = 0
            var firstAt: Date?
            var decodeMs = 0.0
            var chunks = 0
            var failure: Error?
            func flush(_ codes: [Int], last: Bool) {
                guard failure == nil, let decoder else { return }
                let need = emitted == 0 ? Self.firstChunk : Self.step + Self.hold
                guard last ? codes.count > emitted : codes.count - emitted >= need else { return }
                let end = last ? codes.count : codes.count - Self.hold
                guard end > emitted else { return }
                let s = max(0, emitted - Self.left)
                let td = Date()
                let gpu = AppPhase.active
                let box = MLXErrBox()
                let y: [Float]
                do {
                    y = try withErrorHandler({ m in box.set(m) }) {
                        try Device.withDefaultDevice(gpu ? Device.gpu : Device.cpu) { decoder.decode(Array(codes[s ..< codes.count])) }
                    }
                    if let m = box.message { throw MLXRunError(message: m, cpu: !gpu) }
                } catch { failure = error; return }
                decodeMs += Date().timeIntervalSince(td) * 1000
                let a = (emitted - s) * Self.spc
                let b = min(y.count, (end - s) * Self.spc + (last ? 0 : Self.xfade))
                guard b > a else { return }
                var seg = Array(y[a ..< b])
                // الوصلة: نخلط ذيل الدفعة السابقة مع بداية هذي
                let n = min(tail.count, seg.count)
                for i in 0 ..< n {
                    let w = Float(i + 1) / Float(n + 1)
                    seg[i] = tail[i] * (1 - w) + seg[i] * w
                }
                if last { tail = [] } else {
                    tail = Array(seg.suffix(Self.xfade))
                    seg.removeLast(min(Self.xfade, seg.count))
                }
                emitted = end
                total += seg.count
                chunks += 1
                if firstAt == nil { firstAt = Date() }
                onAudio(seg)
            }

            var codes: [Int] = []
            while true {
                do {
                    codes = try generateCodes(maxCodes: cap, codes: codes) { c, last in flush(c, last: last) }
                    break
                } catch is MovedToBackground {
                    // راح للخلفية: نحمّل على المعالج ونكمل من نفس المكان
                    try load()
                    try prefillResume(prompt, codes: codes)
                }
            }
            if let failure { throw failure }
            MLX.Memory.clearCache()
            guard !codes.isEmpty, total > 0 else { throw SawtError.failed("أودار ما طلّع صوت") }
            let genS = Date().timeIntervalSince(t0)
            let audioS = Double(total) / 24_000
            let tps = Double(codes.count) / max(Date().timeIntervalSince(tp) - decodeMs / 1000, 0.001)
            let first = Int((firstAt ?? Date()).timeIntervalSince(t0) * 1000)
            slog("audar: \(voice) \(onGPU ? "gpu" : "cpu") prefill \(fresh) tok \(Int(tp.timeIntervalSince(t0) * 1000))ms, first audio \(first)ms, \(codes.count) codes \(String(format: "%.1f", tps)) tok/s, \(chunks) chunks decode \(Int(decodeMs))ms, audio \(String(format: "%.2f", audioS))s RTF=\(String(format: "%.2f", genS / max(audioS, 0.01))) ram=\(RAM.footprintMB)MB")
            return .success(Output(samples: [], genSeconds: genS, audioSeconds: audioS, loadSeconds: loadS, tokensPerSecond: tps))
        } catch {
            return .failure(error)
        }
        #else
        return .failure(SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة"))
        #endif
    }
}
