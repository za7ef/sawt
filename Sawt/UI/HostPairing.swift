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

    func start() {
        guard !running else { return }
        running = true; pin = ""; result = ""
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
            keepAlive(true)
            status = "جاهز. روح للإعدادات واختر «Sawt» من الأجهزة القريبة للاقتران، وبيطلع لك رمز هنا وبإشعار."
            let res = await Task.detached { () -> String in
                HostPairing.call { c_accept(cfg, 300) }
            }.value
            Log.shared("hostpair accept: \(res.prefix(6000))")
            UIPasteboard.general.string = res
            if res.contains("\"paired\":true") {
                PhoneControl.pairingWritten()
                finish("تم الاقتران ✅ انحفظ ملف جديد. جرّب «فحص الاتصال».")
            } else {
                finish("ما تم الاقتران: \(res.prefix(800))")
            }
        }
    }

    func cancel() {
        #if SAWTCTL
        c_host_cancel()
        #endif
    }

    private func finish(_ msg: String) {
        service?.stop(); service = nil
        keepAlive(false)
        result = msg; status = ""; running = false
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in Log.shared("hostpair: bonjour publish failed \(errorDict)"); self.status = "ما قدرت أعلن الخدمة (الشبكة المحلية مسموحة؟) \(errorDict)" }
    }
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in Log.shared("hostpair: bonjour published \(sender.name)") }
    }

    /// صوت صامت عشان التطبيق يبقى صاحي وأنت في الإعدادات
    func keepAlive(_ on: Bool) {
        if on {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, options: [.mixWithOthers])
            try? s.setActive(true)
            let e = AVAudioEngine()
            let fmt = e.outputNode.inputFormat(forBus: 0)
            let player = AVAudioPlayerNode()
            e.attach(player); e.connect(player, to: e.mainMixerNode, format: fmt)
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate)) {
                buf.frameLength = buf.frameCapacity   // صفر = صمت
                player.scheduleBuffer(buf, at: nil, options: .loops)
            }
            try? e.start(); player.play()
            engine = e
        } else {
            engine?.stop(); engine = nil
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
