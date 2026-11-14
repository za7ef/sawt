import Foundation

/// قراءة وكتابة ملفات JSON بأمان: كتابة متسلسلة خارج الخيط الرئيسي، حماية تسمح بالكتابة والجوال مقفّل
/// بعد أول فتح، ولو الملف خرب نحفظ نسخة احتياطية بدل ما نمسحه.
enum SafeFile {
    private static let queue = DispatchQueue(label: "sawt.safefile", qos: .utility)

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let bak = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: bak)
            slog("safefile: decode failed \(url.lastPathComponent), backup saved: \(error)")
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            catch { slog("safefile: write failed \(url.lastPathComponent): \(error)") }
        }
    }
}
