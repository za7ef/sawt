import Foundation

/// مكان تشغيل النماذج أثناء المكالمة: كرت الشاشة أو المعالج أو تلقائي.
/// نموذج الدردشة: كرت الشاشة = نسخة MLX، المعالج = نسخة GGUF (llama.cpp) من نفس النموذج.
/// نموذج الصوت (أودار): نفس الملف يشتغل على كرت الشاشة أو المعالج.
enum Placement {
    static let chatKey = "callChatDevice"     // auto | gpu | cpu (غير محدد = يتبع اختيار صفحة النماذج)
    static let voiceKey = "callVoiceDevice"   // auto | gpu | cpu

    /// نسخ متقابلة: نموذج MLX ↔ نموذج GGUF
    static let pairs: [String: String] = [
        "mlx-community/gemma-4-e2b-it-4bit": "gemma",
        "mlx-community/Qwen3.5-2B-4bit": "qwen2b",
        "mlx-community/Qwen3.5-4B-4bit": "qwen",
    ]

    static var chatChoice: String {
        get { UserDefaults.standard.string(forKey: chatKey) ?? ComputeMode.current }
        set { UserDefaults.standard.set(newValue, forKey: chatKey); slog("placement: chat → \(newValue)") }
    }
    static var voiceChoice: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey); slog("placement: voice → \(newValue)") }
    }

    /// نسختا نموذج الدردشة الحالي (أيهما ممكن يكون nil إذا ما له نسخة مقابلة)
    @MainActor static func family() -> (mlx: LLMOption?, gguf: GGUFSpec?) {
        if ComputeMode.current == "cpu" {
            let g = GGUFSpec.active
            return (Catalog.llms.first { pairs[$0.id] == g.id }, g)
        }
        let m = AppSettings.shared.llm
        return (m, pairs[m.id].flatMap { id in GGUFSpec.all.first { $0.id == id } })
    }

    @MainActor static func gpuReady(_ f: (mlx: LLMOption?, gguf: GGUFSpec?)) -> Bool {
        guard let m = f.mlx else { return false }
        return ModelManager.shared.downloaded.contains(m.id) || Storage.llmLocalSnapshot(m.id) != nil
    }
    static func cpuReady(_ f: (mlx: LLMOption?, gguf: GGUFSpec?)) -> Bool { f.gguf?.isDownloaded ?? false }

    /// أين يشتغل نموذج الدردشة في هذا الدور. voiceSlow: أودار أبطأ من الوقت الحقيقي على كرت الشاشة.
    @MainActor static func chatDevice(needsVision: Bool, voiceSlow: Bool) -> String {
        let f = family()
        let g = gpuReady(f), c = cpuReady(f)
        let pick: String
        switch chatChoice {
        case "gpu": pick = g ? "gpu" : (c ? "cpu" : ComputeMode.current)
        case "cpu": pick = (c && !needsVision) ? "cpu" : (g ? "gpu" : "cpu")
        default:
            if !(g && c) { pick = ComputeMode.current }
            else if needsVision { pick = "gpu" }                       // النظر على كرت الشاشة بس
            else if ThermalWatch.isHot || voiceSlow { pick = "cpu" }   // نخلي كرت الشاشة للصوت
            else { pick = "gpu" }
        }
        return pick
    }

    /// أودار على كرت الشاشة؟ (في الخلفية دايمًا المعالج)
    static var voiceGPU: Bool {
        guard AppPhase.active else { return false }
        switch voiceChoice {
        case "cpu": return false
        case "gpu": return true
        default: return !lowPower   // تلقائي: كرت الشاشة أسرع بكثير؛ المعالج بس لو الجهاز حار جدًا
        }
    }
    private static var lowPower: Bool { ProcessInfo.processInfo.thermalState == .critical }

    // MARK: الحالة الحية (للوحة التشخيص)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _chat = "—"
    nonisolated(unsafe) private static var _voice = "—"
    static var chatNow: String {
        get { lock.lock(); defer { lock.unlock() }; return _chat }
        set { lock.lock(); _chat = newValue; lock.unlock() }
    }
    static var voiceNow: String {
        get { lock.lock(); defer { lock.unlock() }; return _voice }
        set { lock.lock(); _voice = newValue; lock.unlock() }
    }
    /// «الدردشة: GPU · الصوت: CPU»
    static var liveLabel: String { L("الدردشة: %1$@ · الصوت: %2$@", chatNow, voiceNow) }
}
