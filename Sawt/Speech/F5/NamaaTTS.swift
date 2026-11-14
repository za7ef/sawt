import AVFoundation
import Foundation
import MLX
import MLXNN
import MLXRandom
import SwiftUI

/// صوت «نماء سعودي» التجريبي (NAMAA-Saudi-TTS-V2، رخصة CC-BY-NC-SA، استخدام شخصي غير تجاري).
/// نموذج F5-TTS v1 Base مدرّب على اللهجة السعودية. ثقيل وما يبث، فيولّد الجملة كاملة قبل ما يشغلها.
@MainActor
final class NamaaVoice: ObservableObject {
    static let shared = NamaaVoice()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case converting
        case ready
        case failed(String)
    }

    @Published var state: State = .notDownloaded {
        didSet { ModelManager.shared.refreshDownloadFlag() }
    }

    /// فيه تنزيل أو تحويل شغال
    var isBusy: Bool {
        switch state { case .downloading, .converting: return true; default: return false }
    }
    @Published var testing = false
    @Published var lastTest: String?

    static let modelRepo = "https://huggingface.co/NAMAA-Space/NAMAA-Saudi-TTS-V2/resolve/main/"
    static let files: [(url: String, name: String, bytes: Int64)] = [
        (modelRepo + "model_2000.safetensors", "raw.safetensors", 1_348_757_753),
        (modelRepo + "vocab.txt", "vocab.txt", 20_000),
        ("https://huggingface.co/lucasnewman/vocos-mel-24khz-mlx/resolve/main/model.safetensors", "vocos.safetensors", 54_339_850),
        ("https://raw.githubusercontent.com/SWivid/Habibi-TTS/main/src/habibi_tts/assets/Hijazi.wav", "ref.wav", 175_758),
    ]

    nonisolated static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Namaa", isDirectory: true)
    }
    nonisolated static var modelURL: URL { dir.appendingPathComponent("namaa-f16.safetensors") }
    nonisolated static var isInstalled: Bool {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Namaa", isDirectory: true)
        return ["namaa-f16.safetensors", "vocab.txt", "vocos.safetensors", "ref.wav"].allSatisfy {
            FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path)
        }
    }

    static let testSentence = "هلا والله، كيف حالك اليوم؟ إن شاء الله أمورك طيبة والشغل ماشي تمام."

    private var task: Task<Void, Never>?

    private init() {
        // نعيّن القيمة الأولية مباشرة: الإسناد العادي هنا يشغّل didSet، اللي يقرأ NamaaVoice.shared
        // وهو لسه يتهيأ (كان هذا سبب الانقفال عند فتح التطبيق في بناء 100)
        _state = Published(initialValue: NamaaVoice.isInstalled ? .ready : .notDownloaded)
    }

    var sizeOnDisk: Int64 { Storage.size(NamaaVoice.dir) }

    func download() {
        guard task == nil else { return }
        task = Task {
            if let why = Storage.spaceProblem(forGB: 1.5) { state = .failed(why); task = nil; return }
            guard await NetworkGate.shared.permit("تنزيل صوت نماء") else { task = nil; return }
            do {
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var d = Self.dir; try? d.setResourceValues(excluded)
                let total = Self.files.reduce(Int64(0)) { $0 + $1.bytes }
                var done: Int64 = 0
                state = .downloading(0)
                for f in Self.files {
                    let dest = Self.dir.appendingPathComponent(f.name)
                    if f.name == "raw.safetensors", FileManager.default.fileExists(atPath: Self.modelURL.path) {
                        done += f.bytes; continue
                    }
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        let base = done
                        try await Downloader.fetch(URL(string: f.url)!, to: dest) { got in
                            Task { @MainActor in
                                self.state = .downloading(Double(base + got) / Double(total))
                            }
                        }
                    }
                    done += f.bytes
                }
                state = .converting
                // التحويل ياخذ ~2GB وقتها: نفك النموذج اللغوي أول عشان iOS ما يقفل التطبيق
                let hadLLM = await LLMService.shared.isReady
                await LLMService.shared.unload()
                ModelManager.shared.llm = .idle
                slog("namaa: converting (llm unloaded=\(hadLLM)) avail=\(RAM.availableMB)MB")
                try await Task.detached(priority: .userInitiated) { try NamaaEngine.convert() }.value
                state = .ready
                if hadLLM { ModelManager.shared.loadAll() }
                slog("namaa: installed \(Storage.format(sizeOnDisk))")
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                slog("namaa: install failed \(error)")
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    /// الملف طلع تالف وقت التحميل.
    func markBroken() {
        state = .failed("ملف الصوت تالف، نزّله مرة ثانية")
        if AppSettings.shared.voiceID == "namaa" { slog("namaa: broken while selected") }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = NamaaVoice.isInstalled ? .ready : .notDownloaded
    }

    func delete() {
        cancel()
        NamaaEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.dir)
        state = .notDownloaded
        lastTest = nil
        if AppSettings.shared.voiceID == "namaa" {
            AppSettings.shared.voiceID = Catalog.voices.first?.id ?? "apple"
        }
    }

    /// يولّد الجملة التجريبية ويشغلها، ويحسب الوقت ونسبة الوقت الحقيقي.
    func test() {
        guard !testing else { return }
        testing = true
        lastTest = nil
        Task {
            let r = await NamaaEngine.shared.synthesizeTimed(Self.testSentence, speed: 1.0)
            testing = false
            switch r {
            case .failure(let e):
                lastTest = "ما زبط: \(e.localizedDescription)"
            case .success(let out):
                let rtf = out.genSeconds / max(out.audioSeconds, 0.01)
                lastTest = String(format: "التوليد: %.1f ث • طول الصوت: %.1f ث • النسبة: %.2f× (أقل من 1 يعني أسرع من الكلام)",
                                  out.genSeconds, out.audioSeconds, rtf)
                if out.loadSeconds > 0.05 {
                    lastTest! += String(format: "\nالتحميل للذاكرة أول مرة: %.1f ث", out.loadSeconds)
                }
                Speaker.shared.play(samples: out.samples, sampleRate: 24_000)
            }
        }
    }
}

/// تنزيل ملف كبير مع تقدّم.
enum Downloader {
    final class Delegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Int64) -> Void
        var cont: CheckedContinuation<URL, Error>?
        let dest: URL
        init(dest: URL, progress: @escaping (Int64) -> Void) { self.dest = dest; self.progress = progress }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "namaa", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "التنزيل رجع \(http.statusCode)"])
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                cont?.resume(returning: dest); cont = nil
            } catch {
                cont?.resume(throwing: error); cont = nil
            }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { cont?.resume(throwing: error); cont = nil }
        }
    }

    static func fetch(_ url: URL, to dest: URL, progress: @escaping (Int64) -> Void) async throws {
        let delegate = Delegate(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                delegate.cont = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// المحرّك نفسه: تحميل الأوزان والتوليد. يشتغل على طابور خاص.
final class NamaaEngine: @unchecked Sendable {
    static let shared = NamaaEngine()

    struct Output { let samples: [Float]; let genSeconds: Double; let audioSeconds: Double; let loadSeconds: Double }

    enum NamaaError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self { case .missing(let s): return s }
        }
    }

    private let queue = DispatchQueue(label: "sawt.namaa", qos: .userInitiated)
    private var dit: N5DiT?
    private var vocos: N5Vocos?
    private var filterbank: MLXArray?
    private var vocab: [String: Int] = [:]
    private var refAudio: [Float] = []
    private var refRMS: Float = 0.1

    static let fullRefText = "ابغاك تحقق معاه بس بشكل ودي لانه سلطان يمر بظروف صعبة شوية. "
    /// المرجع المختصر: أول 2.5 ثانية (تنتهي في سكتة بين 2.2 و2.88 ث بعد «بشكل ودي»).
    /// المرجع يتعالج مع كل جملة، فتقصيره من 5.5 إلى 2.5 ث يقلل الإطارات تقريبًا للنص.
    static let shortRefText = "ابغاك تحقق معاه بس بشكل ودي. "
    static let shortRefSeconds = 2.5
    private var refText = NamaaEngine.fullRefText
    /// ثواني التوليد لكل حرف (آخر قياس) لتقدير التأخير
    private var secPerChar: Double = 0
    private let statLock = NSLock()
    /// "ممم" جاهزة بصوت نماء تنقال لو الرد الأول تأخر
    /// كلمات الانتظار الجاهزة بصوت نماء
    private var _fillers: [String: [Float]] = [:]
    func filler(_ text: String) -> [Float]? {
        statLock.lock(); defer { statLock.unlock() }; return _fillers[text]
    }
    var readyFillers: Set<String> {
        statLock.lock(); defer { statLock.unlock() }; return Set(_fillers.keys)
    }
    private func renderFillers(max n: Int) {
        var done = 0
        for f in FillerPicker.renderOrder where done < n && self.filler(f) == nil {
            guard let o = try? self.generate(f, speed: 1.0, steps: 6) else { return }
            statLock.lock(); _fillers[f] = o.samples; statLock.unlock()
            slog("namaa: filler \"\(f)\" \(String(format: "%.2f", o.genSeconds))s")
            done += 1
        }
    }
    /// يجهّز كلمة انتظار وحدة زيادة (ينادى بعد ما يخلص الرد عشان ما يزاحمه)
    func renderNextFiller() {
        queue.async { if self.dit != nil { self.renderFillers(max: 1) } }
    }

    func estimatedSeconds(_ text: String) -> Double {
        statLock.lock(); defer { statLock.unlock() }
        return secPerChar * Double(text.count)
    }
    static let steps = 16
    static let stepChoices = [6, 7, 8, 16]
    /// عدد خطوات التوليد المختار (الافتراضي 7)
    static var chosenSteps: Int {
        let v = UserDefaults.standard.integer(forKey: "namaaSteps")
        return stepChoices.contains(v) ? v : 7
    }
    static let cfg: Float = 2.0
    static let sway: Float = -1.0

    // MARK: التحويل (مرة وحدة بعد التنزيل)

    /// يحوّل أوزان PyTorch (fp32) لأسماء وشكل MLX بدقة fp16 ويحذف الأصل.
    static func convert() throws {
        let dir = NamaaVoice.dir
        let raw = dir.appendingPathComponent("raw.safetensors")
        let out = NamaaVoice.modelURL
        if FileManager.default.fileExists(atPath: out.path) { return }
        guard FileManager.default.fileExists(atPath: raw.path) else { throw NamaaError.missing("ملف النموذج ناقص") }
        slog("namaa: converting")
        let src = try loadArrays(url: raw)
        var dst: [String: MLXArray] = [:]
        for (key, value) in src {
            guard key.hasPrefix("transformer."), !key.hasSuffix("inv_freq") else { continue }
            var k = String(key.dropFirst("transformer.".count))
            k = k.replacingOccurrences(of: "time_mlp.2.", with: "time_mlp.1.")
            k = k.replacingOccurrences(of: "conv1d.2.", with: "conv1d.1.")
            k = k.replacingOccurrences(of: "ff.ff.0.0.", with: "ff.fc1.")
            k = k.replacingOccurrences(of: "ff.ff.2.", with: "ff.fc2.")
            var v = value
            if v.ndim == 3 && (k.hasSuffix("dwconv.weight") || k.contains("conv1d.")) {
                v = v.swappedAxes(1, 2)   // [out, in, k] -> [out, k, in]
            }
            v = v.asType(.float16)
            eval(v)
            dst[k] = v
        }
        // نكتب لملف مؤقت ثم ننقله: لو انقفل التطبيق نص الكتابة ما يبقى ملف ناقص يبان كأنه جاهز
        let tmp = dir.appendingPathComponent("namaa-f16.partial.safetensors")
        try? FileManager.default.removeItem(at: tmp)
        try save(arrays: dst, url: tmp)
        dst.removeAll()
        try FileManager.default.moveItem(at: tmp, to: out)
        try? FileManager.default.removeItem(at: raw)
        MLX.Memory.clearCache()
        slog("namaa: converted \(dst.count) tensors")
    }

    // MARK: التحميل

    private func loadIfNeeded() throws -> Double {
        if dit != nil { return 0 }
        let t0 = Date()
        let dir = NamaaVoice.dir
        guard NamaaVoice.isInstalled else { throw NamaaError.missing("الصوت مو منزّل") }

        // المفردات: سطر لكل رمز، والرقم هو ترتيب السطر
        let text = try String(contentsOf: dir.appendingPathComponent("vocab.txt"), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var map: [String: Int] = [:]
        for (i, l) in lines.enumerated() where map[l] == nil { map[l] = i }
        vocab = map

        let model = N5DiT(textNumEmbeds: lines.count)
        do {
            let w = try loadArrays(url: NamaaVoice.modelURL)
            try model.update(parameters: ModuleParameters.unflattened(w), verify: [.all])
        } catch {
            // ملف تالف (مثلًا انقفل التطبيق وقت التحويل): نحذفه عشان يبان "مو منزّل" ويعاد تنزيله
            slog("namaa: model file broken → removing (\(error))")
            try? FileManager.default.removeItem(at: NamaaVoice.modelURL)
            Task { @MainActor in NamaaVoice.shared.markBroken() }
            throw NamaaError.missing("ملف صوت نماء تالف، نزّله مرة ثانية من الإعدادات")
        }
        eval(model)

        var vw = try loadArrays(url: dir.appendingPathComponent("vocos.safetensors"))
        guard let fb = vw.removeValue(forKey: "feature_extractor.filterbank") else {
            throw NamaaError.missing("ملف Vocos ناقص")
        }
        let voc = N5Vocos()
        try voc.update(parameters: ModuleParameters.unflattened(vw), verify: [.all])
        eval(voc)

        refAudio = try Self.loadWav24k(dir.appendingPathComponent("ref.wav"))
        let rms = sqrt(refAudio.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(refAudio.count, 1)))
        refRMS = rms
        if rms < 0.1, rms > 0 { refAudio = refAudio.map { $0 * 0.1 / rms } }
        // نقص المرجع لأول 2.5 ثانية (داخل السكتة) مع تلاشي قصير في الآخر
        let cut = Int(Self.shortRefSeconds * 24_000)
        if refAudio.count > cut + 2_400 {
            refAudio = Array(refAudio.prefix(cut))
            let fade = 1_200
            for i in 0 ..< fade { refAudio[cut - fade + i] *= Float(fade - i) / Float(fade) }
            refText = Self.shortRefText
        } else {
            refText = Self.fullRefText
        }

        dit = model; vocos = voc; filterbank = fb
        let s = Date().timeIntervalSince(t0)
        slog("namaa: loaded in \(Int(s * 1000))ms vocab=\(lines.count) ram=\(RAM.footprintMB)MB")
        return s
    }

    /// يحمّل النموذج بالخلفية إذا كان منزّل.
    func preload() {
        queue.async {
            guard (try? self.loadIfNeeded()) != nil else { return }
            // تسخين: أول توليد يجهّز النوى، ونحفظ ناتجه ككلمات انتظار (وحدة عادية ووحدة للتفكير)
            self.renderFillers(max: 2)
        }
    }

    func unload() {
        queue.async {
            self.dit = nil; self.vocos = nil; self.filterbank = nil
            self.statLock.lock(); self._fillers = [:]; self.statLock.unlock()
            MLX.Memory.clearCache()
        }
    }

    static func loadWav24k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return [] }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 24_000 / inFmt.sampleRate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    // MARK: التوليد

    func synthesizeTimed(_ text: String, speed: Double, steps: Int? = nil) async -> Result<Output, Error> {
        await withCheckedContinuation { cont in
            queue.async {
                do { cont.resume(returning: .success(try self.generate(text, speed: speed, steps: steps))) }
                catch { cont.resume(returning: .failure(error)) }
            }
        }
    }

    /// للاستخدام من SpeechSynth (القراءة والمكالمة).
    /// النص الطويل بدون ترقيم يتقسم لقطع ≤150 حرف (النموذج يخرب مع الطويل) ونوصلها بسكتة قصيرة.
    func synthesize(_ text: String, speed: Double, steps: Int? = nil) async -> [Float] {
        var out: [Float] = []
        for piece in Self.chunks(text, max: 150) {
            switch await synthesizeTimed(piece, speed: speed, steps: steps) {
            case .success(let o):
                if !out.isEmpty { out += [Float](repeating: 0, count: 2_880) }   // ~0.12ث على 24kHz
                out += o.samples
            case .failure(let e): slog("namaa: synth failed \(e)"); return out
            }
            if Task.isCancelled { break }
        }
        return out
    }

    static func chunks(_ text: String, max: Int) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t.isEmpty ? [] : [t] }
        var res: [String] = []
        var cur = ""
        for word in t.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if cur.count + w.count + 1 > max, !cur.isEmpty {
                res.append(cur); cur = ""
            }
            // كلمة أطول من الحد (نادر): نقصها
            if w.count > max {
                var s = Substring(w)
                while s.count > max { res.append(String(s.prefix(max))); s = s.dropFirst(max) }
                cur = String(s)
            } else {
                cur += (cur.isEmpty ? "" : " ") + w
            }
            // نفضّل القص بعد الفاصلة
            if cur.count > max / 2, let last = cur.last, "،,؛;:".contains(last) { res.append(cur); cur = "" }
        }
        if !cur.isEmpty { res.append(cur) }
        return res
    }

    private func tokens(_ s: String) -> [Int32] {
        s.unicodeScalars.map { Int32(vocab[String($0)] ?? 0) }
    }

    private func generate(_ text: String, speed inSpeed: Double, steps stepsOverride: Int? = nil) throws -> Output {
        let loadS = try loadIfNeeded()
        guard let dit, let vocos, let filterbank else { throw NamaaError.missing("الصوت مو جاهز") }
        let t0 = Date()
        defer { MLX.Memory.clearCache() }

        let gen = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = refText
        let genBytes = gen.utf8.count, refBytes = ref.utf8.count
        let speed = genBytes < 10 ? 0.3 : max(0.5, min(inSpeed, 2.0))

        let hop = 256
        let refAudioLen = refAudio.count / hop
        let duration = refAudioLen + Int(Double(refAudioLen) / Double(refBytes) * Double(genBytes) / speed)

        let cond = N5Audio.logMel(refAudio, filterbank: filterbank)          // [1, c, 100]
        let condLen = cond.dim(1)
        let ids = tokens(ref + gen)
        let total = min(max(duration, max(ids.count, condLen) + 1), 4096)

        let dtype = DType.float16
        let condPadded = MLX.padded(cond, widths: [.init((0, 0)), .init((0, total - condLen)), .init((0, 0))]).asType(dtype)
        let textArr = MLXArray(ids).reshaped([1, ids.count])
        let textCond = dit.text_embed(textArr, seqLen: total, drop: false)
        let textUncond = dit.text_embed(textArr, seqLen: total, drop: true)
        eval(textCond, textUncond)
        let rope = dit.rope(total)

        // عدد الخطوات من الإعدادات (الافتراضي 7 بجدول EPSS)، والتجربة بالإعدادات تستخدم نفس العدد
        // عشان يسمع نفس جودة المكالمة. إذا الجوال حار في مكالمة: 6 كحد أقصى.
        var steps = stepsOverride ?? Self.chosenSteps
        if CallController.isActive, ThermalWatch.isHot { steps = min(steps, 6) }
        // جداول EPSS من F5-TTS v1 (من 32)، ثم sway
        let epssTable: [Int: [Float]] = [
            6: [0, 2, 4, 6, 8, 16, 32],
            7: [0, 2, 4, 6, 8, 16, 24, 32],
            8: [0, 2, 4, 6, 8, 12, 16, 24, 32],
            16: [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32],
        ]
        var ts = epssTable[steps].map { $0.map { $0 / 32 } } ?? (0 ... steps).map { Float($0) / Float(steps) }
        ts = ts.map { t in t + Self.sway * (cos(Float.pi / 2 * t) - 1 + t) }

        var x = MLXRandom.normal([1, total, 100])   // fp32
        for i in 0 ..< (ts.count - 1) {
            let t = ts[i], dt = ts[i + 1] - ts[i]
            let both = dit(x: x.asType(dtype), cond: condPadded, textCond: textCond, textUncond: textUncond,
                           time: t, rope: rope).asType(.float32)
            let parts = both.split(parts: 2, axis: 0)
            let v = parts[0] + (parts[0] - parts[1]) * Self.cfg
            x = x + dt * v
            eval(x)
        }
        // الجزء المولّد بعد مرجع الصوت
        let mel = x[0..., refAudioLen ..< total, 0...]
        var wave = vocos.decode(mel)
        if refRMS < 0.1, refRMS > 0 { wave = wave * (refRMS / 0.1) }
        eval(wave)
        var samples = wave.asArray(Float.self)
        // تنعيم البداية والنهاية لتفادي الطقطقة
        let fade = min(480, samples.count / 4)
        for i in 0 ..< fade {
            let g = Float(i) / Float(fade)
            samples[i] *= g
            samples[samples.count - 1 - i] *= g
        }
        let genS = Date().timeIntervalSince(t0)
        let audioS = Double(samples.count) / 24_000
        // الجمل القصيرة جدًا تكلفتها ثابتة تقريبًا فما نحسبها
        if gen.count >= 20 { statLock.lock(); secPerChar = genS / Double(gen.count); statLock.unlock() }
        slog("namaa: gen \(String(format: "%.2f", genS))s audio \(String(format: "%.2f", audioS))s RTF=\(String(format: "%.2f", genS / max(audioS, 0.01))) steps=\(steps) frames=\(total) ref=\(refAudioLen) ram=\(RAM.footprintMB)MB")
        return Output(samples: samples, genSeconds: genS, audioSeconds: audioS, loadSeconds: loadS)
    }
}
