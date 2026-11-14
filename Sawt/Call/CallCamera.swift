import AVFoundation
import CoreImage
import SwiftUI
import UIKit
import ImageIO

/// كاميرا المكالمة: معاينة صغيرة، ونلتقط إطار واحد مصغّر عند نهاية كل دور كلام.
/// ما تلمس جلسة الصوت (المكالمة تملكها)، وتنطفي مع نهاية المكالمة أو لما يروح التطبيق للخلفية.
final class CallCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = CallCamera()

    @MainActor @Published private(set) var running = false
    @MainActor @Published private(set) var front = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sawt.camera")
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestAt = Date.distantPast
    private var configured = false
    private let ci = CIContext(options: [.cacheIntermediates: false])

    private override init() {
        super.init()
        session.automaticallyConfiguresApplicationAudioSession = false
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    @MainActor func start() async -> Bool {
        guard await Self.authorize() else { return false }
        let useFront = front
        let ok: Bool = await withCheckedContinuation { c in
            queue.async {
                c.resume(returning: self.configure(front: useFront))
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        running = ok && session.isRunning
        slog("camera: start ok=\(running) front=\(useFront)")
        return running
    }

    @MainActor func stop() {
        guard running else { return }
        running = false
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.lock.lock(); self.latest = nil; self.lock.unlock()
            // نمسح الإطارات المؤقتة
            let tmp = FileManager.default.temporaryDirectory
            for f in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where f.hasPrefix("call-frame-") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(f))
            }
        }
        slog("camera: stopped")
    }

    @MainActor func flip() {
        front.toggle()
        let f = front
        queue.async { _ = self.configure(front: f) }
    }

    /// يجهّز المدخل (أمامي/خلفي) والمخرج. يشتغل على خيط الكاميرا.
    private func configure(front: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480   // يكفي للنموذج، وأخف على الحرارة
        for i in session.inputs { session.removeInput(i) }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return false }
        session.addInput(input)
        // 15 إطار بالثانية تكفي للمعاينة
        if (try? dev.lockForConfiguration()) != nil {
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
            dev.unlockForConfiguration()
        }
        if !configured {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            configured = true
        }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = front }
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; latestAt = Date(); lock.unlock()
    }

    /// آخر إطار مصغّر (أطول ضلع 768) كملف JPEG مؤقت. nil إذا ما فيه إطار حديث.
    func snapshot(maxSide: CGFloat = 768) -> URL? {
        lock.lock(); let pb = latest; let at = latestAt; lock.unlock()
        guard let pb, Date().timeIntervalSince(at) < 2 else { return nil }
        var img = CIImage(cvPixelBuffer: pb)
        let scale = min(1, maxSide / max(img.extent.width, img.extent.height))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ci.jpegRepresentation(of: img, colorSpace: cs,
                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("call-frame-\(UUID().uuidString.prefix(8)).jpg")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// معاينة الكاميرا الصغيرة داخل المكالمة.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
