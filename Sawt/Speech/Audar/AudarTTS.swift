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

/// المحرّك: llama.cpp للنموذج اللغوي (المعالج بس، يشتغل حتى والتطبيق بالخلفية) + مفكك NeuCodec على MLX.
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
        if ctx != nil, decoder != nil { return }
        guard AudarVoice.isInstalled else { throw SawtError.notReady("أصوات أودار (نزّلها أول)") }
        let t0 = Date()
        if ctx == nil {
            llama_backend_init()
            var mp = llama_model_default_params()
            mp.n_gpu_layers = 0
            // المعالج بس (مثل نموذج المعالج): Metal ممنوع والتطبيق بالخلفية، والمكالمة تكمل بالخلفية
            var devs: [ggml_backend_dev_t?] = [ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil]
            let m: OpaquePointer? = devs.withUnsafeMutableBufferPointer { buf in
                mp.devices = buf.baseAddress
                return llama_model_load_from_file(AudarVoice.ggufURL.path, mp)
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
            cp.offload_kqv = false
            cp.op_offload = false
            guard let c = llama_init_from_model(m, cp) else {
                llama_model_free(m)
                throw SawtError.failed("ما قدرت أجهّز سياق أودار")
            }
            model = m; ctx = c; vocab = llama_model_get_vocab(m); cached = []
            // تحقق: رموز الصوت في مكانها المتوقع
            let check = tokenize("<|speech_0|><|TARGET_CODES_END|>")
            guard check == [Self.speechBase, Self.codesEnd] else {
                unload()
                throw SawtError.failed("مفردات أودار غير متوقعة \(check)")
            }
            slog("audar: llama loaded threads=\(threads) ctx=\(nCtx)")
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

    /// يكتب رموز الصوت لين رمز النهاية. أي رمز غير صوتي نعتبره نهاية.
    private func generateCodes(maxCodes: Int) throws -> [Int] {
        guard let ctx, let vocab else { throw SawtError.notReady("أودار") }
        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        // إعدادات البطاقة الرسمية (repeat 1.1، top_k 40، top_p 0.9) مع حرارة 0.7 لإلقاء أهدأ وأثبت
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1 ... UInt32.max)))
        var codes: [Int] = []
        while codes.count < maxCodes {
            if Task.isCancelled { break }
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
        }
        return codes
    }
    #endif

    /// للمكالمة والقراءة: يرجع العينات بس (فاضي لو فشل)
    func synthesize(_ text: String, voice: String) async -> [Float] {
        switch await synthesizeTimed(text, voice: voice) {
        case .success(let o): return o.samples
        case .failure(let e): slog("audar: synth failed \(e)"); return []
        }
    }

    func synthesizeTimed(_ text: String, voice: String) async -> Result<Output, Error> {
        #if LLAMA
        do {
            guard let ref = AudarRefs.find(voice) ?? AudarRefs.all.first else { throw SawtError.failed("صوت أودار غير معروف") }
            let tl = Date()
            let wasLoaded = isLoaded
            try load()
            let loadS = wasLoaded ? 0 : Date().timeIntervalSince(tl)
            let t0 = Date()
            let fresh = try prefill(Self.prompt(ref: ref, text: text))
            let tp = Date()
            // تقدير سخي لطول الجملة: ~15 رمز لكل حرف كحد أعلى، عشان لو النموذج ما وقف ما يطوّل
            let cap = min(Self.maxCodes, max(150, text.count * 15))
            let codes = try generateCodes(maxCodes: cap)
            let tg = Date()
            guard !codes.isEmpty, let decoder else { throw SawtError.failed("أودار ما طلّع صوت") }
            // المفكك على كرت الشاشة والتطبيق قدّام، وعلى المعالج بالخلفية (Metal ممنوع هناك)
            let gpu = AppPhase.active
            let box = MLXErrBox()
            let samples = try withErrorHandler({ m in box.set(m) }) {
                try Device.withDefaultDevice(gpu ? Device.gpu : Device.cpu) { decoder.decode(codes) }
            }
            if let m = box.message { throw MLXRunError(message: m, cpu: !gpu) }
            MLX.Memory.clearCache()
            let genS = Date().timeIntervalSince(t0)
            let audioS = Double(samples.count) / 24_000
            let tps = Double(codes.count) / max(tg.timeIntervalSince(tp), 0.001)
            slog("audar: \(voice) prefill \(fresh) tok \(Int(tp.timeIntervalSince(t0) * 1000))ms, \(codes.count) codes \(String(format: "%.1f", tps)) tok/s, decode \(Int(Date().timeIntervalSince(tg) * 1000))ms (\(gpu ? "gpu" : "cpu")), audio \(String(format: "%.2f", audioS))s RTF=\(String(format: "%.2f", genS / max(audioS, 0.01))) ram=\(RAM.footprintMB)MB")
            return .success(Output(samples: samples, genSeconds: genS, audioSeconds: audioS, loadSeconds: loadS, tokensPerSecond: tps))
        } catch {
            return .failure(error)
        }
        #else
        return .failure(SawtError.notReady("محرك المعالج ما انبنى في هذي النسخة"))
        #endif
    }
}
