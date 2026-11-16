import Foundation
import Network
import ReplayKit
import SwiftUI

/// يستقبل إطارات «مشاركة الشاشة» من إضافة البث على 127.0.0.1:47123 ويحتفظ بآخر إطار
final class ScreenShare: @unchecked Sendable {
    static let shared = ScreenShare()
    private let q = DispatchQueue(label: "sawt.share")
    private var listener: NWListener?
    private let lock = NSLock()
    private var _frame: Data?
    private var _at = Date.distantPast
    private(set) var frames = 0

    /// آخر إطار لو عمره أقل من ٣ ثواني
    var latest: Data? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_at) < 3 ? _frame : nil
    }
    var live: Bool { latest != nil }

    private var backoff: Double = 1
    /// يشتغل على طابور الشبكة (ما فيه سباق على listener)
    func start() { q.async { self.startOnQueue() } }

    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47123)
            p.allowLocalEndpointReuse = true
            let l = try NWListener(using: p)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                slog("share: listener \(st)")
                switch st {
                case .ready: self.backoff = 1
                case .failed, .waiting:   // waiting: المنفذ مشغول/الشبكة مو جاهزة — نفس المعاملة
                    // نعيد بمهلة تتضاعف (١، ٢، ٤… لين ٣٠ ثانية)
                    l.cancel()
                    let d = self.backoff; self.backoff = min(self.backoff * 2, 30)
                    self.q.asyncAfter(deadline: .now() + d) { self.listener = nil; self.startOnQueue() }
                default: break
                }
            }
            l.start(queue: q)
            listener = l
        } catch { slog("share: listen failed \(error)") }
    }

    private var current: NWConnection?
    private func accept(_ c: NWConnection) {
        // اتصال واحد بس (الأحدث)، ومن الجهاز نفسه فقط
        if case let .hostPort(host, _) = c.endpoint, "\(host)" != "127.0.0.1" && "\(host)" != "::1" {
            slog("share: rejected non-loopback \(host)"); c.cancel(); return
        }
        current?.cancel(); current = c
        slog("share: extension connected")
        c.start(queue: q)
        readFrame(c)
    }

    private func readFrame(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] h, _, done, err in
            guard let self, let h, h.count == 4, err == nil else { c.cancel(); return }
            let n = Int(h.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard n > 0, n < 4_000_000 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in
                guard let d, d.count == n, e == nil else { c.cancel(); return }
                // لازم يكون JPEG (FF D8 … FF D9)؛ غيره نقفل الاتصال
                guard d.count > 4, d[d.startIndex] == 0xFF, d[d.startIndex + 1] == 0xD8 else { slog("share: rejected non-JPEG frame"); c.cancel(); return }
                self.lock.lock(); self._frame = d; self._at = Date(); self.frames += 1; self.lock.unlock()
                if !done { self.readFrame(c) }
            }
        }
    }
}

/// زر النظام «بدء البث» موجّه لإضافة صوت
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = "com.za7ef.sawt.broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}
