import Foundation
import CoreLocation

/// مصادر بيانات مباشرة بدون مفاتيح (أدق من صفحات البحث للطقس والعملات):
/// الطقس من Open-Meteo، والعملات من open.er-api.com. كلها تمر من بوابة الإنترنت.
enum LiveData {
    /// آخر مدينة استخدمناها للطقس (نتذكرها عشان أسئلة المتابعة)
    static var savedCity: String? {
        get { UserDefaults.standard.string(forKey: "weatherCity") }
        set { UserDefaults.standard.set(newValue, forKey: "weatherCity") }
    }

    /// يرجع نص سياق جاهز أو nil إذا السؤال مو من هالأنواع
    static func context(for text: String, previous: String?) async -> (String, [WebSource])? {
        let t = text.lowercased()
        let both = ((previous ?? "") + " " + text).lowercased()
        if LiveIntent.isWeather(t) || (LiveIntent.isWeather(both) && text.split(separator: " ").count <= 10) {
            return await weather(text: text, previous: previous)
        }
        if LiveIntent.isCurrency(t) { return await currency() }
        return nil
    }

    // MARK: الطقس

    static func weather(text: String, previous: String?) async -> (String, [WebSource])? {
        guard await NetworkGate.shared.permit(L("الطقس")) else { return nil }
        var place: (String, Double, Double)?
        // 1) مدينة مذكورة في الرسالة أو اللي قبلها
        for cand in LiveIntent.placeCandidates(text) + LiveIntent.placeCandidates(previous ?? "") {
            if let p = await geocode(cand) { place = p; break }
        }
        // 2) آخر مدينة محفوظة
        if place == nil, let c = savedCity { place = await geocode(c) }
        // 3) الموقع الحالي (يطلب الإذن مرة وحدة)
        if place == nil, let loc = await LocationOnce.shared.get() {
            let name = await LocationOnce.cityName(loc) ?? "موقعك الحالي"
            place = (name, loc.coordinate.latitude, loc.coordinate.longitude)
        }
        guard case let (name, lat, lon)? = place else {
            slog("live: weather without place")
            return ("ما عرفت المدينة: ما ذكرها المستخدم وما فيه موقع محفوظ. اسأله سؤال قصير وحد: أي مدينة؟", [])
        }
        if !name.contains("موقعك") { savedCity = name }
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=auto&forecast_days=3"
        guard let j = await json(url) else { return nil }
        var out = "طقس \(name) (Open-Meteo، بيانات مباشرة):\n"
        if let c = j["current"] as? [String: Any] {
            let temp = num(c["temperature_2m"]), feels = num(c["apparent_temperature"])
            let hum = num(c["relative_humidity_2m"]), wind = num(c["wind_speed_10m"])
            out += "الحين: \(temp)° (الإحساس \(feels)°)، \(LiveIntent.weatherText(Int(c["weather_code"] as? Double ?? -1)))، رطوبة \(hum)٪، رياح \(wind) كم/س\n"
        }
        if let d = j["daily"] as? [String: Any],
           let days = d["time"] as? [String], let mx = d["temperature_2m_max"] as? [Double],
           let mn = d["temperature_2m_min"] as? [Double], let codes = d["weather_code"] as? [Double] {
            let rain = d["precipitation_probability_max"] as? [Double] ?? []
            let names = ["اليوم", "بكرة", "بعد بكرة"]
            for i in 0..<min(days.count, 3) {
                let r = i < rain.count ? "، احتمال مطر \(Int(rain[i]))٪" : ""
                out += "\(names[i]) (\(days[i])): \(Int(mn[i].rounded()))–\(Int(mx[i].rounded()))°، \(LiveIntent.weatherText(Int(codes[i])))\(r)\n"
            }
        }
        slog("live: weather \(name)")
        return (out, [WebSource(title: "Open-Meteo: \(name)", url: "https://open-meteo.com")])
    }

    static func geocode(_ name: String) async -> (String, Double, Double)? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let lang = WebSearch.isArabic(name) ? "ar" : "en"
        guard let j = await json("https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=\(lang)"),
              let r = (j["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
        // نتجاهل القرى الصغيرة اللي تطابق كلمات عادية بالصدفة
        let pop = r["population"] as? Double ?? 0
        let code = r["feature_code"] as? String ?? ""
        guard pop >= 20000 || code.hasPrefix("PPLA") || code == "PPLC" else { return nil }
        let n = r["name"] as? String ?? name
        let c = r["country"] as? String
        return (c.map { "\(n)، \($0)" } ?? n, lat, lon)
    }

    // MARK: العملات

    static func currency() async -> (String, [WebSource])? {
        guard await NetworkGate.shared.permit(L("أسعار العملات")) else { return nil }
        guard let j = await json("https://open.er-api.com/v6/latest/USD"),
              let rates = j["rates"] as? [String: Double] else { return nil }
        let pick = ["SAR", "EUR", "GBP", "AED", "EGP", "KWD", "QAR", "JOD", "TRY", "PKR", "INR", "IDR", "SDG", "YER", "CNY", "JPY"]
        var out = "أسعار الصرف (open.er-api.com، تحديث \(j["time_last_update_utc"] as? String ?? "")):\n1 دولار أمريكي =\n"
        for k in pick { if let v = rates[k] { out += "  \(k): \(String(format: "%.4f", v))\n" } }
        if let sar = rates["SAR"] {
            out += "1 ريال سعودي = "
            out += ["USD": 1.0, "EUR": rates["EUR"] ?? 0, "EGP": rates["EGP"] ?? 0, "PKR": rates["PKR"] ?? 0]
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \(String(format: "%.4f", $0.value / sar))" }.joined(separator: "، ")
            out += "\n"
        }
        return (out, [WebSource(title: "ExchangeRate-API", url: "https://open.er-api.com")])
    }

    // MARK: أدوات

    private static func num(_ v: Any?) -> String {
        guard let d = v as? Double else { return "?" }
        return String(Int(d.rounded()))
    }

    private static func json(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        do {
            let (data, _) = try await WebSearch.session.data(from: u)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            slog("live: \(u.host ?? "") failed \(error)")
            return nil
        }
    }
}

/// يطلب الموقع مرة وحدة (لو المستخدم رفض ما نسأل مرة ثانية)
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    static let shared = LocationOnce()
    private let m = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?

    func get() async -> CLLocation? {
        let s = m.authorizationStatus
        if s == .denied || s == .restricted { return nil }
        if s == .notDetermined, UserDefaults.standard.bool(forKey: "locAsked") { return nil }
        UserDefaults.standard.set(true, forKey: "locAsked")
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        if let c = cont { cont = nil; c.resume(returning: nil) }
        return await withCheckedContinuation { c in
            cont = c
            if s == .notDetermined { m.requestWhenInUseAuthorization() } else { m.requestLocation() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                if let c = self.cont { self.cont = nil; c.resume(returning: nil) }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            if s == .authorizedWhenInUse || s == .authorizedAlways { self.m.requestLocation() }
            else if s != .notDetermined, let c = self.cont { self.cont = nil; c.resume(returning: nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in if let c = self.cont { self.cont = nil; c.resume(returning: l) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in if let c = self.cont { self.cont = nil; c.resume(returning: nil) } }
    }

    static func cityName(_ loc: CLLocation) async -> String? {
        let p = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "ar"))
        return p?.first?.locality ?? p?.first?.administrativeArea
    }
}
