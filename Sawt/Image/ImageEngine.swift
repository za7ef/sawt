import Foundation
import CoreML
import CoreGraphics
import Compression
import UIKit
import ImagePlayground
import StableDiffusion

/// محركات توليد الصور. المستخدم يختار واحد، وما نبدّل لغيره تلقائيًا أبدًا.
enum ImageEngine: String, CaseIterable, Identifiable {
    case sdReal, sdArt, klein, playground, gemini, geminiLite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sdReal: "واقعي — CyberRealistic"
        case .sdArt: "فني — DreamShaper 8"
        case .klein: "دقيق"
        case .playground: "Image Playground"
        case .gemini: "Gemini 3.1 Flash Image"
        case .geminiLite: "Gemini 3.1 Flash Lite Image"
        }
    }

    /// وصف قصير يطلع في القائمة
    var tag: String {
        switch self {
        case .sdReal, .sdArt, .klein: "محلي"
        case .playground: "سحابة آبل الخاصة"
        case .gemini, .geminiLite: "سحابي · مدفوع"
        }
    }

    var isLocalSD: Bool { self == .sdReal || self == .sdArt }
    /// يرسم على الجوال (يحتاج تنزيل، ونفك نموذج المحادثة وقت الرسم)
    var isLocal: Bool { isLocalSD || self == .klein }
    var isGemini: Bool { self == .gemini || self == .geminiLite }

    var geminiModel: String { self == .geminiLite ? "gemini-3.1-flash-lite-image" : "gemini-3.1-flash-image" }

    /// المحرك المختار (nil = ما اختار للحين)
    static var selected: ImageEngine? {
        get { UserDefaults.standard.string(forKey: "imageEngine").flatMap(ImageEngine.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: "imageEngine") }
    }

    /// محركات انشالت (SD 2.1 وSD-Turbo): لو كان واحد منها مختار يصير «ما اخترت» مع تنبيه في الإعدادات،
    /// وملفاتها القديمة تنحذف مرة وحدة عشان ما تبقى تاخذ مساحة بدون ما تبان
    static func migrate() {
        let d = UserDefaults.standard
        if let cur = d.string(forKey: "imageEngine"), !cur.isEmpty, ImageEngine(rawValue: cur) == nil {
            d.set("", forKey: "imageEngine")
            d.set(true, forKey: "imageEngineRetired")
        }
        d.removeObject(forKey: "sd21Retired")
        guard !d.bool(forKey: "retiredImageFilesCleaned") else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImageModels", isDirectory: true)
            for name in ["sd21", "sd21.partial", "sdTurbo", "sdTurbo.partial"] {
                let u = root.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: u.path) {
                    try? fm.removeItem(at: u)
                    slog("image: removed retired files \(name)")
                }
            }
            UserDefaults.standard.set(true, forKey: "retiredImageFilesCleaned")
        }
    }
}

/// صورة جاهزة: الملف المحفوظ + البرومبت المستخدم
struct GeneratedImage {
    let file: String
    let prompt: String
    let engine: ImageEngine
}

// MARK: - تنزيل نماذج Stable Diffusion

@MainActor
final class SDModels: ObservableObject {
    static let shared = SDModels()

    enum State: Equatable { case idle, downloading(Double), failed(String) }
    @Published var state: [ImageEngine: State] = [:]
    private var tasks: [ImageEngine: Task<Void, Never>] = [:]

    /// الملفات اللي يحتاجها توليد صورة من نص (بدون VAEEncoder وSafetyChecker)
    nonisolated static let needed: [String] = {
        var f: [String] = []
        for m in ["TextEncoder", "Unet", "VAEDecoder"] {
            for p in ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"] {
                f.append("\(m).mlmodelc/\(p)")
            }
        }
        return f + ["vocab.json", "merges.txt"]
    }()

    nonisolated static func dir(_ e: ImageEngine) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageModels/\(e.rawValue)", isDirectory: true)
        return d
    }

    /// ملفات كل محرك محلي
    nonisolated static func files(_ e: ImageEngine) -> [String] {
        e == .klein ? Klein.files.map(\.path) : needed
    }

    nonisolated static func installed(_ e: ImageEngine) -> Bool {
        guard e.isLocal else { return false }
        let d = dir(e)
        return files(e).allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) }
    }

    nonisolated static func approxGB(_ e: ImageEngine) -> Double {
        switch e {
        case .sdReal: 0.89
        case .klein: 3.9
        default: 0.99
        }
    }

    func download(_ e: ImageEngine) {
        guard e.isLocal, tasks[e] == nil else { return }
        state[e] = .downloading(0)
        tasks[e] = Task {
            Storage.otherDownloads += 1
            defer { Storage.otherDownloads -= 1; tasks[e] = nil }
            if let why = Storage.spaceProblem(forGB: Self.approxGB(e) + 0.3) { state[e] = .failed(why); return }
            guard await NetworkGate.shared.permit("تنزيل نموذج الصور \(e.title)") else { state[e] = .idle; return }
            let d = Self.dir(e)
            let tmp = d.deletingLastPathComponent().appendingPathComponent(e.rawValue + ".partial", isDirectory: true)
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                var u = d.deletingLastPathComponent(); var v = URLResourceValues(); v.isExcludedFromBackup = true
                try? u.setResourceValues(v)
                let report: @Sendable (Double) -> Void = { p in Task { @MainActor in SDModels.shared.state[e] = .downloading(p) } }
                guard let src = Self.source(e) else { throw SawtError.failed("ما فيه مصدر لهالنموذج") }
                try await Self.fetchFiles(src, files: Self.files(e), into: tmp, progress: report)
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: d)
                try FileManager.default.moveItem(at: tmp, to: d)
                state[e] = .idle
                slog("image: downloaded \(e.rawValue)")
                objectWillChange.send()
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                state[e] = error is CancellationError ? .idle : .failed(SawtError.friendly(error).localizedDescription)
                slog("image: download failed \(e.rawValue) \(error)")
            }
        }
    }

    func cancel(_ e: ImageEngine) {
        tasks[e]?.cancel()
    }

    func delete(_ e: ImageEngine) {
        tasks[e]?.cancel()
        try? FileManager.default.removeItem(at: Self.dir(e))
        state[e] = .idle
        objectWillChange.send()
        slog("image: deleted \(e.rawValue)")
    }

    /// مصدر الملفات المنفصلة: الرابط الأساسي + أحجام الأوزان بالميقا (لشريط التقدم)
    struct Source: Sendable { let base: String; let weights: [String: Double] }

    // نسخ LocalMuseAI (Core ML، ‏6-bit، ‏split_einsum_v2، ‏512×512، الـUnet بدفعة 2): الملفات منفصلة في المستودع
    nonisolated static func source(_ e: ImageEngine) -> Source? {
        switch e {
        case .sdReal:
            Source(base: "https://huggingface.co/LocalMuseAI/coreml-cyberrealistic-final-lcm-6bit/resolve/main/",
                   weights: ["TextEncoder.mlmodelc/weights/weight.bin": 140, "Unet.mlmodelc/weights/weight.bin": 645,
                             "VAEDecoder.mlmodelc/weights/weight.bin": 99])
        case .sdArt:
            Source(base: "https://huggingface.co/LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2/resolve/main/",
                   weights: ["TextEncoder.mlmodelc/weights/weight.bin": 246, "Unet.mlmodelc/weights/weight.bin": 645,
                             "VAEDecoder.mlmodelc/weights/weight.bin": 99])
        case .klein:
            // Bonsai Image (PrismML): FLUX.2 Klein 4B بأوزان ثلاثية 2-bit + Qwen3-4B بـ4 بت (MLX)
            Source(base: Klein.base, weights: Dictionary(uniqueKeysWithValues: Klein.files.map { ($0.path, $0.mb) }))
        default: nil
        }
    }

    nonisolated private static func fetchFiles(_ src: Source, files: [String], into d: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // الأحجام التقريبية عشان شريط التقدم (الأوزان هي الثقيلة)
        let weights = src.weights
        let total = weights.values.reduce(0, +) + 2
        var done = 0.0
        for f in files {
            try Task.checkCancellation()
            guard let url = URL(string: src.base + f) else { continue }
            let w = weights[f] ?? 0.2
            let base = done
            let tmp = try await ImageModelDownloader.fetch(URLRequest(url: url)) { got, expected in
                let part = expected > 0 ? Double(got) / Double(expected) : 0
                progress(min(0.99, (base + w * part) / total))
            }
            let dest = d.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            done += w
            progress(min(0.99, done / total))
        }
    }
}

// MARK: - تنزيل ملف واحد مع التقدم

enum ImageModelDownloader {
    /// ينزّل لملف مؤقت ويرجع مكانه. يرفض أي رد غير 200/206.
    static func fetch(_ req: URLRequest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let box = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                box.continuation = c
                let t = session.downloadTask(with: req)
                box.task = t
                t.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    private func finish(_ r: Result<URL, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: r)
    }

    func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            finish(.failure(SawtError.failed("التنزيل رجع \(code)"))); return
        }
        // الملف المؤقت ينحذف بعد هالدالة: ننقله أول
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: keep); finish(.success(keep)) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - قراءة ملفات من zip على الإنترنت بطلبات Range (بدون zip64)


// MARK: - التوليد

/// يشغّل المحرك المختار بس. أي فشل يرجع سببه بدون تجربة محرك ثاني.
actor ImageGenerator {
    static let shared = ImageGenerator()
    /// فيه رسم شغال (الوكيل ما يبدأ وقتها)
    nonisolated(unsafe) static var busy = false

    private var pipeline: StableDiffusionPipeline?
    private var pipelineEngine: ImageEngine?

    static var outDir: URL { Attachments.dir }

    func generate(engine: ImageEngine, prompt: String, negative: String,
                  status: @escaping @Sendable (String) -> Void) async throws -> GeneratedImage {
        let img: CGImage
        var used = prompt
        switch engine {
        case .sdReal, .sdArt:
            // نص CLIP يقص بعد 77 رمز (75 + البداية والنهاية): نقص نحن عند حد كلمة عشان الوصف المعروض = المستخدم فعلًا
            used = Self.clipTrim(prompt, dir: SDModels.dir(engine))
            let neg = Self.clipTrim(negative, dir: SDModels.dir(engine))
            if used != prompt { slog("image: prompt trimmed to 75 CLIP tokens") }
            img = try await runSD(engine, prompt: used, negative: neg, status: status)
        case .klein:
            img = try await runKlein(prompt: prompt, status: status)
        case .playground:
            img = try await runPlayground(prompt: prompt, status: status)
        case .gemini, .geminiLite:
            img = try await runGemini(engine, prompt: prompt, status: status)
        }
        let name = "\(UUID().uuidString)-gen.png"
        guard let png = UIImage(cgImage: img).pngData() else { throw SawtError.failed("ما قدرت أحفظ الصورة") }
        try png.write(to: Self.outDir.appendingPathComponent(name), options: .atomic)
        return GeneratedImage(file: name, prompt: used, engine: engine)
    }

    /// نفك نموذج SD من الذاكرة (يُستدعى بعد التوليد وقبل ما يرجع النموذج اللغوي)
    func unloadSD() {
        pipeline?.unloadResources()
        pipeline = nil
        pipelineEngine = nil
    }

    // MARK: Stable Diffusion (Core ML على المحرك العصبي)

    /// يقص النص عند آخر كلمة تدخل ضمن 75 رمز CLIP (بمقطّع النموذج نفسه؛ ولو ما انقرى نكتفي بـ45 كلمة)
    static func clipTrim(_ text: String, dir: URL, limit: Int = 77) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let tok = try? BPETokenizer(mergesAt: dir.appendingPathComponent("merges.txt"),
                                          vocabularyAt: dir.appendingPathComponent("vocab.json")) else {
            return words.prefix(45).joined(separator: " ")
        }
        if tok.tokenize(input: text).tokens.count <= limit { return text }
        var kept: [String] = []
        for w in words {
            let next = (kept + [w]).joined(separator: " ")
            if tok.tokenize(input: next).tokens.count > limit { break }
            kept.append(w)
        }
        return kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    }

    private func runSD(_ e: ImageEngine, prompt: String, negative: String,
                       status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        guard SDModels.installed(e) else { throw SawtError.failed("نموذج \(e.title) مو منزّل. نزّله من الإعدادات ← الصور.") }
        let dir = SDModels.dir(e)
        if pipelineEngine != e {
            unloadSD()
            // أول تحميل يجهّز النموذج للمحرك العصبي (ممكن ياخذ دقيقة أو أكثر)، وبعدها النظام يحفظه
            status("أحمّل نموذج الصور… (أول مرة ممكن ياخذ دقيقة)")
            ImageProgress.post(.loading)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            let t0 = Date()
            let p = try StableDiffusionPipeline(resourcesAt: dir, controlNet: [], configuration: cfg,
                                                disableSafety: true, reduceMemory: false)
            try p.loadResources()
            pipeline = p
            pipelineEngine = e
            slog("image: sd loaded \(e.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000))ms footprint=\(RAM.footprintMB)MB")
        }
        guard let p = pipeline else { throw SawtError.failed("ما تحمّل نموذج الصور") }
        var c = StableDiffusionPipeline.Configuration(prompt: prompt)
        c.schedulerType = .lcmScheduler
        c.seed = UInt32.random(in: 0...UInt32.max)
        c.disableSafety = true
        do {
            // نماذج LCM: مجدول LCM إلزامي. الـUnet مبني لدفعة 2، فالتوجيه (CFG) ما يزيد الوقت.
            // CyberRealistic: الناشر جرّب ٤–١٠ واقترح CFG ‏1.5. DreamShaper 8 LCM: الناشر يقترح CFG ‏~2.
            c.stepCount = e == .sdReal ? 6 : 8
            c.guidanceScale = e == .sdReal ? 1.5 : 2.0
            c.negativePrompt = negative
        }
        // المعاينة الحية من تقدير الصورة النهائية في كل خطوة (مو الـlatent المزعج)
        c.useDenoisedIntermediates = true
        let steps = c.stepCount
        status("أرسم… 0/\(steps)")
        ImageProgress.post(.drawing(0, steps))
        let t0 = Date()
        let images = try p.generateImages(configuration: c) { prog in
            // بعد آخر خطوة يبدأ فك الصورة (VAE) فنقول كذا بدل ما نعلق على «٢٠/٢٠»
            let done = prog.step + 1
            // معاينة مغبّشة في آخر ~٣٠٪ (تحويل خطي رخيص، بدون VAE لكل خطوة)
            var box: PreviewBox?
            if Double(done) >= 0.65 * Double(prog.stepCount),
               let lat = prog.currentLatentSamples.first, let cg = ImageProgress.latentPreview(lat) {
                box = PreviewBox(cg)
            }
            if done >= prog.stepCount {
                status("أجهّز الصورة…")
                ImageProgress.post(.decoding, preview: box)
            } else {
                status("أرسم… \(done)/\(prog.stepCount)")
                ImageProgress.post(.drawing(done, prog.stepCount), preview: box)
            }
            return !Task.isCancelled
        }
        if Task.isCancelled { throw CancellationError() }
        status("أحفظ الصورة…")
        slog("image: sd \(e.rawValue) \(steps) steps in \(Int(Date().timeIntervalSince(t0) * 1000))ms footprint=\(RAM.footprintMB)MB")
        guard let img = images.compactMap({ $0 }).first else { throw SawtError.failed("النموذج ما رجّع صورة") }
        return img
    }

    // MARK: «دقيق» (Bonsai Image: FLUX.2 Klein 4B ثلاثي على MLX)

    private func runKlein(prompt: String, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        guard SDModels.installed(.klein) else { throw SawtError.failed("نموذج «دقيق» مو منزّل. نزّله من الإعدادات ← الصور.") }
        guard ProcessInfo.processInfo.physicalMemory >= 7_000_000_000 else {
            throw SawtError.failed("«دقيق» يحتاج جوال بذاكرة 8GB أو أكثر.")
        }
        unloadSD()
        let t0 = Date()
        let img = try await KleinPipeline.generate(
            dir: SDModels.dir(.klein), prompt: prompt, seed: UInt64.random(in: 0 ... UInt64(UInt32.max)),
            onPhase: { phase in
                switch phase {
                case "encode": status("أقرأ الوصف…"); ImageProgress.post(.loading)
                case "load": status("أحمّل نموذج الصور…"); ImageProgress.post(.loading)
                default: status("أجهّز الصورة…"); ImageProgress.post(.decoding)
                }
            },
            onStep: { k, n in
                status("أرسم… \(k)/\(n)")
                ImageProgress.post(.drawing(k, n))
            })
        if Task.isCancelled { throw CancellationError() }
        status("أحفظ الصورة…")
        slog("image: klein \(Klein.steps) steps in \(Int(Date().timeIntervalSince(t0) * 1000))ms footprint=\(RAM.footprintMB)MB")
        return img
    }

    // MARK: Image Playground (نافذة آبل؛ في iOS 27 يرسم على سحابة آبل الخاصة)
    // ImageCreator (الرسم البرمجي) انلغى في iOS 27، فنفتح نافذة Image Playground بالبرومبت جاهز والمستخدم يأكّد

    private func runPlayground(prompt: String, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        guard await NetworkGate.shared.permit("رسم صورة بـImage Playground (سحابة آبل الخاصة)") else {
            throw SawtError.failed("الإنترنت مقفول")
        }
        status("كمّل في Image Playground…")
        ImageProgress.post(.waiting)
        let url = await withTaskCancellationHandler {
            await PlaygroundBridge.shared.request(prompt)
        } onCancel: {
            Task { @MainActor in PlaygroundBridge.shared.finish(nil) }
        }
        try Task.checkCancellation()
        guard let url else { throw CancellationError() }
        guard let ui = UIImage(contentsOfFile: url.path), let cg = ui.cgImage else {
            throw SawtError.failed("ما قدرت أقرأ الصورة من Image Playground")
        }
        slog("image: playground ok \(cg.width)x\(cg.height)")
        return cg
    }

    // MARK: Gemini (سحابي مدفوع)

    private func runGemini(_ e: ImageEngine, prompt: String, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        // توليد الصور مدفوع: نفضّل مفتاح Gemini المدفوع لو موجود
        guard let key = CloudProvider.geminiPaid.key ?? CloudProvider.gemini.key else { throw SawtError.failed("ما فيه مفتاح Gemini. أضفه من النماذج ← السحابية.") }
        guard await NetworkGate.shared.permit("توليد صورة بـGemini") else { throw SawtError.failed("الإنترنت مقفول") }
        status("أطلب الصورة من \(e.title)…")
        ImageProgress.post(.waiting)
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(e.geminiModel):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            // حسب مرجع generateContent: الصورة ترجع inlineData، وimageConfig يحدد النسبة والحجم (1K هو الافتراضي)
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"],
                                 "imageConfig": ["aspectRatio": "1:1", "imageSize": "1K"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200 else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            slog("image: gemini \(code) \(msg)")
            throw SawtError.failed("Gemini رجّع \(code): \(msg.prefix(220))")
        }
        let cand = (json?["candidates"] as? [[String: Any]])?.first
        let parts = ((cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // نماذج Gemini 3 ممكن ترجع صور «تفكير» مؤقتة (thought: true) قبل النهائية: ناخذ آخر صورة مو تفكير
        for p in parts.reversed() where (p["thought"] as? Bool) != true {
            if let inline = (p["inlineData"] ?? p["inline_data"]) as? [String: Any],
               let b64 = inline["data"] as? String, let d = Data(base64Encoded: b64),
               let img = UIImage(data: d)?.cgImage {
                slog("image: gemini \(e.geminiModel) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                return img
            }
        }
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined(separator: " ")
        let reason = (cand?["finishReason"] as? String) ?? ((json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String) ?? ""
        slog("image: gemini no image reason=\(reason) text=\(text.prefix(200))")
        throw SawtError.failed("Gemini ما رجّع صورة\(reason.isEmpty ? "" : " (\(reason))")\(text.isEmpty ? "" : ": \(text.prefix(200))")")
    }
}

// MARK: - أنماط Image Playground

enum PlaygroundStyles {
    /// الأنماط اللي تظهر في النافذة (externalProvider = مزوّد خارجي مثل ChatGPT، اختياري)
    static let all: [(id: String, label: String)] = [
        ("animation", "أنيميشن"), ("illustration", "رسم توضيحي"), ("sketch", "سكتش"), ("externalProvider", "ChatGPT (مزوّد خارجي)"),
    ]

    static func style(_ id: String) -> ImagePlaygroundStyle {
        switch id {
        case "illustration": .illustration
        case "sketch": .sketch
        case "externalProvider": .externalProvider
        default: .animation
        }
    }

    static var selectedID: String { UserDefaults.standard.string(forKey: "playgroundStyle") ?? "" }
    /// النمط اللي تفتح عليه النافذة
    static var selected: ImagePlaygroundStyle { style(selectedID) }
    /// المسموح في النافذة: أنماط آبل، والمزوّد الخارجي بس لو اختاره
    static var allowed: [ImagePlaygroundStyle] {
        var a: [ImagePlaygroundStyle] = [.animation, .illustration, .sketch]
        if selectedID == "externalProvider" { a.append(.externalProvider) }
        return a
    }
}

/// طلب رسم ينتظر نافذة Image Playground (الواجهة تعرضها وترجع الرابط)
@MainActor
final class PlaygroundBridge: ObservableObject {
    static let shared = PlaygroundBridge()
    @Published private(set) var prompt: String?
    private var cont: CheckedContinuation<URL?, Never>?

    func request(_ p: String) async -> URL? {
        finish(nil)   // أي طلب قديم معلّق
        return await withCheckedContinuation { c in
            cont = c
            prompt = p
        }
    }

    func finish(_ url: URL?) {
        prompt = nil
        let c = cont
        cont = nil
        // الملف مؤقت والنظام ممكن يمسحه بعد ما يرجع الرد: ننسخه فورًا
        var kept: URL?
        if let url {
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            if (try? FileManager.default.copyItem(at: url, to: dst)) != nil { kept = dst } else { kept = url }
        }
        c?.resume(returning: kept)
    }

    /// النافذة انقفلت: لو ما وصل رابط ولا إلغاء خلال ثانية نعتبرها انلغت
    func dismissed() {
        prompt = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if self.prompt == nil, self.cont != nil { self.finish(nil) }
        }
    }
}
