import Foundation
import SwiftUI

/// يتحقق من وجود إصدار أحدث بقراءة ملف عام صغير (بدون أي توكن أو بيانات عن المستخدم).
/// المستودع الرئيسي خاص، فالـCI ينشر update.json في مستودع عام منفصل.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let feed = URL(string: "https://raw.githubusercontent.com/za7ef/sawt-releases/main/update.json")!

    struct Info: Codable, Identifiable {
        var version: String
        var build: Int
        var notes: String?
        var url: String
        var id: Int { build }
    }

    @Published var available: Info?
    @Published var lastMessage: String?
    private let d = UserDefaults.standard

    func check(force: Bool = false) async {
        let now = Date().timeIntervalSince1970
        if !force {
            if now - d.double(forKey: "updLastCheck") < 86_400 { return }
            if now < d.double(forKey: "updSnoozeUntil") { return }
        }
        d.set(now, forKey: "updLastCheck")
        var req = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if force { lastMessage = "ما قدرت أتحقق من التحديثات الحين." }
                return
            }
            let info = try JSONDecoder().decode(Info.self, from: data)
            if info.build > AppVersion.build {
                available = info
            } else if force {
                lastMessage = "عندك آخر إصدار (\(AppVersion.version) بناء \(AppVersion.build))."
            }
        } catch {
            if force { lastMessage = "ما قدرت أتحقق من التحديثات الحين." }
        }
    }

    func snooze() {
        d.set(Date().timeIntervalSince1970 + 86_400, forKey: "updSnoozeUntil")
        available = nil
    }
}

struct UpdateSheet: View {
    let info: UpdateChecker.Info
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.app.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text("تحديث جديد متوفر").font(.title3.bold())
                    Text("الإصدار \(info.version) (بناء \(info.build))").foregroundStyle(.secondary)
                    Text("عندك: \(AppVersion.version) (بناء \(AppVersion.build))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let n = info.notes, !n.isEmpty {
                Text("ما الجديد").font(.headline)
                ScrollView {
                    Text((try? AttributedString(markdown: n, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(n))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("لاحقًا") { UpdateChecker.shared.snooze() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("تحديث") {
                    if let u = URL(string: info.url) { openURL(u) }
                    UpdateChecker.shared.available = nil
                }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}
