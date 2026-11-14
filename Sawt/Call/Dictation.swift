import Foundation
import SwiftUI

/// إملاء صوتي لخانة الكتابة: يسجّل لين تضغط إيقاف، بعدين يحوّل لنص.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var error: String?
    private var buffer: [Float] = []
    private let lock = NSLock()

    func start() {
        guard !isRecording else { return }
        if AudioIO.shared.isRunning {
            if AudioIO.shared.ownedByCall { error = "المايك مشغول بالمكالمة."; return }
            Speaker.shared.stop()
        }
        Task {
            guard await AVAudioApplicationShim.requestRecord() else {
                error = "اسمح للتطبيق يستخدم المايك من الإعدادات."
                return
            }
            lock.lock(); buffer.removeAll(); lock.unlock()
            AudioIO.shared.onMic = { [weak self] s in
                guard let self else { return }
                self.lock.lock(); self.buffer.append(contentsOf: s); self.lock.unlock()
            }
            do {
                try AudioIO.shared.start()
                isRecording = true
            } catch {
                AudioIO.shared.onMic = nil
                self.error = "ما قدرت أشغّل المايك: \(error.localizedDescription)"
                slog("dictation start failed \(error)")
            }
        }
    }

    func stop(_ done: @escaping (String) -> Void) {
        guard isRecording else { return }
        isRecording = false
        isBusy = true
        AudioIO.shared.onMic = nil
        AudioIO.shared.stop()
        lock.lock(); let audio = buffer; buffer.removeAll(); lock.unlock()
        let l = AppSettings.shared.language
        Task {
            let r = try? await SpeechRecognizer.shared.transcribe(audio, language: l == "auto" ? nil : l)
            isBusy = false
            if let t = r?.text, !t.isEmpty { done(t) }
        }
    }
}

/// قراءة رسالة بصوت (زر السماعة تحت الرد).
@MainActor
final class Speaker {
    static let shared = Speaker()
    private var task: Task<Void, Never>?
    private var startedEngine = false

    /// يشغّل عينات جاهزة (مثل تجربة صوت نماء).
    func play(samples: [Float], sampleRate: Double) {
        stop()
        guard !AudioIO.shared.ownedByCall, !samples.isEmpty else { return }
        task = Task {
            if !AudioIO.shared.isRunning {
                guard (try? AudioIO.shared.start()) != nil else { return }
                startedEngine = true
            }
            AudioIO.shared.enqueue(samples: samples, sampleRate: sampleRate)
            while AudioIO.shared.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            if startedEngine { AudioIO.shared.stop(); startedEngine = false }
        }
    }

    func speak(_ text: String, voice override: VoiceOption? = nil) {
        stop()
        let (parts, rest) = TextCleaner.splitSentences(text + "\n", first: false)
        let sentences = parts + (rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest])
        let voice = override ?? AppSettings.shared.voice
        let rate = AppSettings.shared.speechRate
        guard !AudioIO.shared.ownedByCall else { return }
        task = Task {
            if !AudioIO.shared.isRunning {
                guard (try? AudioIO.shared.start()) != nil else { return }
                startedEngine = true
            }
            for s in sentences {
                if Task.isCancelled { return }
                let a = await SpeechSynth.shared.synthesize(s, voice: voice, rate: rate)
                if Task.isCancelled { return }
                AudioIO.shared.enqueue(samples: a.samples, sampleRate: a.rate)
            }
            while AudioIO.shared.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            if startedEngine { AudioIO.shared.stop(); startedEngine = false }
        }
    }

    func stop() {
        let wasActive = task != nil || startedEngine
        task?.cancel()
        task = nil
        // ما نلمس المحرك إذا المكالمة هي اللي شغلته
        if wasActive, !AudioIO.shared.ownedByCall { AudioIO.shared.stopPlayback() }
        if startedEngine, !AudioIO.shared.ownedByCall { AudioIO.shared.stop() }
        startedEngine = false
    }
}
