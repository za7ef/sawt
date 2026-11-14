import Foundation
import MLXLLM
import MLXLMCommon

/// نموذج لغوي متاح للتنزيل (MLX بدقة 4 بت).
struct LLMOption: Identifiable, Hashable {
    let id: String          // معرّف المستودع في Hugging Face
    let title: String
    let sizeGB: Double      // حجم التنزيل
    let ramGB: Double       // الذاكرة المطلوبة تقريبًا
    let speed: String
    let arabic: String
    var tag: String? = nil
    var custom = false
    /// يقدر يشوف الصور (عن طريق MLXVLM)
    var vision = false

    var configuration: ModelConfiguration { LLMRegistry.shared.configuration(id: id) }
    var sizeText: String { sizeGB < 1 ? "\(Int(sizeGB * 1000)) MB" : String(format: "%.1f GB", sizeGB) }
}

/// نموذج تحويل الكلام إلى نص.
struct STTOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let approxSize: String
}

/// صوت مدمج داخل التطبيق.
struct VoiceOption: Identifiable, Hashable {
    enum Kind: Hashable { case piper(onnx: String), kokoro(model: String), apple, namaa }
    let id: String
    let title: String
    let subtitle: String
    let folder: String
    let kind: Kind
}

enum Catalog {
    /// كل الأحجام متحقق منها من Hugging Face (نوفمبر 2026).
    static let builtInLLMs: [LLMOption] = [
        LLMOption(id: "mlx-community/Qwen3.5-2B-4bit", title: "Qwen3.5 2B", sizeGB: 1.72, ramGB: 2.4,
                  speed: "سريع جدًا", arabic: "عربي جيد", tag: "الأسرع والأخف", vision: true),
        LLMOption(id: "mlx-community/Qwen3-4B-4bit", title: "Qwen3 4B", sizeGB: 2.26, ramGB: 3.0,
                  speed: "سريع", arabic: "عربي ممتاز ولهجات زينة", tag: "عربي أحسن • للمكالمات مع سمع آبل"),
        LLMOption(id: "mlx-community/Qwen3.5-4B-4bit", title: "Qwen3.5 4B", sizeGB: 3.03, ramGB: 3.8,
                  speed: "متوسط", arabic: "عربي ممتاز", tag: "الأحدث", vision: true),
        LLMOption(id: "mlx-community/gemma-3-4b-it-qat-4bit", title: "Gemma 3 4B", sizeGB: 3.0, ramGB: 3.8,
                  speed: "متوسط", arabic: "عربي ممتاز وأسلوب طبيعي", vision: true),
        LLMOption(id: "mlx-community/gemma-4-e2b-it-4bit", title: "Gemma 4 E2B", sizeGB: 3.55, ramGB: 3.5,
                  speed: "متوسط", arabic: "عربي ممتاز", vision: true),
        LLMOption(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", title: "Qwen2.5 3B", sizeGB: 1.74, ramGB: 2.4,
                  speed: "سريع", arabic: "عربي جيد"),
        LLMOption(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", title: "Llama 3.2 3B", sizeGB: 1.81, ramGB: 2.5,
                  speed: "سريع", arabic: "عربي مقبول"),
        LLMOption(id: "mlx-community/Phi-4-mini-instruct-4bit", title: "Phi-4 Mini", sizeGB: 2.16, ramGB: 2.9,
                  speed: "سريع", arabic: "عربي ضعيف، إنجليزي قوي"),
        LLMOption(id: "mlx-community/SmolLM3-3B-4bit", title: "SmolLM3 3B", sizeGB: 1.73, ramGB: 2.4,
                  speed: "سريع", arabic: "عربي ضعيف"),
        LLMOption(id: "mlx-community/Qwen3-1.7B-4bit", title: "Qwen3 1.7B", sizeGB: 0.97, ramGB: 1.5,
                  speed: "سريع جدًا", arabic: "عربي مقبول"),
        LLMOption(id: "mlx-community/gemma-3-1b-it-qat-4bit", title: "Gemma 3 1B", sizeGB: 0.73, ramGB: 1.2,
                  speed: "سريع جدًا", arabic: "عربي مقبول"),
        LLMOption(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", title: "Llama 3.2 1B", sizeGB: 0.7, ramGB: 1.2,
                  speed: "سريع جدًا", arabic: "عربي ضعيف"),
        LLMOption(id: "mlx-community/Qwen3-0.6B-4bit", title: "Qwen3 0.6B", sizeGB: 0.34, ramGB: 0.8,
                  speed: "لحظي", arabic: "للتجربة فقط"),
    ]

    static var customLLMs: [LLMOption] {
        (UserDefaults.standard.stringArray(forKey: "customLLMs") ?? []).map {
            LLMOption(id: $0, title: String($0.split(separator: "/").last ?? Substring($0)), sizeGB: 0, ramGB: 0,
                      speed: "؟", arabic: "نموذج مخصص", custom: true)
        }
    }

    static var llms: [LLMOption] { builtInLLMs + customLLMs }

    static func addCustom(_ repo: String) {
        var list = UserDefaults.standard.stringArray(forKey: "customLLMs") ?? []
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.contains("/"), !list.contains(r), !builtInLLMs.contains(where: { $0.id == r }) else { return }
        list.append(r)
        UserDefaults.standard.set(list, forKey: "customLLMs")
    }

    static func removeCustom(_ repo: String) {
        var list = UserDefaults.standard.stringArray(forKey: "customLLMs") ?? []
        list.removeAll { $0 == repo }
        UserDefaults.standard.set(list, forKey: "customLLMs")
    }

    static let stts: [STTOption] = [
        STTOption(id: "apple", title: "سمع آبل",
                  subtitle: "موصى به للمكالمات: ما ياخذ ذاكرة، فيخلي مكان لنموذج أذكى", approxSize: "0 MB"),
        STTOption(id: "small", title: "Whisper Small",
                  subtitle: "يشتغل بدون آبل، ياخذ ذاكرة متوسطة", approxSize: "~220 MB"),
        STTOption(id: "large-v3-v20240930_626MB", title: "Whisper Large v3 Turbo",
                  subtitle: "أفضل فهم للعربي لكنه ثقيل ويسخّن", approxSize: "~630 MB"),
    ]

    /// الأصوات المدمجة. يُتجاهل أي صوت ملفاته غير موجودة في الحزمة.
    static let allVoices: [VoiceOption] = [
        VoiceOption(id: "nabra-saudi", title: "نبرة سعودية",
                    subtitle: "صوت أنثوي طبيعي باللهجة السعودية، المقترح للمكالمات", folder: "nabra-saudi",
                    kind: .kokoro(model: "model.int8.onnx")),
        VoiceOption(id: "nabra-msa", title: "نبرة فصحى",
                    subtitle: "صوت أنثوي طبيعي بالفصحى", folder: "nabra-msa",
                    kind: .kokoro(model: "model.int8.onnx")),
        VoiceOption(id: "piper-miro", title: "ميرو",
                    subtitle: "صوت بلكنة سعودية، سريع جدًا", folder: "piper-miro",
                    kind: .piper(onnx: "ar_JO-SA_miro_V2-high.onnx")),
        VoiceOption(id: "apple", title: "صوت آبل",
                    subtitle: "أصوات النظام، تشتغل دايم", folder: "", kind: .apple),
        VoiceOption(id: "namaa", title: "نماء سعودي (تجريبي)",
                    subtitle: "صوت رجّالي سعودي، ثقيل وياخذ وقت قبل كل جملة في المكالمة", folder: "", kind: .namaa),
    ]

    static var namaaVoice: VoiceOption? { allVoices.first { $0.kind == .namaa } }

    static var voicesRoot: URL? { Bundle.main.url(forResource: "Voices", withExtension: nil) }

    static var voices: [VoiceOption] {
        allVoices.filter { v in
            switch v.kind {
            case .apple: return true
            case .namaa: return NamaaVoice.isInstalled
            case .piper(let onnx): return exists("\(v.folder)/\(onnx)")
            case .kokoro(let model): return exists("\(v.folder)/\(model)")
            }
        }
    }

    /// مجلد الصوت: داخل التطبيق إذا مدمج، وإلا اللي نزل على الجوال.
    static func voiceDir(_ folder: String) -> URL {
        if let root = voicesRoot {
            let d = root.appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: d.path) { return d }
        }
        return VoiceDownloads.root.appendingPathComponent(folder)
    }

    static func exists(_ rel: String) -> Bool {
        if let root = voicesRoot, FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) { return true }
        return FileManager.default.fileExists(atPath: VoiceDownloads.root.appendingPathComponent(rel).path)
    }
}

/// إعدادات المستخدم المحفوظة.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var llmID: String { didSet { d.set(llmID, forKey: "llmID") } }
    @Published var sttID: String { didSet { d.set(sttID, forKey: "sttID") } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var persona: String { didSet { d.set(persona, forKey: "persona") } }
    @Published var patience: Double { didSet { d.set(patience, forKey: "patience") } }
    /// اختياري ومحفوظ على الجهاز بس.
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    /// "m" مذكر، "f" مؤنث، "" بدون تحديد
    @Published var addressForm: String { didSet { d.set(addressForm, forKey: "addressForm") } }

    private let d = UserDefaults.standard

    static let defaultPersona = """
    أنت «صوت»، مساعد ذكي يشتغل على جوال المستخدم بدون إنترنت. تتكلم معه في مكالمة صوتية مباشرة.
    تكلّم بالعربي بلهجة بيضاء طبيعية إذا كلمك بالعربي، وبالإنجليزي إذا كلمك بالإنجليزي.
    ردودك قصيرة وطبيعية كأنك صاحبه تتكلم مو تكتب: جملة إلى ثلاث جمل غالبًا.
    نوّع كلامك ولا تكرر نفس العبارات أو نفس بداية الرد، ولا تعيد سؤاله عليه.
    جاوب على اللي قاله مباشرة. إذا ما فهمت كلامه (ممكن التمييز غلط) اسأله يعيد باختصار.
    لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.
    اكتب الأرقام بالحروف إذا كانت قليلة.
    """

    /// التعليمات الكاملة وقت التشغيل: الشخصية + الاسم وصيغة المخاطبة (إذا محددة) + الذاكرة.
    func systemPrompt(chat: Bool, query: String, memory: Bool = true) -> String {
        // الوصف القديم "بدون إنترنت" مو دقيق مع البحث في الويب
        var s = persona.replacingOccurrences(of: "يشتغل على جوال المستخدم بدون إنترنت", with: "يشتغل على جوال المستخدم")
        // شخصية أساسية وحدة للدردشة والمكالمة (نفس المحتوى والدقة)، والمكالمة تضيف بس أسلوب الكلام
        s = s.replacingOccurrences(of: "تتكلم معه في مكالمة صوتية مباشرة.", with: chat ? "تكلمه في دردشة كتابية." : "تكلمه الحين في مكالمة صوتية مباشرة.")
        s = s.replacingOccurrences(of: "ردودك قصيرة وطبيعية كأنك صاحبه تتكلم مو تكتب: جملة إلى ثلاث جمل غالبًا.",
                                   with: "ردودك واضحة ومباشرة، قصيرة إذا السؤال بسيط.")
        if chat {
            s = s.replacingOccurrences(of: "لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.",
                                       with: "في الدردشة تقدر تستخدم قوائم وتنسيق Markdown وكود إذا يفيد، وطوّل إذا السؤال يحتاج.")
        } else {
            s = s.replacingOccurrences(of: "لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.", with: "")
            s += """

            أسلوب المكالمة: فكّر في نفس الجواب اللي كنت بتكتبه في الدردشة بنفس الدقة والمعلومات، وقله ملخّص للكلام:             جملتين إلى أربع جمل تغطي النقاط الأساسية بدون ما تغيّر المضمون. إذا طلب تفصيل أو قال كمّل، طوّل.             بدون قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.
            """
        }
        if chat {
            s = s.replacingOccurrences(of: "اكتب الأرقام بالحروف إذا كانت قليلة.", with: "اكتب الأرقام والتواريخ بالأرقام (مثل 3 يناير 2026).")
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ar@numbers=latn")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "EEEE d MMMM yyyy"
        let today = df.string(from: Date())
        var extra: [String] = ["تاريخ اليوم: \(today) (ميلادي). أي تاريخ قبله صار ماضي؛ لا تتكلم عنه كأنه جاي.",
                               "لهجتك عامية سعودية بيضاء مو فصحى (إلا إذا كلمك بالإنجليزي أو طلب الفصحى). مثال: بدل «أنا بخير، شكراً لسؤالك» قل «الحمدلله تمام، وأنت كيفك؟».",
                               "حاول تجاوب أول دايمًا. لا ترد بأسئلة كثيرة: سؤال توضيحي واحد بالكثير، وبس إذا ما تقدر تجاوب بدونه. إذا كان لغز أو مسألة، فكّر وحلّها وقل الجواب."]
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { extra.append("اسم المستخدم: \(name).") }
        switch addressForm {
        case "m": extra.append("خاطب المستخدم بصيغة المذكر.")
        case "f": extra.append("خاطب المستخدم بصيغة المؤنث.")
        default: break
        }
        if !extra.isEmpty { s += "\n" + extra.joined(separator: "\n") }
        if memory {
            let mem = MemoryStore.promptBlock(for: query)
            if !mem.isEmpty { s += "\n\n" + mem }
        }
        return s
    }

    private init() {
        llmID = d.string(forKey: "llmID") ?? Catalog.llms[0].id
        if !d.bool(forKey: "migratedAppleSTT") {
            // من بناء 34: سمع آبل افتراضي (ما ياخذ ذاكرة) عشان النماذج الأذكى تكفي بالمكالمة
            d.set(true, forKey: "migratedAppleSTT")
            d.set(true, forKey: "migratedLightDefaults")
            d.removeObject(forKey: "sttID")
        }
        if !d.bool(forKey: "migratedLightDefaults") {
            // من بناء 13: الافتراضي أخف عشان الذاكرة والحرارة
            d.set(true, forKey: "migratedLightDefaults")
            d.removeObject(forKey: "sttID")
        }
        sttID = d.string(forKey: "sttID") ?? Catalog.stts[0].id
        voiceID = d.string(forKey: "voiceID") ?? (Catalog.voices.first?.id ?? "apple")
        speechRate = d.object(forKey: "speechRate") as? Double ?? 1.0
        language = d.string(forKey: "language") ?? "auto"
        if let p = d.string(forKey: "persona"), !p.contains("صوت»، مساعد ذكي") || p == AppSettings.defaultPersona {
            persona = p
        } else {
            // ترقية أي شخصية افتراضية قديمة (كانت فيها معلومات شخصية) للعامة الجديدة
            persona = AppSettings.defaultPersona
            d.set(AppSettings.defaultPersona, forKey: "persona")
        }
        userName = d.string(forKey: "userName") ?? ""
        addressForm = d.string(forKey: "addressForm") ?? ""
        patience = d.object(forKey: "patience") as? Double ?? 0.7
    }

    var llm: LLMOption { Catalog.llms.first { $0.id == llmID } ?? Catalog.llms[0] }
    var stt: STTOption { Catalog.stts.first { $0.id == sttID } ?? Catalog.stts[0] }
    var voice: VoiceOption { Catalog.voices.first { $0.id == voiceID } ?? Catalog.voices.first { $0.kind == .apple }! }
}
