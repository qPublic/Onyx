import Foundation
import CoreLocation

// MARK: - Where you are: Location Services when allowed, otherwise your IP address's city

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()   // first used from WeatherService.start, on the main thread
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var allowed: Bool { manager.authorizationStatus == .authorizedAlways }   // macOS reports "allowed" this way
    var denied: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }

    /// A location fix, or nil if Location Services is off or not allowed. macOS asks for permission the first time.
    @MainActor func current() async -> CLLocation? {
        if denied { return nil }
        return await withCheckedContinuation { c in
            waiters.append(c)
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(nil) }   // no fix: use the IP city
        }
    }

    private func finish(_ l: CLLocation?) {
        let w = waiters; waiters = []
        w.forEach { $0.resume(returning: l) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if allowed {
            if waiters.isEmpty { Task { await WeatherService.shared.refresh() } } else { m.requestLocation() }   // allowed late: refresh now
        } else if denied {
            finish(nil)
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) { finish(locs.last) }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    static func placeName(_ l: CLLocation) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(l)
        return marks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.name }
    }
}

// MARK: - Weather stations: the closest real measurement beats a forecast model for "right now"

/// A current reading from one weather station.
struct StationReading {
    var source: String   // "NWS" or "METAR"
    var id: String
    var name: String
    var lat: Double, lon: Double
    var tempC: Double
    var code: Int?       // WMO weather code, when the station reports conditions
    var time: Date
    var distanceKm = 0.0
}

enum WeatherSources {
    static let agent = "Onyx (github.com/qPublic/Onyx)"
    static let maxDistanceKm = 20.0
    static let maxAge: TimeInterval = 90 * 60

    /// The closest station that reported in the last 90 minutes, if one is within 20 km. Asks the US National Weather
    /// Service (which also has non-airport stations) and aviation METAR reports (airports worldwide) at the same time.
    static func nearest(lat: Double, lon: Double) async -> StationReading? {
        async let a = nws(lat: lat, lon: lon)
        async let b = metar(lat: lat, lon: lon)
        let all = await a + b
        return pick(all, lat: lat, lon: lon, now: Date())
    }

    static func pick(_ readings: [StationReading], lat: Double, lon: Double, now: Date) -> StationReading? {
        readings.map { r -> StationReading in var r = r; r.distanceKm = distanceKm(lat, lon, r.lat, r.lon); return r }
            .filter { $0.distanceKm <= maxDistanceKm && now.timeIntervalSince($0.time) <= maxAge }
            .min { $0.distanceKm < $1.distanceKm }
    }

    private static func get(_ s: String) async -> Any? {
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 10)
        r.setValue(agent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// Aviation weather reports from airports within ~30 km.
    static func metar(lat: Double, lon: Double) async -> [StationReading] {
        let dLat = 0.3, dLon = 0.3 / max(cos(lat * .pi / 180), 0.2)
        let box = String(format: "%.3f,%.3f,%.3f,%.3f", lat - dLat, lon - dLon, lat + dLat, lon + dLon)
        guard let arr = await get("https://aviationweather.gov/api/data/metar?bbox=\(box)&format=json") as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["icaoId"] as? String, let la = m["lat"] as? Double, let lo = m["lon"] as? Double,
                  let t = (m["temp"] as? Double) ?? (m["temp"] as? Int).map(Double.init), let obs = m["obsTime"] as? Double else { return nil }
            let covers = (m["clouds"] as? [[String: Any]] ?? []).compactMap { $0["cover"] as? String }
            let name = (m["name"] as? String)?.components(separatedBy: ",").first ?? id
            return StationReading(source: "METAR", id: id, name: name, lat: la, lon: lo, tempC: t,
                                  code: code(metarWeather: m["wxString"] as? String, covers: covers), time: Date(timeIntervalSince1970: obs))
        }
    }

    /// US National Weather Service observations from the stations nearest the point (empty outside the US).
    static func nws(lat: Double, lon: Double) async -> [StationReading] {
        guard let point = await get(String(format: "https://api.weather.gov/points/%.4f,%.4f", lat, lon)) as? [String: Any],
              let list = (point["properties"] as? [String: Any])?["observationStations"] as? String,
              let st = await get(list + "?limit=6") as? [String: Any], let features = st["features"] as? [[String: Any]] else { return [] }
        let stations: [(String, String, Double, Double)] = features.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let id = p["stationIdentifier"] as? String,
                  let c = (f["geometry"] as? [String: Any])?["coordinates"] as? [Double], c.count >= 2 else { return nil }
            return (id, (p["name"] as? String) ?? id, c[1], c[0])
        }
        let nearest = stations.sorted { distanceKm(lat, lon, $0.2, $0.3) < distanceKm(lat, lon, $1.2, $1.3) }.prefix(3)
        return await withTaskGroup(of: StationReading?.self) { g in
            for (id, name, la, lo) in nearest {
                g.addTask {
                    guard let o = await get("https://api.weather.gov/stations/\(id)/observations/latest") as? [String: Any],
                          let p = o["properties"] as? [String: Any],
                          let t = (p["temperature"] as? [String: Any])?["value"] as? Double,
                          let ts = p["timestamp"] as? String, let time = ISO8601DateFormatter().date(from: ts) else { return nil }
                    return StationReading(source: "NWS", id: id, name: name.capitalizedStationName, lat: la, lon: lo, tempC: t,
                                          code: code(nwsText: p["textDescription"] as? String), time: time)
                }
            }
            var out: [StationReading] = []
            for await r in g { if let r { out.append(r) } }
            return out
        }
    }

    static func distanceKm(_ a1: Double, _ o1: Double, _ a2: Double, _ o2: Double) -> Double {
        let r = Double.pi / 180, dA = (a2 - a1) * r, dO = (o2 - o1) * r
        let h = sin(dA / 2) * sin(dA / 2) + cos(a1 * r) * cos(a2 * r) * sin(dO / 2) * sin(dO / 2)
        return 6371 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// METAR weather ("-RA", "+TSRA", "BR") and cloud cover → the WMO code the weather icons use.
    static func code(metarWeather wx: String?, covers: [String]) -> Int? {
        let w = (wx ?? "").uppercased()
        let heavy = w.contains("+"), light = w.contains("-")
        func level(_ l: Int, _ m: Int, _ h: Int) -> Int { heavy ? h : light ? l : m }
        if w.contains("TS") { return 95 }
        if w.contains("FZRA") || w.contains("FZDZ") { return 66 }
        if w.contains("SN") || w.contains("SG") || w.contains("PL") || w.contains("GS") { return w.contains("SH") ? 85 : level(71, 73, 75) }
        if w.contains("RA") { return w.contains("SH") ? level(80, 81, 82) : level(61, 63, 65) }
        if w.contains("DZ") { return level(51, 53, 55) }
        if w.contains("FG") || w.contains("BR") || w.contains("HZ") { return 45 }
        if covers.contains(where: { ["OVC", "BKN", "OVX"].contains($0) }) { return 3 }
        if covers.contains("SCT") { return 2 }
        if covers.contains("FEW") { return 1 }
        if covers.contains(where: { ["CLR", "SKC", "NCD", "NSC", "CAVOK"].contains($0) }) || (wx == nil && covers.isEmpty) { return 0 }
        return nil
    }

    /// NWS descriptions ("Light Rain", "Mostly Cloudy", "Fog/Mist") → WMO code.
    static func code(nwsText: String?) -> Int? {
        guard let t = nwsText?.lowercased(), !t.isEmpty else { return nil }
        let heavy = t.contains("heavy"), light = t.contains("light")
        func level(_ l: Int, _ m: Int, _ h: Int) -> Int { heavy ? h : light ? l : m }
        if t.contains("thunder") { return 95 }
        if t.contains("freezing") { return 66 }
        if t.contains("snow") || t.contains("sleet") || t.contains("ice pellets") { return level(71, 73, 75) }
        if t.contains("shower") { return level(80, 81, 82) }
        if t.contains("rain") { return level(61, 63, 65) }
        if t.contains("drizzle") { return level(51, 53, 55) }
        if t.contains("fog") || t.contains("mist") || t.contains("haze") || t.contains("smoke") { return 45 }
        if t.contains("partly") { return 2 }
        if t.contains("mostly clear") || t.contains("mostly sunny") || t.contains("few clouds") { return 1 }
        if t.contains("cloudy") || t.contains("overcast") { return 3 }
        if t.contains("clear") || t.contains("sunny") || t.contains("fair") { return 0 }
        return nil
    }
}

private extension String {
    /// "SEATTLE WEATHER FORECAST OFFICE" → "Seattle Weather Forecast Office"; mixed-case names stay as they are.
    var capitalizedStationName: String { self == uppercased() ? capitalized : self }
}
