import SwiftUI
import Foundation
import Security

/// مفاتيح الخدمات السحابية: في سلسلة المفاتيح (Keychain) بس — ما تنحفظ في الإعدادات ولا تنكتب في السجل
enum KeyStore {
    private static let service = "com.za7ef.sawt.cloudkeys"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8)
        return (s?.isEmpty ?? true) ? nil : s
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        delete(account)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return true }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                // الجهاز هذا بس، وما ينسخ احتياطيًا لجهاز ثاني
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecValueData as String: Data(v.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// مزوّدو الوكيل السحابي (اختياري، بمفتاح المستخدم نفسه)
enum CloudProvider: String, CaseIterable, Identifiable {
    // مجاني
    case gemini, openrouter
    // مدفوع
    case openai, anthropic, geminiPaid
    var id: String { rawValue }

    static let free: [CloudProvider] = [.gemini, .openrouter]
    static let paid: [CloudProvider] = [.openai, .anthropic, .geminiPaid]
    var isFree: Bool { Self.free.contains(self) }
    /// Gemini الصيغة نفسها (مجاني أو مدفوع)؛ OpenRouter بصيغة OpenAI
    var isGemini: Bool { self == .gemini || self == .geminiPaid }

    var title: String {
        switch self {
        case .gemini: "Gemini (مفتاح AI Studio المجاني)"
        case .openrouter: "OpenRouter (نماذج :free)"
        case .openai: "ChatGPT (OpenAI)"
        case .anthropic: "Claude (Anthropic)"
        case .geminiPaid: "Gemini (مدفوع / Pro)"
        }
    }
    var short: String {
        switch self {
        case .gemini: "Gemini"; case .openrouter: "OpenRouter"; case .openai: "ChatGPT"
        case .anthropic: "Claude"; case .geminiPaid: "Gemini"
        }
    }
    /// النماذج الافتراضية (من صفحات النماذج الرسمية وقائمة OpenRouter، نوفمبر ٢٠٢٦) — تقدر تغيّرها
    var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.5-flash"
        case .openrouter: "google/gemma-4-31b-it:free"
        case .openai: "gpt-6.1-terra"
        case .anthropic: "claude-haiku-5-5"
        case .geminiPaid: "gemini-4-carbon"
        }
    }
    var keyURL: String {
        switch self {
        case .gemini, .geminiPaid: "https://aistudio.google.com/apikey"
        case .openrouter: "https://openrouter.ai/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .anthropic: "https://console.anthropic.com"
        }
    }
    /// ملاحظة الحدود
    var note: String {
        switch self {
        case .gemini: "مجاني بحد بالدقيقة وباليوم؛ لو خلص يوقف لين يتجدد. جوجل ممكن تستخدم بيانات الطبقة المجانية لتحسين خدماتها."
        case .openrouter: "نماذج :free مجانية بحد بالدقيقة وباليوم (أقل لو ما عندك رصيد)، وممكن تكون زحمة أو توقف. بدائل: nvidia/nemotron-3.5-super-vl:free، google/gemma-4-26b-a4b-it:free"
        case .openai: "مدفوع حسب الاستخدام من رصيد حسابك."
        case .anthropic: "مدفوع حسب الاستخدام من رصيد حسابك."
        case .geminiPaid: "مدفوع (حساب فيه فوترة)؛ نماذج Pro/Carbon ما لها طبقة مجانية."
        }
    }
    var key: String? { KeyStore.get("key." + rawValue) }
    var hasKey: Bool { key != nil }
    var model: String {
        let m = UserDefaults.standard.string(forKey: "cloudModel." + rawValue)?.trimmingCharacters(in: .whitespaces) ?? ""
        // الافتراضي القديم (3.8 عليه ضغط كثير ويرجع 503) → الافتراضي الجديد
        if self == .gemini, m == "gemini-3.8-flash" { UserDefaults.standard.removeObject(forKey: "cloudModel.gemini"); return defaultModel }
        return m.isEmpty ? defaultModel : m
    }
}

/// استدعاء واحد للوكيل السحابي: تعليمات + نص الشاشة + صورة (اختياري) → سطر JSON
enum CloudAgent {
    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var code: Int = 0
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// موديل احتياطي لـGemini المجاني لو الأساسي عليه ضغط (503)
    static let geminiFallback = "gemini-3.5-flash"

    static func ask(_ p: CloudProvider, system: String, user: String, image: URL?) async throws -> String {
        do { return try await askOnce(p, model: p.model, system: system, user: user, image: image) }
        catch let f as Failure where f.code == 503 && p.isGemini && p.model != geminiFallback {
            slog("agent: gemini 503 → fallback \(geminiFallback)")
            return try await askOnce(p, model: geminiFallback, system: system, user: user, image: image)
        }
    }

    private static func askOnce(_ p: CloudProvider, model: String, system: String, user: String, image: URL?) async throws -> String {
        guard let key = p.key else { throw Failure(message: "ما فيه مفتاح لـ\(p.short) — حطه في «مفاتيح الخدمات»") }
        let img = image.flatMap { try? Data(contentsOf: $0) }?.base64EncodedString()
        var req: URLRequest
        var body: [String: Any]
        switch p {
        case .openai, .openrouter:
            let or = p == .openrouter
            req = URLRequest(url: URL(string: or ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if or { req.setValue("Sawt", forHTTPHeaderField: "X-Title") }
            var content: [[String: Any]] = [["type": "text", "text": user + (or ? "\n\nرد بسطر JSON واحد فقط." : "")]]
            if let img { content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img)", "detail": "low"]]) }
            body = ["model": model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": content]]]
            if or { body["max_tokens"] = 2000 }   // بعض النماذج المجانية ما تدعم response_format
            else { body["response_format"] = ["type": "json_object"]; body["max_completion_tokens"] = 2000 }
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            if let img { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img]]) }
            content.append(["type": "text", "text": user + "\n\nرد بسطر JSON واحد فقط بدون أي كلام ثاني."])
            body = ["model": model, "max_tokens": 2000, "system": system,
                    "messages": [["role": "user", "content": content]]]
        case .gemini, .geminiPaid:
            let m = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var parts: [[String: Any]] = [["text": user]]
            if let img { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": img]]) }
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": parts]],
                    "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": 2048]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            let ns = error as NSError
            if ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost {
                throw Failure(message: "ما فيه إنترنت — الوكيل السحابي يحتاج اتصال")
            }
            if ns.code == NSURLErrorTimedOut { throw Failure(message: "\(p.short) ما رد خلال دقيقة") }
            throw Failure(message: "تعذّر الاتصال بـ\(p.short): \(ns.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200 else { throw Failure(message: errorText(p, code: code, json: json), code: code) }
        guard let json else { throw Failure(message: "رد غير مفهوم من \(p.short)") }

        var text = ""
        switch p {
        case .openai, .openrouter:
            let ch = (json["choices"] as? [[String: Any]])?.first
            text = ((ch?["message"] as? [String: Any])?["content"] as? String) ?? ""
            if text.isEmpty, (ch?["finish_reason"] as? String) == "length" { throw Failure(message: "\(p.short) خلّص حد الطول قبل ما يرد") }
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini, .geminiPaid:
            let cand = (json["candidates"] as? [[String: Any]])?.first
            let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            // نتجاهل أجزاء التفكير
            text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            if text.isEmpty, let r = cand?["finishReason"] as? String, r != "STOP" {
                throw Failure(message: r == "SAFETY" ? "Gemini رفض الطلب (فلتر الأمان)" : "Gemini وقف بدون رد (\(r))")
            }
        }
        return text
    }

    /// رسالة واضحة بالعربي حسب الخطأ (بدون المفتاح طبعًا)
    static func errorText(_ p: CloudProvider, code: Int, json: [String: Any]?) -> String {
        let err = json?["error"] as? [String: Any]
        let msg = (err?["message"] as? String ?? "").prefix(160)
        let status = err?["status"] as? String ?? err?["type"] as? String ?? ""
        switch code {
        case 401, 403:
            if p.isGemini, msg.lowercased().contains("location") { return "Gemini مو متاح في منطقتك بهالمفتاح" }
            return "مفتاح \(p.short) غلط أو ما له صلاحية — راجعه في «مفاتيح الخدمات»"
        case 404:
            return "اسم النموذج «\(p.model)» مو موجود عند \(p.short) — صحّحه في «مفاتيح الخدمات»"
        case 429:
            switch p {
            case .gemini:
                return "حد Gemini المجاني خلص (أو طلبات كثير ورا بعض) — استنى دقيقة، أو لين بكرة لو خلص الحد اليومي"
            case .geminiPaid:
                return "Gemini: وصلت حد الطلبات — استنى شوي وجرّب"
            case .openrouter:
                return "حد OpenRouter المجاني خلص أو النموذج زحمة — استنى دقيقة، أو جرّب نموذج :free ثاني"
            case .openai:
                if status.contains("insufficient_quota") || msg.contains("quota") { return "رصيد OpenAI خلص — اشحن الحساب" }
                return "OpenAI: طلبات كثير ورا بعض — استنى شوي وجرّب"
            case .anthropic:
                return "Claude: وصلت حد الطلبات — استنى شوي وجرّب"
            }
        case 400:
            if p == .anthropic, msg.contains("credit") { return "رصيد Anthropic خلص — اشحن الحساب" }
            return "\(p.short) رفض الطلب: \(msg)"
        case 402:
            if p == .openrouter { return "OpenRouter: النموذج مو مجاني أو الرصيد خلص — استخدم نموذج ينتهي بـ:free" }
            return "رصيد \(p.short) خلص"
        case 503:
            if p.isGemini { return "Gemini عليه ضغط الحين — جرّب بعد شوي أو غيّر الموديل" }
            return "\(p.short) عليه ضغط الحين — جرّب بعد شوي"
        case 500...599:
            return "\(p.short) عنده مشكلة الحين (\(code)) — جرّب بعد شوي"
        default:
            return "\(p.short): خطأ \(code) \(msg)"
        }
    }
}

/// أقسام المزوّدين السحابيين (مجاني / مدفوع): مفتاح، اسم نموذج، رابط المفتاح، ملاحظة الحدود، وتشغيل للدردشة
struct CloudSections: View {
    var showActivate: Bool
    var onChange: () -> Void = {}
    @State private var drafts: [String: String] = [:]
    @State private var version = 0
    @State private var askConsent = false
    @State private var pending: CloudProvider?
    @AppStorage("cloudCalls") private var useInCalls = false

    var body: some View {
        Group {
            if showActivate {
                Section {
                    Toggle("استخدمه في المكالمات بعد", isOn: $useInCalls)
                } footer: {
                    Text("النموذج السحابي المفعّل يرد في الدردشة (ويشوف الصور). المحلي يبقى احتياط: لو صار خطأ أو انقطع النت تقدر ترجع له بضغطة.")
                }
            }
            Section {
                ForEach(CloudProvider.free) { row($0) }
            } header: { Text("مجاني") } footer: { Text("الطبقات المجانية لها حد بالدقيقة وباليوم، وممكن توقف لين يتجدد الحد.") }
            Section {
                ForEach(CloudProvider.paid) { row($0) }
            } header: { Text("مدفوع") } footer: {
                Text("تندفع حسب الاستخدام من رصيد حسابك عند الخدمة. المفاتيح تنحفظ في سلسلة المفاتيح على هالجوال بس، ومشتركة بين الدردشة والوكيل.")
            }
        }
        .id(version)
        .alert("النماذج السحابية", isPresented: $askConsent) {
            Button("موافق") {
                UserDefaults.standard.set(true, forKey: "cloudConsent")
                if let p = pending { CloudLLM.setActive(p) }
                pending = nil; version += 1; onChange()
            }
            Button("إلغاء", role: .cancel) { pending = nil }
        } message: {
            Text("النموذج السحابي يرسل لخوادم الخدمة اللي اخترتها: رسايلك والمحادثة السابقة والصور المرفقة (وفي الوكيل نص الشاشة وصورتها)، حسب سياسة خصوصيتها. الطبقات المجانية ممكن تستخدم البيانات لتحسين خدماتها. هالتنبيه يطلع مرة وحدة.")
        }
    }

    @ViewBuilder private func row(_ p: CloudProvider) -> some View {
        let isActive = CloudLLM.active == p
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                if isActive { Text("مفعّل").font(.caption.bold()).foregroundStyle(.green) }
                else if p.hasKey { Image(systemName: "key.fill").foregroundStyle(.secondary) }
            }
            SecureField(p.hasKey ? "المفتاح محفوظ — الصق جديد لتغييره" : "الصق المفتاح هنا",
                        text: Binding(get: { drafts[p.rawValue] ?? "" }, set: { drafts[p.rawValue] = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
            TextField(p.defaultModel, text: Binding(
                get: { UserDefaults.standard.string(forKey: "cloudModel." + p.rawValue) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: "cloudModel." + p.rawValue) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.footnote.monospaced())
                .environment(\.layoutDirection, .leftToRight)
            Text(p.note).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if !(drafts[p.rawValue] ?? "").isEmpty {
                    Button("حفظ المفتاح") {
                        KeyStore.set("key." + p.rawValue, drafts[p.rawValue] ?? "")
                        drafts[p.rawValue] = ""; version += 1; onChange()
                    }
                }
                if showActivate, p.hasKey {
                    if isActive {
                        Button("رجوع للمحلي") { CloudLLM.setActive(nil); version += 1; onChange() }
                    } else {
                        Button("تشغيل") {
                            if CloudLLM.consent { CloudLLM.setActive(p); version += 1; onChange() }
                            else { pending = p; askConsent = true }
                        }
                        .bold()
                    }
                }
                if p.hasKey {
                    Button("حذف المفتاح", role: .destructive) {
                        KeyStore.delete("key." + p.rawValue)
                        if UserDefaults.standard.string(forKey: "cloudActive") == p.rawValue { CloudLLM.setActive(nil) }
                        if UserDefaults.standard.string(forKey: "agentModelPick") == "cloud:" + p.rawValue {
                            UserDefaults.standard.set("", forKey: "agentModelPick")
                        }
                        version += 1; onChange()
                    }
                }
                Spacer()
                if let u = URL(string: p.keyURL) { Link("جيب مفتاح", destination: u) }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}
