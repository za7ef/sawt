import Foundation

/// أصوات ما ننشرها داخل التطبيق (رخصتها ما تسمح بإعادة التوزيع)، فتنزل من مصدرها الأصلي على جوالك لما تطلبها.
@MainActor
final class VoiceDownloads: ObservableObject {
    static let shared = VoiceDownloads()

    struct Item: Identifiable {
        let id: String          // نفس معرّف VoiceOption
        let folder: String
        let repo: String        // مستودع Hugging Face
        let files: [String]
        let approx: String
    }

    static let items: [Item] = [
        Item(id: "piper-miro", folder: "piper-miro", repo: "csukuangfj/vits-piper-ar_JO-SA_miro_V2-high-int8",
             files: ["ar_JO-SA_miro_V2-high.onnx", "tokens.txt"], approx: "~19 MB"),
    ]

    enum State: Equatable { case idle, downloading(Double), failed(String) }
    @Published var state: [String: State] = [:]

    static var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var u = d; try? u.setResourceValues(v)
        return d
    }

    func installed(_ item: Item) -> Bool {
        item.files.allSatisfy { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("\(item.folder)/\($0)").path) }
    }

    func download(_ item: Item) {
        if case .downloading = state[item.id] { return }
        state[item.id] = .downloading(0)
        Task {
            guard await NetworkGate.shared.permit("تنزيل صوت \(item.id == "piper-miro" ? "ميرو" : item.id)") else {
                state[item.id] = .idle; return
            }
            let dir = Self.root.appendingPathComponent(item.folder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, f) in item.files.enumerated() {
                    let url = URL(string: "https://huggingface.co/\(item.repo)/resolve/main/\(f)")!
                    let (tmp, resp) = try await URLSession.shared.download(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let dest = dir.appendingPathComponent(f)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    state[item.id] = .downloading(Double(i + 1) / Double(item.files.count))
                }
                state[item.id] = .idle
                slog("voice: downloaded \(item.id)")
                objectWillChange.send()
            } catch {
                try? FileManager.default.removeItem(at: dir)
                state[item.id] = .failed(SawtError.friendly(error).localizedDescription)
                slog("voice: download failed \(item.id) \(error)")
            }
        }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(item.folder))
        objectWillChange.send()
    }
}
