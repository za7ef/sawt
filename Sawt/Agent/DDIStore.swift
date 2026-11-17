import Foundation
import UIKit
import CryptoKit

/// صورة المطوّر (DDI): خدمات القراءة واللمس وأطر XCTest ما تظهر إلا وهي مركّبة، وتبقى مركّبة لين يطفي الجوال.
/// نحمّلها مرة وحدة من النسخة العامة على GitHub (نفس مصدر StikDebug وPoki)، ونتحقق من كل ملف بـSHA-384
/// المكتوب في BuildManifest.plist، وبعدها sawtctl يركّبها: iOS 26.4 وأحدث عبر cryptexd، والأقدم عبر image mounter.
/// خادم Apple (TSS) يوقّع تذكرة لهذا الجهاز وقت التركيب، فأول تركيب بعد كل تشغيل للجوال يحتاج إنترنت.
@MainActor
final class DDIStore: ObservableObject {
    static let shared = DDIStore()

    enum Kind: String {
        case cryptex, personalized
        var folder: String { self == .cryptex ? "Xcode_iOS_DDI_Cryptex" : "Xcode_iOS_DDI_Personalized" }
        var files: [String] {
            let base = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
            return self == .cryptex ? base + ["Image.dmg.cryptex_info", "Image.dmg.root_hash"] : base
        }
        /// مفاتيح الملفات في BuildManifest (المسار والبصمة)
        var payloadKeys: [String] {
            self == .cryptex
                ? ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"]
                : ["PersonalizedDMG", "LoadableTrustCache"]
        }
    }

    @Published private(set) var status = ""
    @Published private(set) var busy = false

    private static let mirror = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/"

    // MARK: - معلومات الجهاز

    static var iosVersion: String { UIDevice.current.systemVersion }

    /// رقم البناء (مثل 23D5047e للتجريبي)
    static var iosBuild: String { sysctlString("kern.osversion") ?? "?" }

    /// من iOS 26.4: cryptex
    static var kind: Kind {
        let p = iosVersion.split(separator: ".").compactMap { Int($0) }
        let major = p.first ?? 0, minor = p.count > 1 ? p[1] : 0
        return (major, minor) >= (26, 4) ? .cryptex : .personalized
    }

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// نسخة الصورة المحمّلة (ProductBuildVersion في BuildManifest)
    static var imageBuild: String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("BuildManifest.plist")),
              let m = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return m["ProductBuildVersion"] as? String
    }

    static var filesPresent: Bool {
        kind.files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// سطر الإصدارات لـ«فحص الاتصال»
    static var versionLine: String {
        L("iOS %1$@ (%2$@) — صورة المطوّر: %3$@ (%4$@)", iosVersion, iosBuild,
          imageBuild ?? L("غير محمّلة"), kind == .cryptex ? "cryptex" : "personalized")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// وقت آخر تشغيل للجوال: الصورة تبقى مركّبة لين يتغيّر
    private static var bootTime: Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }

    private static let mountedBootKey = "ddiMountedBoot"

    // MARK: - التحميل والتحقق

    /// يتحقق من الملفات المحفوظة مقابل البصمات في BuildManifest. nil = سليمة، وإلا السبب.
    nonisolated static func verify(dir: URL, kind: Kind) -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("BuildManifest.plist")),
              let m = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ids = m["BuildIdentities"] as? [[String: Any]] else { return "BuildManifest.plist" }
        var hashes: [String: Data] = [:]
        func hash(_ path: String) -> Data? {
            if let h = hashes[path] { return h }
            guard let b = try? Data(contentsOf: dir.appendingPathComponent(path), options: .mappedIfSafe) else { return nil }
            let h = Data(SHA384.hash(data: b))
            hashes[path] = h
            return h
        }
        var sawIdentity = false
        for id in ids {
            guard let man = id["Manifest"] as? [String: Any] else { continue }
            let entries = kind.payloadKeys.compactMap { man[$0] as? [String: Any] }
            guard entries.count == kind.payloadKeys.count else { continue }
            sawIdentity = true
            let ok = entries.allSatisfy { e in
                guard let path = (e["Info"] as? [String: Any])?["Path"] as? String,
                      let digest = e["Digest"] as? Data else { return false }
                return hash(path) == digest
            }
            if ok { return nil }
        }
        return sawIdentity ? "SHA-384" : "BuildManifest.plist (\(kind.rawValue))"
    }

    /// ينزّل الملفات الناقصة ويتحقق منها. nil = جاهزة، وإلا رسالة الخطأ.
    func download(force: Bool = false, permitted: Bool = false) async -> String? {
        let kind = Self.kind, dir = Self.dir
        let fm = FileManager.default
        if !force, Self.filesPresent, Self.verify(dir: dir, kind: kind) == nil { return nil }
        if !permitted {
            let ok = await NetworkGate.shared.permit(L("تنزيل صورة المطوّر"))
            if !ok { return Self.netOff }
        }
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in kind.files.enumerated() {
            status = L("تنزيل صورة المطوّر (%1$@ من %2$@)…", String(i + 1), String(kind.files.count))
            guard let url = URL(string: Self.mirror + kind.folder + "/" + name) else { return L("تعذّر تنزيل صورة المطوّر: %@", name) }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    try? fm.removeItem(at: tmp)
                    return L("تعذّر تنزيل صورة المطوّر: %@", "\(name) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                let dest = dir.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                return L("تعذّر تنزيل صورة المطوّر: %@", "\(name): \(error.localizedDescription)")
            }
        }
        let bad = await Task.detached(priority: .userInitiated) { Self.verify(dir: dir, kind: kind) }.value
        if let bad {
            try? fm.removeItem(at: dir)
            return L("ملف صورة المطوّر غير سليم (%@)؛ حُذف ويمكن تنزيله مرة أخرى.", bad)
        }
        slog("ddi: downloaded \(kind.rawValue) build=\(Self.imageBuild ?? "?")")
        return nil
    }

    // MARK: - التركيب

    /// يتأكد إن الصورة مركّبة، وإلا ينزّلها ويركّبها. nil = جاهزة، وإلا سبب واضح.
    /// `force`: يتجاهل ذاكرة «مركّبة في هذا التشغيل» ويسأل الجهاز.
    func ensureMounted(force: Bool = false, permitted: Bool = false) async -> String? {
        let boot = Self.bootTime
        if !force, boot != 0, UserDefaults.standard.integer(forKey: Self.mountedBootKey) == boot { return nil }
        while busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        if !force, boot != 0, UserDefaults.standard.integer(forKey: Self.mountedBootKey) == boot { return nil }
        busy = true
        defer { busy = false; status = "" }

        status = L("التحقق من صورة المطوّر…")
        let st = await PhoneAgent.exec(.ddiStatus)
        let sj = Self.json(st)
        guard sj["ok"] as? Bool == true else {
            return L("تعذّر الاتصال بالجهاز (يجب أن يكون LocalDevVPN قيد التشغيل): %@", String(((sj["error"] as? String) ?? st).prefix(160)))
        }
        if sj["mounted"] as? Bool == true {
            UserDefaults.standard.set(boot, forKey: Self.mountedBootKey)
            slog("ddi: already mounted")
            return nil
        }
        // التنزيل وتوقيع Apple يحتاجان الإنترنت (يمر من بوابة الإنترنت في التطبيق)
        if !permitted && !NetworkGate.shared.on {
            let ok = await NetworkGate.shared.permit(L("تركيب صورة المطوّر"))
            if !ok { return Self.netOff }
        }
        if let e = await download(permitted: true) { return e }

        status = L("تركيب صورة المطوّر… (قد يستغرق دقيقة)")
        slog("ddi: mounting \(Self.kind.rawValue) ios=\(Self.iosVersion) build=\(Self.iosBuild) image=\(Self.imageBuild ?? "?")")
        let r = await PhoneAgent.exec(.ddiMount(Self.dir.path, Self.iosVersion))
        slog("ddi: mount \(r.prefix(1500))")
        let j = Self.json(r)
        if j["ok"] as? Bool == true {
            UserDefaults.standard.set(boot, forKey: Self.mountedBootKey)
            return nil
        }
        let err = (j["error"] as? String) ?? r
        if err.hasPrefix("ddi:ddi_bad") { try? FileManager.default.removeItem(at: Self.dir) }
        return Self.message(err)
    }

    static var netOff: String { L("الإنترنت مغلق؛ يلزم السماح به لتنزيل صورة المطوّر وتوقيعها من Apple.") }

    /// يحوّل رمز الخطأ من sawtctl لرسالة واضحة
    static func message(_ err: String) -> String {
        let detail = String(err.drop { $0 != " " }.dropFirst().prefix(140))
        if err.hasPrefix("ddi:developer_mode") { return L("وضع المطوّر غير مفعّل على الجهاز، أو أن خدمة تركيب صورة المطوّر غير متاحة.") }
        if err.hasPrefix("ddi:locked") { return L("الجهاز مقفل؛ يلزم فتح القفل ثم المحاولة مرة أخرى.") }
        if err.hasPrefix("ddi:tss") { return L("تعذّر توقيع صورة المطوّر من خادم Apple؛ يلزم اتصال بالإنترنت لا يمر عبر وكيل أو فلتر يحجب gs.apple.com. (%@)", detail) }
        if err.hasPrefix("ddi:ddi_bad") { return L("صورة المطوّر المحمّلة لا تناسب هذا الإصدار من iOS؛ حُذفت وسيُعاد تنزيلها في المحاولة التالية. (%@)", detail) }
        if err.hasPrefix("ddi:not_downloaded") { return L("صورة المطوّر غير محمّلة.") }
        if err.hasPrefix("ddi:not_visible") { return L("رُكّبت صورة المطوّر لكن خدماتها لم تظهر بعد؛ يمكن المحاولة مرة أخرى بعد لحظات.") }
        if err.hasPrefix("ddi:") { return L("تعذّر تركيب صورة المطوّر: %@", detail) }
        return L("تعذّر الاتصال بالجهاز (يجب أن يكون LocalDevVPN قيد التشغيل): %@", String(err.prefix(140)))
    }

    private static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}
