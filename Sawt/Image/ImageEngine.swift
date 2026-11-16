import Foundation
import CoreML
import CoreGraphics
import Compression
import UIKit
import ImagePlayground
import StableDiffusion

/// محركات توليد الصور. المستخدم يختار واحد، وما نبدّل لغيره تلقائيًا أبدًا.
enum ImageEngine: String, CaseIterable, Identifiable {
    case sd21, sdTurbo, playground, gemini, geminiLite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sd21: "Stable Diffusion 2.1"
        case .sdTurbo: "سريع (تجريبي) — SD-Turbo"
        case .playground: "Image Playground"
        case .gemini: "Gemini 3.1 Flash Image"
        case .geminiLite: "Gemini 3.1 Flash Lite Image"
        }
    }

    /// وصف قصير يطلع في القائمة
    var tag: String {
        switch self {
        case .sd21, .sdTurbo, .playground: "محلي"
        case .gemini, .geminiLite: "سحابي · مدفوع"
        }
    }

    var isLocalSD: Bool { self == .sd21 || self == .sdTurbo }
    var isGemini: Bool { self == .gemini || self == .geminiLite }

    var geminiModel: String { self == .geminiLite ? "gemini-3.1-flash-lite-image" : "gemini-3.1-flash-image" }

    /// المحرك المختار (nil = ما اختار للحين)
    static var selected: ImageEngine? {
        get { UserDefaults.standard.string(forKey: "imageEngine").flatMap(ImageEngine.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: "imageEngine") }
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

    nonisolated static func installed(_ e: ImageEngine) -> Bool {
        guard e.isLocalSD else { return false }
        let d = dir(e)
        return needed.allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) }
    }

    nonisolated static func approxGB(_ e: ImageEngine) -> Double { e == .sd21 ? 1.08 : 1.02 }

    func download(_ e: ImageEngine) {
        guard e.isLocalSD, tasks[e] == nil else { return }
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
                if e == .sd21 {
                    try await Self.fetchFiles(into: tmp, progress: report)
                } else {
                    try await Self.fetchFromZip(into: tmp, progress: report)
                }
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

    // نسخة Apple الرسمية: الملفات منفصلة في المستودع
    nonisolated private static let sd21Base = "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/split_einsum_v2/compiled/"
    // SD-Turbo (6-bit) موجود كملف zip بس: ناخذ الملفات اللي نحتاجها منه بطلبات Range بدون ما ننزّل الملف كامل
    nonisolated private static let turboZip = "https://huggingface.co/mozksoft/sd-turbo-coreml-q6/resolve/main/sd-turbo-coreml-q6_split_einsum_v2_compiled.zip"

    nonisolated private static func fetchFiles(into d: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // الأحجام التقريبية عشان شريط التقدم (الأوزان هي الثقيلة)
        let weights: [String: Double] = ["TextEncoder.mlmodelc/weights/weight.bin": 319, "Unet.mlmodelc/weights/weight.bin": 650,
                                         "VAEDecoder.mlmodelc/weights/weight.bin": 99]
        let total = 1080.0
        var done = 0.0
        for f in needed {
            try Task.checkCancellation()
            guard let url = URL(string: sd21Base + f) else { continue }
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

    nonisolated private static func fetchFromZip(into d: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: turboZip) else { throw SawtError.failed("رابط النموذج غلط") }
        let entries = try await ZipRange.entries(of: url)
        // أول جزء من المسار اسم المجلد داخل الملف: نشيله
        func local(_ name: String) -> String {
            guard let i = name.firstIndex(of: "/") else { return name }
            return String(name[name.index(after: i)...])
        }
        let wanted = entries.filter { needed.contains(local($0.name)) }
        guard Set(wanted.map { local($0.name) }) == Set(needed) else {
            throw SawtError.failed("ملف النموذج ناقص (\(wanted.count)/\(needed.count))")
        }
        let total = Double(wanted.reduce(0) { $0 + $1.compressedSize })
        var done = 0.0
        for e in wanted {
            try Task.checkCancellation()
            let base = done
            let dest = d.appendingPathComponent(local(e.name))
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await ZipRange.extract(e, from: url, to: dest) { got in
                progress(min(0.99, (base + Double(got)) / max(total, 1)))
            }
            done += Double(e.compressedSize)
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

enum ZipRange {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localOffset: UInt64
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16
    }

    private static func range(_ url: URL, _ from: UInt64, _ to: UInt64?) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(to.map { "bytes=\(from)-\($0)" } ?? "bytes=-\(from)", forHTTPHeaderField: "Range")
        return r
    }

    private static func get(_ r: URLRequest) async throws -> Data {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 206 else { throw SawtError.failed("الخادم ما يدعم التنزيل الجزئي (\(code))") }
        return d
    }

    /// يقرأ الفهرس المركزي من آخر الملف
    static func entries(of url: URL) async throws -> [Entry] {
        let tail = try await get(range(url, 65_536, nil))
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard let eocd = tail.lastRange(of: Data(sig))?.lowerBound else { throw SawtError.failed("ملف zip غير صالح") }
        let e = eocd - tail.startIndex
        let count = Int(u16(tail, e + 10))
        let cdSize = UInt64(u32(tail, e + 12))
        let cdOffset = UInt64(u32(tail, e + 16))
        guard cdOffset != 0xFFFF_FFFF else { throw SawtError.failed("zip64 غير مدعوم") }
        let cd = try await get(range(url, cdOffset, cdOffset + cdSize - 1))
        var out: [Entry] = []
        var o = 0
        for _ in 0..<count {
            guard o + 46 <= cd.count, u32(cd, o) == 0x0201_4b50 else { throw SawtError.failed("فهرس zip تالف") }
            let method = u16(cd, o + 10)
            let csize = UInt64(u32(cd, o + 20))
            let size = UInt64(u32(cd, o + 24))
            let nl = Int(u16(cd, o + 28)), el = Int(u16(cd, o + 30)), cl = Int(u16(cd, o + 32))
            let off = UInt64(u32(cd, o + 42))
            let nameData = cd.subdata(in: cd.startIndex + o + 46 ..< cd.startIndex + o + 46 + nl)
            let name = String(decoding: nameData, as: UTF8.self)
            if !name.hasSuffix("/") {
                out.append(Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: off))
            }
            o += 46 + nl + el + cl
        }
        return out
    }

    /// ينزّل بيانات ملف واحد ويفك ضغطه (deflate) لمكانه
    static func extract(_ e: Entry, from url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard e.method == 0 || e.method == 8 else { throw SawtError.failed("طريقة ضغط غير مدعومة (\(e.method))") }
        let head = try await get(range(url, e.localOffset, e.localOffset + 29))
        guard u32(head, 0) == 0x0403_4b50 else { throw SawtError.failed("ترويسة zip تالفة") }
        let start = e.localOffset + 30 + UInt64(u16(head, 26)) + UInt64(u16(head, 28))
        let tmp: URL
        if e.compressedSize == 0 {
            tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
        } else {
            tmp = try await ImageModelDownloader.fetch(range(url, start, start + e.compressedSize - 1)) { got, _ in progress(got) }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.removeItem(at: dest)
        if e.method == 0 {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } else {
            try inflate(tmp, to: dest)
        }
        let got = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard got == e.size else { throw SawtError.failed("حجم \(dest.lastPathComponent) غلط (\(got)/\(e.size))") }
    }

    /// فك deflate خام على دفعات (بدون تحميل الملف كله بالذاكرة)
    private static func inflate(_ src: URL, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? input.close(); try? output.close() }
        var failed: Error?
        let filter = try OutputFilter(.decompress, using: .zlib) { (chunk: Data?) in
            if let chunk, failed == nil {
                do { try output.write(contentsOf: chunk) } catch { failed = error }
            }
        }
        while true {
            let block = try input.read(upToCount: 1 << 20) ?? Data()
            if block.isEmpty { break }
            try filter.write(block)
            if let failed { throw failed }
        }
        try filter.finalize()
        if let failed { throw failed }
    }
}

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
        case .sd21, .sdTurbo:
            // نص CLIP يقص بعد 77 رمز (75 + البداية والنهاية): نقص نحن عند حد كلمة عشان الوصف المعروض = المستخدم فعلًا
            used = Self.clipTrim(prompt, dir: SDModels.dir(engine))
            let neg = Self.clipTrim(negative, dir: SDModels.dir(engine))
            if used != prompt { slog("image: prompt trimmed to 75 CLIP tokens") }
            img = try await runSD(engine, prompt: used, negative: neg, status: status)
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

    /// حجم دفعة الـUnet من metadata.json (2 = مبني للتوجيه CFG)
    private static func unetBatch(_ dir: URL) -> Int {
        let u = dir.appendingPathComponent("Unet.mlmodelc/metadata.json")
        guard let d = try? Data(contentsOf: u),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
              let inputs = arr.first?["inputSchema"] as? [[String: Any]],
              let hs = inputs.first(where: { ($0["name"] as? String) == "encoder_hidden_states" }),
              let shape = hs["shape"] as? String else { return 2 }
        let n = shape.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").first
        return n.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 2
    }

    private func runSD(_ e: ImageEngine, prompt: String, negative: String,
                       status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        guard SDModels.installed(e) else { throw SawtError.failed("نموذج \(e.title) مو منزّل. نزّله من النماذج ← الصور.") }
        let dir = SDModels.dir(e)
        if pipelineEngine != e {
            unloadSD()
            // أول تحميل يجهّز النموذج للمحرك العصبي (ممكن ياخذ دقيقة أو أكثر)، وبعدها النظام يحفظه
            status("أحمّل نموذج الصور… (أول مرة ممكن ياخذ دقيقة)")
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
        c.schedulerType = .dpmSolverMultistepScheduler
        c.seed = UInt32.random(in: 0...UInt32.max)
        c.disableSafety = true
        if e == .sdTurbo {
            // DPM-Solver بخطوتين = خطوات [999, 500] من الدرجة الأولى (مثل DDIM)، وهذا يناسب نماذج الخطوات القليلة.
            // keijiro (ml-stable-diffusion لـSD-Turbo) يوصي بـ1–4 خطوات وتوجيه 1–2.
            // Turbo مدرّب بدون توجيه: 1.0 = نفس النتيجة بدون CFG (الـUnet مبني لدفعة 2 فنحتاج نمرّر الاثنين)
            c.stepCount = 2
            c.guidanceScale = Self.unetBatch(dir) == 2 ? 1.0 : 0.0
            c.negativePrompt = ""
        } else {
            c.stepCount = 20
            c.guidanceScale = 7.5
            c.negativePrompt = negative
        }
        let steps = c.stepCount
        status("أرسم… 0/\(steps)")
        let t0 = Date()
        let images = try p.generateImages(configuration: c) { prog in
            status("أرسم… \(prog.step + 1)/\(prog.stepCount)")
            return !Task.isCancelled
        }
        if Task.isCancelled { throw CancellationError() }
        slog("image: sd \(e.rawValue) \(steps) steps in \(Int(Date().timeIntervalSince(t0) * 1000))ms footprint=\(RAM.footprintMB)MB")
        guard let img = images.compactMap({ $0 }).first else { throw SawtError.failed("النموذج ما رجّع صورة") }
        return img
    }

    // MARK: Image Playground (Apple Intelligence على الجهاز)

    private func runPlayground(prompt: String, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        status("أرسم بـImage Playground…")
        let style = await PlaygroundStyles.selectedStyle()
        do {
            let creator = try await ImageCreator()
            let styles = creator.availableStyles
            guard let st = style.flatMap({ s in styles.first { $0.id == s.id } }) ?? styles.first(where: { PlaygroundStyles.isLocal($0) }) else {
                throw SawtError.failed("Image Playground ما فيه أنماط متاحة")
            }
            slog("image: playground style=\(st.id) available=\(styles.map(\.id))")
            for try await img in creator.images(for: [.text(prompt)], style: st, limit: 1) {
                return img.cgImage
            }
            throw SawtError.failed("Image Playground ما رجّع صورة")
        } catch let e as ImageCreator.Error {
            slog("image: playground error \(e)")
            throw SawtError.failed("Image Playground رفض: \(PlaygroundStyles.explain(e))")
        }
    }

    // MARK: Gemini (سحابي مدفوع)

    private func runGemini(_ e: ImageEngine, prompt: String, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        // توليد الصور مدفوع: نفضّل مفتاح Gemini المدفوع لو موجود
        guard let key = CloudProvider.geminiPaid.key ?? CloudProvider.gemini.key else { throw SawtError.failed("ما فيه مفتاح Gemini. أضفه من النماذج ← السحابية.") }
        guard await NetworkGate.shared.permit("توليد صورة بـGemini") else { throw SawtError.failed("الإنترنت مقفول") }
        status("أطلب الصورة من \(e.title)…")
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
    /// الأنماط على الجهاز؛ externalProvider (iOS 26: أنماط ChatGPT) هو اللي يروح للسحابة
    static func isLocal(_ s: ImagePlaygroundStyle) -> Bool {
        s.id != ImagePlaygroundStyle.externalProvider.id
    }

    static func label(_ s: ImagePlaygroundStyle) -> String {
        let base: String
        switch s.id {
        case ImagePlaygroundStyle.animation.id: base = "أنيميشن"
        case ImagePlaygroundStyle.illustration.id: base = "رسم توضيحي"
        case ImagePlaygroundStyle.sketch.id: base = "سكتش"
        case ImagePlaygroundStyle.externalProvider.id: base = "ChatGPT"
        default: base = s.id
        }
        return isLocal(s) ? base : "\(base) (سحابي)"
    }

    static var selectedID: String? {
        get { UserDefaults.standard.string(forKey: "playgroundStyle") }
        set { UserDefaults.standard.set(newValue, forKey: "playgroundStyle") }
    }

    /// النمط المختار لو موجود
    static func selectedStyle() async -> ImagePlaygroundStyle? {
        guard let id = selectedID else { return nil }
        guard let c = try? await ImageCreator() else { return nil }
        return c.availableStyles.first { $0.id == id }
    }

    /// الأنماط المتاحة أو سبب عدم التوفر (لصفحة النماذج وزر التجربة)
    static func probe() async -> (styles: [ImagePlaygroundStyle], error: String?) {
        do {
            let c = try await ImageCreator()
            return (c.availableStyles, nil)
        } catch let e as ImageCreator.Error {
            return ([], explain(e))
        } catch {
            return ([], error.localizedDescription)
        }
    }

    static func explain(_ e: ImageCreator.Error) -> String {
        switch e {
        case .notSupported: return "الجهاز أو التطبيق ما يدعمه (notSupported)"
        case .unavailable: return "Apple Intelligence مو جاهز أو للحين ينزّل (unavailable)"
        case .backgroundCreationForbidden: return "لازم صوت يكون قدّام وقت الرسم"
        case .creationCancelled: return "انلغى"
        default: return String(describing: e)
        }
    }
}
