import Foundation
import AVFoundation
import UserNotifications
import UIKit

#if SAWTCTL
@_silgen_name("sawtctl_host_begin") private func c_host_begin(_ cfg: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_host_accept") private func c_host_accept(_ cfg: UnsafePointer<CChar>, _ timeout: UInt32, _ cb: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("sawtctl_host_cancel") private func c_host_cancel()
@_silgen_name("sawtctl_free") private func c_hfree(_ p: UnsafeMutablePointer<CChar>?)
#endif

/// اقتران يبدأه الجوال (iOS 27): صوت يعلن نفسه كـ"كمبيوتر" قريب، والجوال يتصل فيه من الإعدادات
/// ويطلب رمز، وصوت يعرض الرمز (وإشعار) ويحفظ ملف الاقتران.
@MainActor
final class HostPairing: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = HostPairing()

    @Published var running = false
    @Published var status = ""
    @Published var pin = ""
    @Published var result = ""

    private var service: NetService?
    private var engine: AVAudioEngine?

    private var pairAlive = false
    func start() {
        guard !running else { return }
        running = true; pin = ""; result = ""; pairAlive = false
        status = "أجهّز…"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let cfg = PhoneControl.config(host: "10.7.0.1", rpPort: 0, rpHost: "")
        Task {
            let begin = await Task.detached { () -> String in HostPairing.call { c_begin(cfg) } }.value
            Log.shared("hostpair begin: \(begin)")
            guard let d = try? JSONSerialization.jsonObject(with: Data(begin.utf8)) as? [String: Any],
                  d["ok"] as? Bool == true, let port = d["port"] as? Int, let ident = d["identifier"] as? String else {
                finish("ما قدرت أجهّز: \(begin.prefix(300))"); return
            }
            let txt = (d["txt"] as? [String: String]) ?? [:]
            let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: ident, port: Int32(port))
            s.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            s.delegate = self
            s.publish()
            service = s
            keepAlive(true); pairAlive = true
            status = "جاهز. روح للإعدادات واختر «Sawt» من الأجهزة القريبة للاقتران، وبيطلع لك رمز هنا وبإشعار."
            let res = await Task.detached { () -> String in
                HostPairing.call { c_accept(cfg, 300) }
            }.value
            Log.shared("hostpair accept: \(res.prefix(6000))")
            if res.contains("\"paired\":true") {
                PhoneControl.pairingWritten()
                finish("تم الاقتران ✅ انحفظ ملف جديد. جرّب «فحص الاتصال».")
            } else {
                finish("ما تم الاقتران: \(res.prefix(800))")
            }
        }
    }

    func cancel() {
        status = "أوقف…"
        #if SAWTCTL
        c_host_cancel()
        #endif
    }

    private func finish(_ msg: String) {
        service?.stop(); service = nil
        // بس لو شغّلناه (فشل التجهيز ما شغّله) — عشان العدّاد ما ينقص غلط
        if pairAlive { keepAlive(false); pairAlive = false }
        result = msg; status = ""; running = false
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in Log.shared("hostpair: bonjour publish failed \(errorDict)"); self.status = "ما قدرت أعلن الخدمة (الشبكة المحلية مسموحة؟) \(errorDict)" }
    }
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in Log.shared("hostpair: bonjour published \(sender.name)") }
    }

    /// صوت صامت عشان التطبيق يبقى صاحي وأنت في الإعدادات.
    /// بعدّاد (أكثر من مستخدم)، وما يغيّر جلسة الصوت لو فيه مكالمة (playAndRecord)، ويرجّع الإعداد القديم.
    private var aliveCount = 0
    private var player: AVAudioPlayerNode?
    private var savedAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var observers: [NSObjectProtocol] = []
    /// بعد مقاطعة (اتصال/سيري) أو تغيير السماعة: نرجّع المحرك يشتغل
    private func watchAudio() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, self.aliveCount > 0, let e = self.engine, let p = self.player else { return }
                    if n.name == AVAudioSession.interruptionNotification,
                       (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { return }
                    if !e.isRunning {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        do { try e.start(); p.play(); Log.shared("keepAlive: restarted after \(n.name.rawValue)") }
                        catch { Log.shared("keepAlive: restart failed \(error)") }
                    }
                }
            })
        }
    }

    func keepAlive(_ on: Bool) {
        if on {
            aliveCount += 1
            guard aliveCount == 1 else { return }
            watchAudio()
            let s = AVAudioSession.sharedInstance()
            if s.category == .playAndRecord {
                // المكالمة شغّالة: صوتها يكفي يخلي التطبيق صاحي — ما نلمس الجلسة
                Log.shared("keepAlive: call audio active, session untouched"); return
            }
            savedAudio = (s.category, s.mode, s.categoryOptions)
            try? s.setCategory(.playback, options: [.mixWithOthers])
            try? s.setActive(true)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p); e.connect(p, to: e.mainMixerNode, format: fmt)
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) {
                buf.frameLength = buf.frameCapacity   // صفر = صمت
                p.scheduleBuffer(buf, at: nil, options: .loops)
            }
            do { try e.start(); p.play(); engine = e; player = p }
            catch { Log.shared("keepAlive: engine start failed \(error)"); e.detach(p) }
        } else {
            guard aliveCount > 0 else { return }
            aliveCount -= 1
            guard aliveCount == 0 else { return }
            player?.stop()
            if let e = engine, let p = player { e.stop(); e.detach(p) }
            engine = nil; player = nil
            // نرجّع الجلسة بس لو محد غيّرها (مثلاً مكالمة بدأت بعدنا)
            let s = AVAudioSession.sharedInstance()
            if let sv = savedAudio, s.category == .playback {
                try? s.setCategory(sv.0, mode: sv.1, options: sv.2)
            }
            savedAudio = nil
        }
    }

    // يستدعيه Rust من خيطه
    nonisolated fileprivate static func gotPin(_ p: String) {
        Log.shared("hostpair: pin shown")
        let c = UNMutableNotificationContent()
        c.title = "رمز الاقتران"
        c.body = "اكتب الرمز في الجوال: \(p)"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sawt.pin", content: c, trigger: nil))
        Task { @MainActor in HostPairing.shared.pin = p; HostPairing.shared.status = "اكتب الرمز في الجوال" }
    }

    nonisolated private static func call(_ f: () -> UnsafeMutablePointer<CChar>?) -> String {
        #if SAWTCTL
        guard let p = f() else { return "{\"ok\":false,\"error\":\"null\"}" }
        let s = String(cString: p); c_hfree(p); return s
        #else
        return "{\"ok\":false,\"error\":\"أداة التحكم ما انبنت في هذي النسخة\"}"
        #endif
    }
}

private func c_begin(_ cfg: String) -> UnsafeMutablePointer<CChar>? {
    #if SAWTCTL
    return cfg.withCString { c_host_begin($0) }
    #else
    return nil
    #endif
}

private func c_accept(_ cfg: String, _ t: UInt32) -> UnsafeMutablePointer<CChar>? {
    #if SAWTCTL
    return cfg.withCString { c_host_accept($0, t, { p in
        guard let p else { return }
        HostPairing.gotPin(String(cString: p))
    }) }
    #else
    return nil
    #endif
}
