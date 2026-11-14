import Foundation
import MLXLMCommon
import SwiftUI

struct Turn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
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
            // نجهز الصوت هنا (مو وقت فتح التطبيق) عشان الذاكرة
            self.debug.stage = "يجهّز الصوت"
            slog("call: preparing voice")
            await ModelManager.shared.prepareVoice()
            guard self.state == .starting else { return }
            self.proc.sync {
                self.vad = VoiceDetector()
                self.resetProc()
                self.patienceMs = 450 + patience * 600
            }
            self.audio.onMic = { [weak self] samples in
                guard let self else { return }
                self.proc.async { self.handleMic(samples) }
            }
            do {
                try self.audio.start()
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

    func end() {
        cancelReply(recordPartial: true)
        audio.onMic = nil
        audio.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        proc.sync { resetProc() }
        state = .idle
        liveUser = ""
        liveAI = ""
        micLevel = 0
        outLevel = 0
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
        if !keepAI { aiActive = false }
        vad?.reset()
    }

    private func handleMic(_ samples: [Float]) {
        guard !procMuted, let vad else { return }
        preRoll.append(contentsOf: samples)
        if preRoll.count > 9_600 { preRoll.removeFirst(preRoll.count - 9_600) } // 0.6 ثانية
        if inSpeech { utter.append(contentsOf: samples) }

        for (speech, db) in vad.process(samples) {
            procDB = db
            procSpeech = speech
            if !inSpeech {
                // أثناء كلام الذكاء نحتاج دليل أقوى عشان ما يقاطع نفسه من بقايا الصدى
                let need = aiActive ? 7 : 3
                let loudEnough = aiActive ? db > -44 : true
                speechRun = (speech && loudEnough) ? speechRun + 1 : 0
                if speechRun >= need {
                    inSpeech = true
                    utter = preRoll
                    silenceRun = 0
                    voicedWindows = speechRun
                    speechRun = 0
                    let barge = aiActive
                    aiActive = false
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
            if silenceMs >= 280, specTask == nil, voicedWindows >= 6 {
                startSpeculative()
            }
            var endMs = patienceMs
            if let t = specText?.trimmingCharacters(in: .whitespaces) {
                if let last = t.last, "؟?.!".contains(last) { endMs *= 0.65 }
                if TurnHeuristics.soundsUnfinished(t) { endMs *= 1.8 }
            }
            let tooLong = utter.count > 16_000 * 25
            if silenceMs >= endMs || tooLong {
                commitTurn()
            } else if silenceMs >= 1_500, voicedWindows < 6 {
                // صوت قصير جدًا (كحة أو طقة): نتجاهله
                inSpeech = false
                utter.removeAll()
                DispatchQueue.main.async { self.userCancelled() }
            }
        }
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
        slog("turn: commit \(utter.count / 16)ms audio, spec=\(specTask != nil)")
        let audioCopy = utter
        utter.removeAll()
        let spec = specTask
        specTask = nil
        specText = nil
        aiActive = true
        let lang = Self.whisperLanguage()
        let t0 = Date()
        Task {
            var result: (String, String)
            if let spec, !spec.isCancelled {
                result = await spec.value
            } else {
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
        liveUser = ""
        state = .hearing
    }

    private func userCancelled() {
        if state == .hearing { state = .listening }
    }

    private func userFinished(text: String) {
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
        var msgs: [Chat.Message] = []
        for t in turns.dropLast().suffix(16) {
            msgs.append(t.role == .user ? .user(t.text) : .assistant(t.text))
        }
        return msgs
    }

    private func reply(to text: String) {
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
        spokenSoFar = ""
        proc.async { self.aiActive = true }

        let settings = AppSettings.shared
        let voice = settings.voice
        let rate = settings.speechRate
        let hist = history()
        let system = settings.persona

        var cont: AsyncStream<String>.Continuation!
        let sentences = AsyncStream<String> { cont = $0 }
        sentenceCont = cont

        // مستهلك الجمل: يحوّل كل جملة لصوت بالترتيب ويجدولها
        speakTask = Task { @MainActor in
            for await sentence in sentences {
                if Task.isCancelled || myID != self.replyID { break }
                let audioOut = await SpeechSynth.shared.synthesize(sentence, voice: voice, rate: rate)
                if Task.isCancelled || myID != self.replyID { break }
                guard !audioOut.samples.isEmpty else { continue }
                self.enqueued += 1
                if self.state == .thinking {
                    self.state = .speaking
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
                let stream = try await LLMService.shared.stream(system: system, history: hist, user: text)
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
            self.checkReplyFinished()
        }
    }

    private func checkReplyFinished() {
        guard llmDone, played >= enqueued, state == .thinking || state == .speaking else { return }
        state = .listening
        proc.async { self.aiActive = false }
    }

    /// يوقف الرد الحالي. إذا ما بدأ يتكلم، نخلي كلام المستخدم يتجمع مع اللي بعده.
    private func cancelReply(recordPartial: Bool) {
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
    }
}

enum TurnHeuristics {
    /// كلمات لو انتهى فيها الكلام غالبًا المتكلم ما خلص.
    static let fillers: [String] = [
        "و", "بس", "يعني", "لأن", "لان", "عشان", "اللي", "ثم", "او", "أو", "اذا", "إذا", "لكن",
        "اممم", "امم", "ام", "طيب", "في", "على", "من", "مع", "عن",
        "and", "but", "so", "because", "the", "a", "to", "of", "or", "um", "uh", "like", "with",
    ]

    static func soundsUnfinished(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard let last = t.split(separator: " ").last?.lowercased() else { return false }
        if text.hasSuffix("...") || text.hasSuffix("…") { return true }
        return fillers.contains(String(last))
    }
}
