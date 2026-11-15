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

    func start() {
        guard listener == nil else { return }
        do {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47123)
            p.allowLocalEndpointReuse = true
            let l = try NWListener(using: p)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                slog("share: listener \(st)")
                if case .failed = st {
                    // نعيد تشغيل المستمع بعد ثانية
                    l.cancel()
                    self?.q.asyncAfter(deadline: .now() + 1) { self?.listener = nil; self?.start() }
                }
            }
            l.start(queue: q)
            listener = l
        } catch { slog("share: listen failed \(error)") }
    }

    private func accept(_ c: NWConnection) {
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
