import Foundation
import SwiftUI

/// إملاء صوتي لخانة الكتابة: يسجّل لين تضغط إيقاف، بعدين يحوّل لنص.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var isBusy = false
    private var buffer: [Float] = []
    private let lock = NSLock()

    func start() {
        guard !isRecording, !AudioIO.shared.isRunning else { return }
        Task {
            guard await AVAudioApplicationShim.requestRecord() else { return }
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

    func speak(_ text: String) {
        stop()
        let (parts, rest) = TextCleaner.splitSentences(text + "\n", first: false)
        let sentences = parts + (rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest])
        let voice = AppSettings.shared.voice
        let rate = AppSettings.shared.speechRate
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
        task?.cancel()
        task = nil
        AudioIO.shared.stopPlayback()
        if startedEngine { AudioIO.shared.stop(); startedEngine = false }
    }
}
