import Foundation
import os
import UIKit
import MetricKit

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

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// السجل الحي: يُكتب سطر سطر عشان يبقى حتى لو انقفل التطبيق فجأة.
    let liveURL = Log.dir.appendingPathComponent("current.txt")
    /// سجل التشغيلة السابقة (اللي ممكن انتهت بكراش).
    let prevURL = Log.dir.appendingPathComponent("previous.txt")
    let crashURL = Log.dir.appendingPathComponent("crash-reports.txt")
    let fileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("sawt-log.txt")
    private var handle: FileHandle?
    private var unsynced = 0

    /// وش كان التطبيق يسوي آخر شي (لو انقفل فجأة نعرف وين).
    private(set) var previousRunCrashed = false
    private(set) var previousStage = ""
    private let stageKey = "log.lastStage"

    init() {
        let fm = FileManager.default
        try? fm.removeItem(at: prevURL)
        if fm.fileExists(atPath: liveURL.path) { try? fm.moveItem(at: liveURL, to: prevURL) }
        fm.createFile(atPath: liveURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: liveURL)
        let d = UserDefaults.standard
        if let s = d.string(forKey: stageKey), !s.isEmpty, s != "idle" {
            previousRunCrashed = true
            previousStage = s
        }
        d.set("launch", forKey: stageKey)
    }

    /// يحدد المرحلة الحالية. "" = خروج نظيف.
    func stage(_ s: String) {
        UserDefaults.standard.set(s, forKey: stageKey)
    }

    func cleanExit() { stage("") }

    func callAsFunction(_ message: String) {
        let line = "\(df.string(from: Date())) [\(RAM.footprintMB)MB/\(RAM.availableMB)MB] \(message)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > 3000 { self.lines.removeFirst(500) }
            // write() يوصل للنظام مباشرة فيبقى حتى لو انقفل التطبيق؛ المزامنة للقرص كل 50 سطر بس (أخف)
            if let data = (line + "\n").data(using: .utf8) {
                try? self.handle?.write(contentsOf: data)
                self.unsynced += 1
                if self.unsynced >= 50 { try? self.handle?.synchronize(); self.unsynced = 0 }
            }
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
        var text = header + body
        if let prev = try? String(contentsOf: prevURL, encoding: .utf8), !prev.isEmpty {
            text += "\n\n==== التشغيلة السابقة\(previousRunCrashed ? " (انتهت فجأة عند: \(previousStage))" : "") ====\n"
            text += String(prev.suffix(200_000))
        }
        if let crash = try? String(contentsOf: crashURL, encoding: .utf8), !crash.isEmpty {
            // نقص من بداية تقرير كامل (ما نقطع راس التقرير اللي فيه نوع الكراش)
            var tail = String(crash.suffix(200_000))
            if tail.count < crash.count, let r = tail.range(of: "CRASH ") { tail = String(tail[r.lowerBound...]) }
            text += "\n\n==== تقارير الكراش من النظام ====\n" + tail
        }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
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

/// يستقبل تقارير الكراش والذاكرة من النظام (توصل غالبًا في التشغيلة اللي بعدها).
final class CrashCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashCollector()

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var out = ""
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                out += "CRASH \(c.metaData.applicationBuildVersion) signal=\(c.signal.map { "\($0)" } ?? "-") "
                out += "exception=\(c.exceptionType.map { "\($0)" } ?? "-") code=\(c.exceptionCode.map { "\($0)" } ?? "-")\n"
                out += "reason: \(c.terminationReason ?? "-")\n"
                // JSON مضغوط (المنسّق كان يطوّل التقرير لين ينقص راسه عند القص)
                let raw = c.callStackTree.jsonRepresentation()
                if let o = try? JSONSerialization.jsonObject(with: raw),
                   let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) {
                    out += String(data: d, encoding: .utf8) ?? ""
                } else {
                    out += String(data: raw, encoding: .utf8) ?? ""
                }
                out += "\nEND CRASH \(c.metaData.applicationBuildVersion)\n----\n"
            }
        }
        guard !out.isEmpty else { return }
        slog("metrickit: received crash diagnostics")
        let url = Log.shared.crashURL
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + out).write(to: url, atomically: true, encoding: .utf8)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            if let exits = p.applicationExitMetrics {
                let bg = exits.backgroundExitData, fg = exits.foregroundExitData
                slog("metrickit exits: fg memLimit=\(fg.cumulativeMemoryResourceLimitExitCount) crash=\(fg.cumulativeAbnormalExitCount) bg memLimit=\(bg.cumulativeMemoryResourceLimitExitCount)")
            }
        }
    }
}
