import Foundation
import MLXLMCommon
import SwiftUI

struct Turn: Identifiable, Equatable {
    enum Role { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var interrupted = false
}

/// يدير المكالمة: مايك مفتوح طول الوقت، يعرف متى خلصت كلامك، ويقطع كلامه إذا قاطعته.
final class CallController: ObservableObject {
    enum State: Equatable { case idle, starting, listening, hearing, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published var turns: [Turn] = [] { didSet { onTurnsChanged?(turns) } }
    var onTurnsChanged: (([Turn]) -> Void)?
    @Published private(set) var liveUser = ""
    @Published private(set) var liveAI = ""
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var outLevel: Float = 0
    @Published var error: String?
    @Published var muted = false
    /// الكاميرا شغالة في المكالمة (طافية افتراضيًا)
    @Published var cameraOn = false
    @Published var cameraBusy = false

    /// معلومات التشخيص اللي تطلع فوق المكالمة.
    struct Debug: Equatable {
        var stage = "—"
        var micDB: Float = -120
        var vadSpeech = false
        var lastTranscript = ""
        var sttMs = 0
        var firstTokenMs = 0
        var firstAudioMs = 0
        var ramMB = 0
        var availMB = 0
        var thermal = ""
    }
    @Published private(set) var debug = Debug()
    private var procDB: Float = -120
    private var procSpeech = false
    private var turnStart = Date()
    private var tick = 0
    /// فكّينا نموذج السمع مؤقتًا عشان الذاكرة وقت الرد
    private var sttUnloaded = false
    private var userTalking = false
    /// بث تمييز آبل للدور الحالي (على خيط المعالجة)
    private var appleStream: AppleStream?
    private var fragmentTimer: Task<Void, Never>?
    private var sttReload: Task<Void, Never>?

    private let audio = AudioIO.shared
    private var meterTimer: Timer?

    // ===== بيانات خيط المعالجة (proc) =====
    private let proc = DispatchQueue(label: "sawt.proc", qos: .userInteractive)
    private var vad: VoiceDetector?
    private var preRoll: [Float] = []
    private var utter: [Float] = []
    private var inSpeech = false
    private var speechRun = 0
    private var silenceRun = 0
    private var voicedWindows = 0
    private var aiActive = false
    private var procMuted = false
    private var patienceMs: Double = 870
    private var specTask: Task<(String, String), Never>?
    private var specText: String?
    private let windowMs = 32.0

    // ===== بيانات الرد (main) =====
    private var responseTask: Task<Void, Never>?
    private var sentenceCont: AsyncStream<String>.Continuation?
    private var speakTask: Task<Void, Never>?
    private var enqueued = 0
    private var played = 0
    private var llmDone = false
    /// كل الجمل اتحولت صوت (عشان ما نرجع نسمع والصوت لسا يتجهز)
    private var ttsDone = true
    private var lastMemBlock = ""
    private var spokenSoFar = ""
    private var carryUserText = ""
    private var replyID = 0

    // MARK: بدء وإنهاء

    @MainActor func start(seed: [Turn] = []) {
        guard state == .idle else { return }
        turns = seed
        let mm = ModelManager.shared
        guard mm.allReady else {
            error = mm.llm.isBusy || mm.stt.isBusy
                ? "النماذج للحين تتجهز، لحظات وجرّب."
                : "نزّل نموذج المحادثة ونموذج السمع من شاشة النماذج أول."
            mm.loadAll()
            return
        }
        state = .starting
        let patience = AppSettings.shared.patience
        Task { @MainActor in
            let granted = await AVAudioApplicationShim.requestRecord()
            guard granted else {
                self.error = "اسمح للتطبيق يستخدم المايك من الإعدادات."
                self.state = .idle
                return
            }
            if let why = AppleSTT.blockedReason {
                self.error = why
                self.state = .idle
                return
            }
            // نجهز الصوت هنا (مو وقت فتح التطبيق) عشان الذاكرة
            self.debug.stage = "يجهّز الصوت"
            slog("call: preparing voice")
            self.lastMemBlock = ""
            await ModelManager.shared.ensureTextMode()
            await LLMService.shared.resetCallSession()
            slog.stage("call:tts-load")
            await ModelManager.shared.prepareVoice()
            slog.stage("call:listening")
            let avail = RAM.availableMB
            let persona = AppSettings.shared.systemPrompt(chat: false, query: "", memory: false)
            Task { await LLMService.shared.warmup(system: persona) }
            slog("call: after voice load footprint=\(RAM.footprintMB)MB avail=\(avail)MB")
            if avail < 1500, !AppSettings.shared.llmID.lowercased().contains("2b") {
                self.error = "الذاكرة قليلة لهالنموذج في المكالمة (باقي \(avail)MB). إذا انقفل التطبيق، جرّب Qwen3.5 2B."
            }
            guard self.state == .starting else { return }
            CallController.isActive = true
            MemoryStore.shared.cancel()
            self.proc.sync {
                self.vad = VoiceDetector()
                self.resetProc()
                // مهلة أطول: الافتراضي حوالي ثانية قبل ما نعتبره خلص
                self.patienceMs = 650 + patience * 700
            }
            self.audio.onMic = { [weak self] samples in
                guard let self else { return }
                self.proc.async { self.handleMic(samples) }
            }
            self.audio.onStateChange = { [weak self] ok in
                guard let self, self.state != .idle else { return }
                if ok {
                    self.proc.async { self.resetProc() }
                    self.state = .listening
                } else {
                    self.cancelReply(recordPartial: true)
                    self.error = "انقطع الصوت (مكالمة أو تغيّر السماعة). إذا ما رجع، سكّر المكالمة وافتحها."
                }
            }
            do {
                Speaker.shared.stop()
                try self.audio.start()
                self.audio.ownedByCall = true
            } catch {
                self.error = "ما قدرت أشغّل المايك: \(error.localizedDescription)"
                self.state = .idle
                return
            }
            self.state = .listening
            slog("call: started, stt=\(AppSettings.shared.sttID) llm=\(AppSettings.shared.llmID)")
            // 15 مرة بالثانية تكفي للرسوم، وأخف على البطارية والحرارة
            self.meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.micLevel = self.muted ? 0 : self.audio.micLevel
                    self.outLevel = self.audio.outLevel
                    self.tick += 1
                    var d = self.debug
                    d.stage = "\(self.state)"
                    let (db, sp) = self.proc.sync { (self.procDB, self.procSpeech) }
                    d.micDB = db
                    d.vadSpeech = sp
                    if self.tick % 8 == 0 {
                        d.ramMB = RAM.footprintMB
                        d.availMB = RAM.availableMB
                        d.thermal = ThermalWatch.label
                    }
                    if d != self.debug { self.debug = d }
                }
            }
        }
    }

    /// هل فيه مكالمة شغالة (عشان استخراج الذاكرة ما يزاحمها).
    static var isActive = false

    func end() {
        cancelReply(recordPartial: true)
        if cameraOn { cameraOn = false }
        Task { @MainActor in CallCamera.shared.stop() }
        CallController.isActive = false
        // استخراج الذاكرة بعد المكالمة
        var pairs: [(user: String, assistant: String)] = []
        var lastUser: String?
        for t in turns {
            if t.role == .user { lastUser = (lastUser.map { $0 + " " } ?? "") + t.text }
            else if let u = lastUser { pairs.append((u, t.text)); lastUser = nil }
        }
        if let u = lastUser { pairs.append((u, "")) }
        let recent = Array(pairs.suffix(6))
        Task { @MainActor in MemoryStore.shared.extractLater(exchanges: recent) }
        Task { await LLMService.shared.resetCallSession() }
        // نفك الصوت من الذاكرة لو ما رجعت للمكالمة خلال دقيقة
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if !CallController.isActive { SpeechSynth.shared.unload(); ModelManager.shared.voiceIdle() }
        }
        audio.onMic = nil
        audio.onStateChange = nil
        audio.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        proc.sync { resetProc() }
        state = .idle
        slog.stage("idle")
        fragmentTimer?.cancel()
        fragmentTimer = nil
        userTalking = false
        carryUserText = ""
        liveUser = ""
        liveAI = ""
        micLevel = 0
        outLevel = 0
    }

    /// يشغّل/يطفي الكاميرا. التشغيل يحوّل النموذج لوضع النظر (إذا يدعمه) ويبدأ جلسة جديدة.
    @MainActor func toggleCamera() async {
        if cameraOn {
            cameraOn = false
            CallCamera.shared.stop()
            slog("call: camera off")
            return
        }
        guard AppSettings.shared.llm.vision else {
            error = "النموذج الحالي ما يشوف الصور. اختر نموذج عليه رمز العين (مثل Qwen3.5 أو Gemma) من شاشة النماذج."
            return
        }
        cameraBusy = true
        defer { cameraBusy = false }
        guard await CallCamera.shared.start() else {
            error = "ما قدرت أشغّل الكاميرا. تأكد إن التطبيق مسموح له يستخدمها من الإعدادات."
            return
        }
        cancelReply(recordPartial: true)
        let ok = await ModelManager.shared.ensureVision()
        await LLMService.shared.resetCallSession()   // النموذج تغيّر: الجلسة القديمة ما تصلح
        lastMemBlock = ""
        guard ok, state != .idle else {
            CallCamera.shared.stop()
            if state != .idle { error = "ما قدرت أجهّز وضع النظر (ممكن الذاكرة ما تكفي). كمّل المكالمة بدون كاميرا." }
            return
        }
        cameraOn = true
        slog("call: camera on")
    }

    func toggleMute() {
        muted.toggle()
        let m = muted
        proc.async { self.procMuted = m; if m { self.resetProc(keepAI: true) } }
    }

    /// يقطع كلام الذكاء يدويًا (زر).
    func interrupt() {
        guard state == .thinking || state == .speaking else { return }
        cancelReply(recordPartial: true)
        state = .listening
    }

    func clearConversation() {
        turns.removeAll()
        carryUserText = ""
    }

    // MARK: معالجة المايك (proc)

    private func resetProc(keepAI: Bool = false) {
        preRoll.removeAll()
        utter.removeAll()
        inSpeech = false
        speechRun = 0
        silenceRun = 0
        voicedWindows = 0
        specTask?.cancel()
        specTask = nil
        specText = nil
        appleStream?.cancel()
        appleStream = nil
        if !keepAI { aiActive = false }
        vad?.reset()
    }

    private func handleMic(_ samples: [Float]) {
        guard !procMuted, let vad else { return }
        preRoll.append(contentsOf: samples)
        if preRoll.count > 9_600 { preRoll.removeFirst(preRoll.count - 9_600) } // 0.6 ثانية
        if inSpeech {
            utter.append(contentsOf: samples)
            appleStream?.append(samples)
        }

        for (speech, db) in vad.process(samples) {
            procDB = db
            procSpeech = speech
            if !inSpeech {
                // أثناء كلام الذكاء نحتاج دليل أقوى عشان ما يقاطع نفسه من بقايا الصدى
                // وقت ما الذكاء يتكلم (أو بعد ما خلصت كلامك بشوي) نحتاج صوت أعلى وأطول عشان الصدى والضجة ما تفتح دور
                let need = aiActive ? 10 : 4
                let loudEnough = aiActive ? db > -40 : db > -52
                speechRun = (speech && loudEnough) ? speechRun + 1 : 0
                if speechRun >= need {
                    inSpeech = true
                    utter = preRoll
                    silenceRun = 0
                    voicedWindows = speechRun
                    speechRun = 0
                    let barge = aiActive
                    aiActive = false
                    startAppleStream()
                    DispatchQueue.main.async { self.userStarted(bargeIn: barge) }
                }
                continue
            }

            if speech {
                voicedWindows += 1
                if silenceRun > 0 {
                    silenceRun = 0
                    // رجع يتكلم: نلغي النسخ المسبق
                    specTask?.cancel(); specTask = nil; specText = nil
                }
                continue
            }

            silenceRun += 1
            let silenceMs = Double(silenceRun) * windowMs
            if silenceMs >= 280, specTask == nil, appleStream == nil, voicedWindows >= 6 {
                startSpeculative()
            }
            var endMs = patienceMs
            if let t = specText?.trimmingCharacters(in: .whitespaces) {
                if let last = t.last, "؟?.!".contains(last) { endMs *= 0.65 }
                if TurnHeuristics.soundsUnfinished(t) { endMs *= 1.8 }
                else if appleStream != nil, !t.isEmpty, !TurnHeuristics.isFragment(t) {
                    // النص الجزئي واضح وكامل: ننهي الدور أسرع
                    endMs = max(600, endMs * 0.7)
                }
            }
            let tooLong = utter.count > 16_000 * 25
            // لازم كلام كافي (حوالي ثلث ثانية) قبل ما ننهي الدور، عشان كلمة أو نفس ما يطلق رد
            let enoughSpeech = voicedWindows >= 10
            if tooLong || (silenceMs >= endMs && enoughSpeech) {
                commitTurn()
            } else if silenceMs >= 1_800, !enoughSpeech {
                // صوت قصير جدًا (كحة أو طقة): نتجاهله
                inSpeech = false
                utter.removeAll()
                appleStream?.cancel()
                appleStream = nil
                DispatchQueue.main.async { self.userCancelled() }
            }
        }
    }

    /// يبدأ بث تمييز آبل لهالدور (على خيط المعالجة).
    private func startAppleStream() {
        appleStream?.cancel()
        appleStream = nil
        guard (UserDefaults.standard.string(forKey: "sttID") ?? "apple") == "apple" else { return }
        let s = AppleStream()
        s.onPartial = { [weak self] text in
            guard let self else { return }
            self.proc.async { if self.appleStream === s { self.specText = text } }
            DispatchQueue.main.async { if !text.isEmpty { self.liveUser = text } }
        }
        guard s.start(language: Self.whisperLanguage()) else { slog("stt: apple stream unavailable"); return }
        s.append(utter)
        appleStream = s
    }

    private func startSpeculative() {
        let snapshot = utter
        slog("stt: speculative \(snapshot.count / 16)ms")
        let lang = Self.whisperLanguage()
        let task = Task<(String, String), Never> {
            let r = try? await SpeechRecognizer.shared.transcribe(snapshot, language: lang)
            return (r?.text ?? "", r?.language ?? "ar")
        }
        specTask = task
        Task {
            let r = await task.value
            self.proc.async {
                if self.specTask == task { self.specText = r.0 }
            }
            await MainActor.run { if !r.0.isEmpty { self.liveUser = r.0 } }
        }
    }

    private func commitTurn() {
        inSpeech = false
        DispatchQueue.main.async { self.userTalking = false }
        slog("turn: commit \(utter.count / 16)ms audio, spec=\(specTask != nil)")
        let audioCopy = utter
        utter.removeAll()
        let spec = specTask
        specTask = nil
        specText = nil
        let stream = appleStream
        appleStream = nil
        aiActive = true
        let lang = Self.whisperLanguage()
        let t0 = Date()
        Task {
            var result: (String, String)
            if let stream {
                slog.stage("call:stt")
                let text = await stream.finish()
                result = (text, lang ?? "ar")
            } else if let spec, !spec.isCancelled {
                result = await spec.value
            } else {
                slog.stage("call:stt")
                if let reload = await self.pendingSTTReload() { await reload.value }
                let r = try? await SpeechRecognizer.shared.transcribe(audioCopy, language: lang)
                result = (r?.text ?? "", r?.language ?? "ar")
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            slog("stt: done in \(ms)ms → \(result.0)")
            await MainActor.run {
                self.debug.sttMs = ms
                self.debug.lastTranscript = result.0.isEmpty ? "(ما فهم شي)" : result.0
                self.userFinished(text: result.0)
            }
        }
    }

    nonisolated private static func whisperLanguage() -> String? {
        let l = UserDefaults.standard.string(forKey: "language") ?? "auto"
        return l == "auto" ? nil : l
    }

    // MARK: أحداث المستخدم (main)

    private func userStarted(bargeIn: Bool) {
        slog("vad: user started speaking\(bargeIn ? " (barge-in)" : "")")
        if bargeIn || state == .thinking || state == .speaking {
            cancelReply(recordPartial: true)
        }
        fragmentTimer?.cancel()
        fragmentTimer = nil
        userTalking = true
        if carryUserText.isEmpty { liveUser = "" }
        state = .hearing
    }

    private func userCancelled() {
        userTalking = false
        if state == .hearing { state = carryUserText.isEmpty ? .listening : .hearing }
        if !carryUserText.isEmpty { scheduleFragmentFlush() }
    }

    /// إذا قال كلمة وحدة أو جملة ناقصة وسكت، نستنى شوي ثم نرد على اللي قاله.
    private func scheduleFragmentFlush() {
        fragmentTimer?.cancel()
        fragmentTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, !self.userTalking, !self.carryUserText.isEmpty else { return }
            slog("turn: fragment wait over → reply")
            self.userFinished(text: "", force: true)
        }
    }

    private func userFinished(text: String, force: Bool = false) {
        // رجع يتكلم قبل ما يوصل النص: نخزنه ونضيفه لكلامه الجاي بدل ما نرد مرتين
        if userTalking {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { carryUserText += (carryUserText.isEmpty ? "" : " ") + t }
            slog("turn: carried (user speaking again)")
            return
        }
        guard state != .idle, state != .starting else { return }
        let joined = ((carryUserText.isEmpty ? "" : carryUserText + " ") + text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // جملة ناقصة أو كلمة وحدة: نخليه يكمل بدل ما نرد على طول
        if !force, !joined.isEmpty, TurnHeuristics.isFragment(joined) {
            carryUserText = joined
            liveUser = joined
            state = .hearing
            slog("turn: fragment \"\(joined)\" → waiting")
            scheduleFragmentFlush()
            return
        }
        fragmentTimer?.cancel()
        fragmentTimer = nil
        let full = (carryUserText.isEmpty ? "" : carryUserText + " ") + text
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        carryUserText = ""
        liveUser = ""
        guard !trimmed.isEmpty else {
            proc.async { self.aiActive = false }
            state = .listening
            return
        }
        turns.append(Turn(role: .user, text: trimmed))
        reply(to: trimmed)
    }

    // MARK: الرد

    private func history() -> [Chat.Message] {
        // آخر الأدوار بحد ~4000 حرف (ذاكرة وسرعة)
        var msgs: [Chat.Message] = []
        var budget = 4000
        for t in turns.dropLast().suffix(16).reversed() {
            budget -= t.text.count
            if budget < 0, !msgs.isEmpty { break }
            msgs.insert(t.role == .user ? .user(t.text) : .assistant(t.text), at: 0)
        }
        return msgs
    }

    private func reply(to text: String) {
        stopReplyTasks()
        replyID += 1
        let myID = replyID
        state = .thinking
        turnStart = Date()
        debug.firstTokenMs = 0
        debug.firstAudioMs = 0
        slog("llm: start")
        liveAI = ""
        enqueued = 0
        played = 0
        llmDone = false
        ttsDone = false
        spokenSoFar = ""
        proc.async { self.aiActive = true }

        let settings = AppSettings.shared
        let voice = settings.voice
        let rate = settings.speechRate
        let hist = history()
        // التعليمات ثابتة (الجلسة تنعاد استخدامها)، والذاكرة المناسبة تنحط مع كل دور
        let system = settings.systemPrompt(chat: false, query: "", memory: false)
        let mem = MemoryStore.promptBlock(for: text, limit: 4)
        // الكاميرا شغالة: نلتقط إطار واحد مصغّر مع نهاية كلامك
        let frame: URL? = cameraOn ? CallCamera.shared.snapshot() : nil


        var cont: AsyncStream<String>.Continuation!
        let sentences = AsyncStream<String> { cont = $0 }
        sentenceCont = cont

        // مستهلك الجمل: يحوّل كل جملة لصوت بالترتيب ويجدولها
        speakTask = Task { @MainActor in
            for await sentence in sentences {
                if Task.isCancelled || myID != self.replyID { break }
                slog.stage("call:tts")
                let audioOut = await SpeechSynth.shared.synthesize(sentence, voice: voice, rate: rate)
                if Task.isCancelled || myID != self.replyID { break }
                guard !audioOut.samples.isEmpty else { continue }
                self.enqueued += 1
                if self.state == .thinking {
                    self.state = .speaking
                    slog.stage("call:speaking")
                    self.debug.firstAudioMs = Int(Date().timeIntervalSince(self.turnStart) * 1000)
                    slog("tts: first audio after \(self.debug.firstAudioMs)ms")
                }
                self.audio.enqueue(samples: audioOut.samples, sampleRate: audioOut.rate) { [weak self] in
                    Task { @MainActor in
                        guard let self, myID == self.replyID else { return }
                        self.played += 1
                        self.spokenSoFar += (self.spokenSoFar.isEmpty ? "" : " ") + sentence
                        self.checkReplyFinished()
                    }
                }
            }
        }

        responseTask = Task { @MainActor in
            var full = ""
            var pending = ""
            var first = true
            do {
                try await self.makeRoomForLLM()
                // نضيف الذاكرة بس إذا تغيّرت، أو إذا الجلسة جديدة (بعد مقاطعة أو خطأ أو جلسة طويلة)
                if !(await LLMService.shared.hasCallSession) { self.lastMemBlock = "" }
                var userText = (mem.isEmpty || mem == self.lastMemBlock) ? text : "[\(mem)]\n\n\(text)"
                if frame != nil {
                    userText = "[مرفقة صورة من كاميرا المستخدم الحين. استخدمها إذا كلامه عنها، وصف باختصار.]\n" + userText
                }
                if !mem.isEmpty { self.lastMemBlock = mem }
                slog.stage("call:llm")
                let stream = try await LLMService.shared.stream(system: system, history: hist, user: userText, maxTokens: 300, reuse: true,
                                                                images: frame.map { [$0] } ?? [])
                for try await chunk in stream {
                    if Task.isCancelled || myID != self.replyID { break }
                    if full.isEmpty {
                        self.debug.firstTokenMs = Int(Date().timeIntervalSince(self.turnStart) * 1000)
                        slog("llm: first token after \(self.debug.firstTokenMs)ms")
                    }
                    full += chunk
                    pending += chunk
                    self.liveAI = full
                    let (ready, rest) = TextCleaner.splitSentences(pending, first: first)
                    pending = rest
                    for s in ready { cont.yield(s); first = false }
                }
                if myID == self.replyID {
                    let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { cont.yield(tail) }
                }
            } catch {
                slog("llm: error \(error)")
                if myID == self.replyID { self.error = SawtError.friendly(error).localizedDescription }
            }
            cont.finish()
            guard myID == self.replyID else { return }
            let answer = TextCleaner.forSpeech(full)
            if !answer.isEmpty { self.turns.append(Turn(role: .assistant, text: answer)) }
            self.liveAI = ""
            self.llmDone = true
            await self.speakTask?.value
            if myID == self.replyID { self.ttsDone = true }
            self.checkReplyFinished()
        }
    }

    /// يوقف أي رد شغال بدون ما يعدّل المحادثة (عشان ما يشتغل ردّين مع بعض أبدًا).
    private func stopReplyTasks() {
        guard responseTask != nil || speakTask != nil else { return }
        replyID += 1
        responseTask?.cancel()
        speakTask?.cancel()
        sentenceCont?.finish()
        responseTask = nil
        speakTask = nil
        sentenceCont = nil
        audio.stopPlayback()
    }

    @MainActor private func pendingSTTReload() -> Task<Void, Never>? {
        if sttUnloaded {
            sttUnloaded = false
            slog("mem: reloading stt")
            sttReload = ModelManager.shared.loadSTT()
        }
        return sttReload
    }

    /// قبل التوليد: نتأكد فيه ذاكرة تكفي، وإلا نفك السمع مؤقتًا، وإلا نوقف برسالة بدل ما ينقفل التطبيق.
    @MainActor private func makeRoomForLLM() async throws {
        await LLMService.shared.trim()
        var avail = RAM.availableMB
        slog("mem: before llm footprint=\(RAM.footprintMB)MB avail=\(avail)MB")
        if avail < 1500, AppSettings.shared.sttID != "apple", !sttUnloaded {
            await SpeechRecognizer.shared.unload()
            sttUnloaded = true
            avail = RAM.availableMB
            slog("mem: unloaded stt for generation → avail=\(avail)MB")
        }
        if avail < 600 {
            let name = AppSettings.shared.llm.title
            throw SawtError.failed("الذاكرة ما تكفي لتشغيل \(name) في المكالمة (باقي \(avail)MB). جرّب Qwen3.5 2B أو سمع آبل.")
        }
    }

    private func checkReplyFinished() {
        guard llmDone, ttsDone, played >= enqueued, state == .thinking || state == .speaking else { return }
        state = .listening
        slog.stage("call:listening")
        Task { @MainActor in _ = self.pendingSTTReload() }
        proc.async { self.aiActive = false }
    }

    /// يوقف الرد الحالي. إذا ما بدأ يتكلم، نخلي كلام المستخدم يتجمع مع اللي بعده.
    private func cancelReply(recordPartial: Bool) {
        lastMemBlock = ""
        guard responseTask != nil || speakTask != nil else { return }
        let wasSpeaking = played > 0 || enqueued > 0
        replyID += 1
        responseTask?.cancel()
        speakTask?.cancel()
        sentenceCont?.finish()
        responseTask = nil
        speakTask = nil
        sentenceCont = nil
        audio.stopPlayback()
        proc.async { self.aiActive = false }

        if !llmDone {
            if wasSpeaking, recordPartial {
                let said = spokenSoFar.isEmpty ? liveAI : spokenSoFar
                if !said.isEmpty { turns.append(Turn(role: .assistant, text: said + "…", interrupted: true)) }
            } else if !wasSpeaking, let last = turns.last, last.role == .user {
                // ما لحق يرد: نعتبر الكلام الجديد تكملة للسابق
                carryUserText = last.text
                turns.removeLast()
            }
        } else if let i = turns.lastIndex(where: { $0.role == .assistant }), recordPartial,
                  played < enqueued, !spokenSoFar.isEmpty {
            turns[i].text = spokenSoFar + "…"
            turns[i].interrupted = true
        }
        liveAI = ""
        llmDone = true
        ttsDone = true
    }
}

