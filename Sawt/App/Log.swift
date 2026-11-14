import Foundation
import os
import UIKit

/// سجل بسيط للتشخيص: يحفظ آخر الأحداث في ملف عشان تقدر تصدّره.
final class Log: @unchecked Sendable {
    static let shared = Log()

    private let queue = DispatchQueue(label: "sawt.log")
    private var lines: [String] = []
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    let fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sawt-log.txt")

    init() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func callAsFunction(_ message: String) {
        let line = "\(df.string(from: Date())) [\(RAM.footprintMB)MB] \(message)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > 3000 { self.lines.removeFirst(500) }
        }
        #if DEBUG
        print(line)
        #endif
    }

    /// يكتب السجل مع معلومات الجهاز ويرجع رابط الملف.
    func export() -> URL {
        let header = """
        Sawt \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") \
        (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))
        iOS \(UIDevice.current.systemVersion) • RAM \(ProcessInfo.processInfo.physicalMemory / 1_048_576)MB
        thermal: \(ThermalWatch.label)
        footprint: \(RAM.footprintMB)MB • available: \(RAM.availableMB)MB
        settings: llm=\(AppSettings.shared.llmID) stt=\(AppSettings.shared.sttID) voice=\(AppSettings.shared.voiceID)
        ----

        """
        let body = queue.sync { lines.joined(separator: "\n") }
        try? (header + body).write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

let slog = Log.shared

enum RAM {
    /// الذاكرة اللي يستخدمها التطبيق فعليًا (نفس رقم النظام لما يقرر يقفل التطبيق).
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// كم باقي قبل ما النظام يقفل التطبيق.
    static var availableMB: Int { Int(os_proc_available_memory() / 1_048_576) }
}

enum ThermalWatch {
    static var isHot: Bool {
        let s = ProcessInfo.processInfo.thermalState
        return s == .serious || s == .critical
    }

    static var label: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "طبيعي"
        case .fair: return "دافي"
        case .serious: return "حار"
        case .critical: return "حار جدًا"
        @unknown default: return "؟"
        }
    }
}
