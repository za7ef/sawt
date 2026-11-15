import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import CoreImage
import Tokenizers

/// النموذج اللغوي المحلي (MLX).
actor LLMService {
    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedID: String?
    /// جلسة المكالمة: نحتفظ فيها بين الأدوار عشان ما نعيد معالجة التعليمات والمحادثة كل مرة (كاش KV).
    private var callSession: ChatSession?

    func resetCallSession() { callSession = nil; callTurns = 0 }
    private func keepCallSession(_ s: ChatSession?) { callSession = s; callTurns += 1 }
    /// عدد الأدوار في جلسة المكالمة الحالية؛ بعد حد معيّن نبدأ جلسة جديدة بسجل مختصر عشان الكاش ما يكبر بلا حد.
    private var callTurns = 0
    /// فيه جلسة مكالمة بتنعاد استخدامها في الدور الجاي
    var hasCallSession: Bool { callSession != nil && callTurns < 20 }

    var isReady: Bool { container != nil }
    /// النموذج محمّل بوضع النظر (يقبل صور)
    private(set) var visionLoaded = false

    func unload() {
        container = nil
        loadedID = nil
        warmedID = nil
        callSession = nil
        callTurns = 0
        MLX.Memory.clearCache()
    }

    private var warmedID: String?

    /// تسخين: نولّد كلمة وحدة عشان أول رد في المكالمة يكون أسرع (تجهيز كرت الشاشة والكاش).
    /// مصنّف سريع: هل الرسالة تحتاج تفكير عميق؟ (رموز قليلة جدًا، بدون جلسة)
    func classifyNeedsThinking(_ text: String) async -> Bool {
        let sys = """
        صنّف رسالة المستخدم: إذا تحتاج تفكير أو استنتاج قبل الجواب (لغز، مسألة، منطق، حساب، تخطيط، مقارنة، شرح سبب، برمجة) اكتب THINK.         إذا سؤال بسيط أو معلومة سريعة أو سوالف اكتب NO. اكتب كلمة وحدة بس.
        """
        guard let s = try? stream(system: sys, history: [], user: String(text.prefix(500)), maxTokens: 3) else { return false }
        var out = ""
        do { for try await c in s { out += c } } catch { return false }
        return out.uppercased().contains("THINK")
    }

    /// مصنّف سريع: هل السؤال يحتاج بحث في الويب (معلومة حديثة أو متغيرة)؟
    func classifyNeedsSearch(_ text: String) async -> Bool {
        let sys = """
        هل يحتاج سؤال المستخدم معلومات حديثة أو متغيرة من الإنترنت (أخبار، أسعار، أحداث جارية، مواعيد، نتائج، منتجات جديدة، شيء بعد ٢٠٢٤)؟         إذا نعم اكتب SEARCH، وإذا يكفيه العلم العام اكتب NO. كلمة وحدة بس.
        """
        guard let s = try? stream(system: sys, history: [], user: String(text.prefix(500)), maxTokens: 3) else { return false }
        var out = ""
        do { for try await c in s { out += c } } catch { return false }
        return out.uppercased().contains("SEARCH")
    }

    func warmup(system: String) async {
        guard let id = loadedID, warmedID != id else { return }
        warmedID = id
        let t0 = Date()
        do {
            let s = try stream(system: system, history: [], user: "هلا", maxTokens: 1)
            for try await _ in s {}
            slog("llm: warmup \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch {
            slog("llm: warmup failed \(error)")
        }
    }

    /// اختبار قصير للمعالج: يرجع nil إذا نجح، أو رسالة الخطأ
    /// هل الرد الجاي بيطلع من المعالج (llama.cpp)؟
    static var onCPU: Bool { ComputeMode.device(for: ComputeMode.forced ?? ComputeMode.current) == "cpu" }

    private var lastWarm: (device: String, at: Date)?

    /// تسخين صامت: يحمّل الأوزان ويولّد رمز واحد على تعليمات المحادثة
    /// (كرت الشاشة: يجمّع كيرنلات Metal؛ المعالج: يعبّي كاش البداية في llama)
    func warmUp(reason: String) async {
        let dev = ComputeMode.device(for: ComputeMode.current) ?? "gpu"
        if let w = lastWarm, w.device == dev, Date().timeIntervalSince(w.at) < 120 { return }
        if dev == "gpu" && !AppPhase.active { return }   // Metal ممنوع في الخلفية
        let sys = await MainActor.run { AppSettings.shared.systemPrompt(chat: true, query: "", memory: false) }
        let t0 = Date()
        if dev == "cpu" {
            guard LlamaModelFile.isDownloaded else { return }
            await LlamaEngine.shared.prewarm(system: sys)
        } else {
            guard container != nil else { slog("llm: warm-up skipped (not loaded) \(reason)"); return }
            do {
                let st = try stream(system: sys, history: [], user: ".", maxTokens: 1)
                for try await _ in st {}
            } catch { slog("llm: warm-up failed \(error)"); return }
        }
        lastWarm = (dev, Date())
        slog("llm: warm-up \(dev) (\(reason)) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    func cpuThreadBench() async -> String {
        guard LlamaModelFile.isDownloaded else { return "نموذج المعالج مو منزّل" }
        do { return try await LlamaEngine.shared.benchThreads() } catch { return error.localizedDescription }
    }

    func cpuSelfTest() async -> (ok: Bool, info: String) {
        guard LlamaModelFile.isDownloaded else { return (false, "نموذج المعالج مو منزّل") }
        return await ComputeMode.$forced.withValue("cpu") {
            let t0 = Date()
            do {
                let st = try await self.stream(system: "جاوب بكلمة.", history: [], user: "عرّف نفسك بجملة.", maxTokens: 24)
                var out = ""
                var n = 0
                for try await c in st { out += c; n += 1 }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                slog("llm: cpu self-test ok \(ms)ms out=\(out.prefix(40))")
                return (true, "\(ms)ms، تقريبًا \(String(format: "%.1f", Double(n) / max(Double(ms) / 1000, 0.001))) كلمة/ث")
            } catch {
                slog("llm: cpu self-test failed \(error)")
                return (false, error.localizedDescription)
            }
        }
    }

    /// يُستدعى لما النظام يحذّر من الذاكرة.
    func trim() { MLX.Memory.clearCache() }

    func load(_ option: LLMOption, vision: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedID == option.id, container != nil, visionLoaded == vision { return }
        container = nil
        visionLoaded = false
        MLX.Memory.clearCache()
        // كاش صغير لكرت الشاشة عشان ما تتكدس الذاكرة بين الردود
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        slog("llm: loading \(option.id)")
        var cfg = option.configuration
        // نازل كامل؟ نحمّله من المجلد مباشرة: ولا طلب واحد للإنترنت (حتى فحص النسخة)
        if let local = Storage.llmLocalSnapshot(option.id) {
            cfg.id = .directory(local)
            slog("llm: loading offline from local snapshot")
        }
        // نحدد المصنع بنفسنا: النصي أخف على الذاكرة، والنظر بس لما يحتاجه المستخدم
        let c: ModelContainer
        if vision {
            c = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: cfg,
                progressHandler: { p in progress(p.fractionCompleted) })
        } else {
            c = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: cfg,
                progressHandler: { p in progress(p.fractionCompleted) })
        }
        container = c
        visionLoaded = vision
        slog("llm: loaded vision=\(vision) avail=\(RAM.availableMB)MB")
        loadedID = option.id
        progress(1)
        Task.detached(priority: .utility) { await LLMService.shared.warmUp(reason: "loaded") }
    }

    /// يرجع تدفق نص الرد. السجل يحتوي الرسائل السابقة بدون الرسالة الحالية.
    /// إذا رفض قالب المحادثة (بعض النماذج ما تقبل رسالة النظام)، نعيد المحاولة بدمج التعليمات في رسالة المستخدم.
    func stream(system: String, history: [Chat.Message], user: String, maxTokens: Int = 400, reuse: Bool = false,
                images: [URL] = [], think: Bool = false,
                onThink: (@Sendable (String) -> Void)? = nil) throws -> AsyncThrowingStream<String, Error> {
        // المعالج = llama.cpp (MLX على المعالج ما يطلع شي في iOS)
        if ComputeMode.device(for: ComputeMode.forced ?? ComputeMode.current) == "cpu" {
            slog("llm: cpu → llama.cpp (mlx loaded=\(container != nil) avail=\(RAM.availableMB)MB)")
            callSession = nil; callTurns = 0
            // المعالج أبطأ بكثير: سقف أقل للرد
            let cap = ThermalWatch.isHot ? 200 : 320
            return LlamaEngine.shared.stream(system: system, history: history, user: user,
                                             maxTokens: min(cap, maxTokens))
        }
        guard let container else { throw SawtError.notReady("النموذج اللغوي") }
        var params = GenerateParameters()
        params.maxTokens = ThermalWatch.isHot ? min(200, maxTokens) : maxTokens
        // كاش مضغوط 8 بت بعد أول 1024 رمز (يوفر تقريبًا نص ذاكرة الكاش). ما نستخدم maxKVSize لأن
        // الكاش الدوّار ما يقبل الضغط ويحذف التعليمات؛ طول السياق محدود من عندنا (ميزانية السجل وإعادة الجلسة).
        params.maxKVSize = nil
        params.kvBits = 8
        params.quantizedKVStart = 1024
        params.temperature = 0.7
        params.topP = 0.9
        // وضع التفكير موجود بس في عائلة Qwen3 (ومنها Qwen3.5)، مو Qwen2.5
        let isQwen3 = (loadedID ?? "").lowercased().contains("qwen3")
        // تفكير عميق: Qwen3 يفكر بنفسه؛ الباقي نطلب منه يفكر داخل <think>. بدونه نقفل تفكير Qwen عشان السرعة.
        let reasoning = "\n\nقبل الجواب فكّر خطوة بخطوة بينك وبين نفسك داخل <think> و</think>، بعدين اكتب الجواب النهائي بعدها مباشرة."
        let sys = isQwen3 ? (think ? system : system + "\n/no_think") : (think ? system + reasoning : system)
        let ctx: [String: any Sendable]? = isQwen3 ? ["enable_thinking": think] : nil

        // المحاولة الأولى: رسالة نظام عادية. الثانية: بدون رسالة نظام وبتناوب صارم.
        var attempts: [() -> (ChatSession, String)] = [
            {
                (ChatSession(container, instructions: sys, history: history, generateParameters: params,
                             additionalContext: ctx), user)
            },
            {
                let merged = Self.strictAlternation(history)
                let first = merged.isEmpty
                    ? "تعليمات: \(sys)\n\n\(user)"
                    : user
                var hist = merged
                if !hist.isEmpty, case .user = hist[0].role {
                    hist[0] = .user("تعليمات: \(sys)\n\n" + hist[0].content)
                }
                return (ChatSession(container, instructions: nil, history: hist, generateParameters: params,
                                    additionalContext: ctx), first)
            },
        ]

        if reuse, callTurns >= 20 {
            slog("llm: call session long (\(callTurns) turns) → fresh session with trimmed history")
            callSession = nil; callTurns = 0
        }
        if reuse, let existing = callSession {
            existing.generateParameters = params
            attempts.insert({ (existing, user) }, at: 0)
            slog("llm: reusing call session (kv cache)")
        }
        let hadSession = callSession != nil
        callSession = nil   // ترجع بس إذا خلص الدور بنجاح
        // جلسة جديدة (أو انفقدت بعد خطأ/مقاطعة) = العداد يبدأ من الصفر
        if !reuse || !hadSession { callTurns = 0 }

        let maxTok = params.maxTokens ?? 400
        return AsyncThrowingStream { cont in
            // أولوية userInitiated (مو background) عشان المعالج يشتغل بسرعة في الخلفية والمايك مفتوح
            let task = Task(priority: .userInitiated) {
                let mode = ComputeMode.forced ?? ComputeMode.current
                var dev = ComputeMode.device(for: mode)
                if dev == nil {
                    // كرت الشاشة ممنوع في الخلفية: نوقف بدل ما يطيح التطبيق
                    slog("llm: paused (background, gpu-only)")
                    cont.finish(throwing: BackgroundPause())
                    return
                }
                var anyYielded = false
                var round = 0
                while true {
                    round += 1
                    let useCPU = dev == "cpu"
                    var interrupted = false
                    var lastError: Error?
                    var finished = false
                    let t0 = Date()
                    var chunks = 0
                    // أخطاء MLX (مثل عملية ما لها نسخة على المعالج) ترجع خطأ بدل ما تطيّح التطبيق
                    let mlxErr = MLXErrBox()
                    await withErrorHandler({ m in mlxErr.set(m) }) {
                    // دوال compile تحتاج مُترجم JIT للمعالج وهو مو موجود في iOS → نطفيها على المعالج
                    MLX.compile(enable: !useCPU)
                    await Device.withDefaultDevice(useCPU ? Device.cpu : Device.gpu) {
                for (i, make) in attempts.enumerated() {
                    let (session, prompt) = make()
                    var yielded = false
                    // بعض قوالب Qwen تفتح <think> بنفسها في البرومبت: نعتبر البداية تفكير من أول حرف (بدون وميض)
                    var inThink = think && isQwen3
                    var pendingTag = ""
                    do {
                        let imgs: [UserInput.Image] = images.compactMap { u in CIImage(contentsOf: u).map { .ciImage($0) } }
                        for try await chunk in session.streamResponse(to: prompt, images: imgs) {
                            if Task.isCancelled { break }
                            // التطبيق راح للخلفية وإحنا على كرت الشاشة: نوقف قبل ما يرفض النظام الشغل
                            if !useCPU && !AppPhase.active { interrupted = true; break }
                            if mlxErr.message != nil { break }
                            chunks += 1
                            var text = pendingTag + chunk
                            pendingTag = ""
                            var visible = ""
                            while !text.isEmpty {
                                if inThink {
                                    if let r = text.range(of: "<think>") { text.removeSubrange(r) }
                                    if let r = text.range(of: "</think>") {
                                        onThink?(String(text[..<r.lowerBound]))
                                        text = String(text[r.upperBound...]); inThink = false
                                    } else if let lt = text.lastIndex(of: "<"), text[lt...].count < 9 {
                                        onThink?(String(text[..<lt])); pendingTag = String(text[lt...]); text = ""; break
                                    } else { onThink?(text); text = ""; break }
                                } else if let r = text.range(of: "<think>") {
                                    visible += text[..<r.lowerBound]
                                    text = String(text[r.upperBound...]); inThink = true
                                } else if let lt = text.lastIndex(of: "<"), text[lt...].count < 8 {
                                    visible += text[..<lt]; pendingTag = String(text[lt...]); text = ""
                                } else {
                                    visible += text; text = ""
                                }
                            }
                            if !visible.isEmpty { yielded = true; anyYielded = true; cont.yield(visible) }
                            else if inThink { cont.yield("") }   // نبّه الواجهة تحدّث التفكير
                        }
                        if interrupted { return }
                        if !pendingTag.isEmpty, !inThink { cont.yield(pendingTag) }
                        withExtendedLifetime(session) {}
                        // نحتفظ بالجلسة بس إذا الرد كمل (لو انقطع، كاشها مو مضمون)
                        if reuse, !Task.isCancelled { await self.keepCallSession(session) }
                        finished = true
                        return
                    } catch {
                        lastError = error
                        if yielded || Task.isCancelled || i == attempts.count - 1 { break }
                    }
                }
                    }
                    }
                    let dt = Date().timeIntervalSince(t0)
                    if let m = mlxErr.message {
                        slog("llm: mlx error device=\(useCPU ? "cpu" : "gpu"): \(m)")
                        if useCPU { ComputeMode.cpuError = m }
                        MLX.Memory.clearCache()
                        // تلقائي والمعالج فشل وإحنا قدّام: نرجع لكرت الشاشة
                        if useCPU, mode == "auto", AppPhase.active, !anyYielded, round == 1, !Task.isCancelled {
                            dev = "gpu"
                            continue
                        }
                        cont.finish(throwing: MLXRunError(message: m, cpu: useCPU))
                        return
                    }
                    if chunks > 1 {
                        slog("llm: device=\(useCPU ? "cpu" : "gpu") \(chunks) tok in \(Int(dt * 1000))ms ≈ \(String(format: "%.1f", Double(chunks) / max(dt, 0.001))) tok/s")
                    }
                    MLX.Memory.clearCache()
                    if finished { cont.finish(); return }
                    if interrupted {
                        // تلقائي وما طلع شي: نعيد الدور على المعالج
                        if mode == "auto", !anyYielded, round == 1, !Task.isCancelled {
                            slog("llm: background → retry on cpu (llama.cpp)")
                            do {
                                for try await c in LlamaEngine.shared.stream(system: system, history: history, user: user,
                                                                             maxTokens: maxTok) {
                                    cont.yield(c)
                                }
                                cont.finish()
                            } catch { cont.finish(throwing: error) }
                            return
                        }
                        slog("llm: interrupted (background)")
                        cont.finish(throwing: BackgroundPause())
                        return
                    }
                    cont.finish(throwing: SawtError.friendly(lastError))
                    return
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// يدمج الرسائل المتتالية من نفس الطرف ويبدأ بالمستخدم.
    static func strictAlternation(_ msgs: [Chat.Message]) -> [Chat.Message] {
        var out: [Chat.Message] = []
        for m in msgs {
            switch m.role {
            case .user, .assistant:
                if let last = out.last, last.role == m.role {
                    out[out.count - 1] = last.role == .user ? .user(last.content + "\n" + m.content)
                                                           : .assistant(last.content + "\n" + m.content)
                } else {
                    out.append(m)
                }
            default: continue
            }
        }
        if let f = out.first, f.role == .assistant { out.removeFirst() }
        if let l = out.last, l.role == .user { out.removeLast() }
        return out
    }
}


/// طريقة تشغيل النموذج: "gpu" كرت الشاشة، "cpu" المعالج، "auto" كرت الشاشة قدّام والمعالج في الخلفية
enum ComputeMode {
    /// لاختبار جهاز معيّن (اختبار المعالج من الإعدادات)
    @TaskLocal static var forced: String?
    /// آخر خطأ من MLX على المعالج (يطلع في الإعدادات)
    nonisolated(unsafe) static var cpuError: String?
    static var current: String { UserDefaults.standard.string(forKey: "llmDevice") ?? "gpu" }
    /// nil = ممنوع الحين (كرت الشاشة بس والتطبيق في الخلفية)
    static func device(for mode: String) -> String? {
        switch mode {
        case "cpu": return "cpu"
        case "auto": return AppPhase.active ? "gpu" : "cpu"
        default: return AppPhase.active ? "gpu" : nil
        }
    }
}

/// حالة التطبيق (قدّام/خلفية) يقراها أي خيط
enum AppPhase {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _active = true
    static var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
}

struct BackgroundPause: LocalizedError {
    var errorDescription: String? { "افتح التطبيق عشان أكمل" }
}

final class MLXErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _m: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return _m }
    func set(_ m: String) { lock.lock(); if _m == nil { _m = m }; lock.unlock() }
}

struct MLXRunError: LocalizedError {
    var message: String
    var cpu: Bool
    var errorDescription: String? {
        cpu ? "النموذج ما اشتغل على المعالج: \(message.prefix(160)). رجّع «تشغيل النموذج» لكرت الشاشة."
            : "صار خطأ في النموذج: \(message.prefix(160))"
    }
}
