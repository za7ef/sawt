import AVFoundation

enum AVAudioApplicationShim {
    static func requestRecord() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }
}
