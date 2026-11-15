import ReplayKit
import CoreImage
import Network

/// إضافة «مشاركة الشاشة»: تاخذ إطار كل نص ثانية، تصغّره لـ٤٤٨ بكسل JPEG،
/// وترسله للتطبيق على 127.0.0.1:47123 (بدون App Group لأن التطبيق ينوقّع عند التثبيت).
/// الإطار: ٤ بايت طول (big-endian) + بيانات JPEG.
final class SampleHandler: RPBroadcastSampleHandler {
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private let q = DispatchQueue(label: "sawt.broadcast")
    private var conn: NWConnection?
    private var ready = false
    private var last = Date.distantPast
    private var busy = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) { connect() }
    override func broadcastFinished() { conn?.cancel(); conn = nil }

    private func connect() {
        conn?.cancel()
        ready = false
        let c = NWConnection(host: "127.0.0.1", port: 47123, using: .tcp)
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.ready = true
            case .waiting:
                // التطبيق مو مستمع: نلغي ونعيد (الإلغاء يوصلنا لـ.cancelled تحت)
                c.cancel()
            case .failed, .cancelled:
                self.ready = false
                // التطبيق ممكن مو مستمع الحين: نعيد بعد ثانيتين
                self.q.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.conn === c { self?.connect() } }
            default: break
            }
        }
        conn = c
        c.start(queue: q)
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, Date().timeIntervalSince(last) > 0.5, !busy, ready,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        last = Date(); busy = true
        var img = CIImage(cvPixelBuffer: pb)
        // اتجاه الشاشة
        if let o = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let ori = CGImagePropertyOrientation(rawValue: o.uint32Value) { img = img.oriented(ori) }
        let s = 448 / img.extent.width
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let jpeg = ctx.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
        guard let jpeg, let c = conn else { busy = false; return }
        var n = UInt32(jpeg.count).bigEndian
        var d = Data(bytes: &n, count: 4); d.append(jpeg)
        c.send(content: d, completion: .contentProcessed { [weak self] _ in self?.q.async { self?.busy = false } })
    }
}
