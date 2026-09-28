import AppKit
import SwiftUI
import CoreAudio

// MARK: - AirPods & headphones: their battery pops up in the notch when they connect

/// Watches for Bluetooth audio devices appearing (Core Audio, so no Bluetooth permission is needed), then reads
/// their battery from system_profiler, like BluetoothService does.
final class EarbudsWatcher {
    static let shared = EarbudsWatcher()
    private var known: Set<AudioDeviceID> = []
    private var lastShown: [String: Date] = [:]

    func start() {
        known = Set(Self.bluetoothOutputs().map(\.id))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.devicesChanged()
        }
    }

    private func devicesChanged() {
        let now = Self.bluetoothOutputs()
        let added = now.filter { !known.contains($0.id) }
        known = Set(now.map(\.id))
        guard Prefs.bool(Prefs.earbudsActivity) else { return }
        // Once a minute per device at most (AirPods hop between your Mac and iPhone).
        for d in added where Date().timeIntervalSince(lastShown[d.name] ?? .distantPast) > 60 { show(d.name) }
    }

    /// The battery shows up a few seconds after connecting, so this tries a few times.
    func show(_ name: String, attempt: Int = 0) {
        BluetoothService.shared.refreshBattery { [weak self] map in
            if let b = Self.match(name, in: map), b.any {
                self?.lastShown[name] = Date()
                NotchModel.shared.flash(.earbuds(name: name, left: b.left, right: b.right, caseLevel: b.caseLevel, main: b.main), for: 5)
            } else if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt + 1) * 3) { self?.show(name, attempt: attempt + 1) }
            }
        }
    }

    static func match(_ name: String, in map: [String: BluetoothService.BTBattery]) -> BluetoothService.BTBattery? {
        map[name] ?? map.first { $0.key.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.key) }?.value
    }

    static func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("max") { return "airpodsmax" }
        if n.contains("pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
    static func caseIcon(_ name: String) -> String {
        name.lowercased().contains("pro") ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill"
    }
    /// "Sam's AirPods Pro" → "AirPods Pro".
    static func shortName(_ name: String) -> String {
        for mark in ["’s ", "'s "] { if let r = name.range(of: mark) { return String(name[r.upperBound...]) } }
        return name
    }

    struct Output { let id: AudioDeviceID; let name: String }

    /// Bluetooth devices that can play sound (AirPods also show up as a microphone; that one is skipped).
    static func bluetoothOutputs() -> [Output] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var transport: UInt32 = 0, ts = UInt32(MemoryLayout<UInt32>.size)
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ta, 0, nil, &ts, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return nil }
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
            return Output(id: id, name: n as String)
        }
    }
}

/// The right side of the AirPods pop-up: one number when both buds match, else L and R, then the case.
struct EarbudsLevels: View {
    let name: String, left: Int?, right: Int?, caseLevel: Int?, main: Int?
    var body: some View {
        HStack(spacing: 6) {
            if let l = left, let r = right, abs(l - r) > 5 {
                level("L", l, pct: false); level("R", r, pct: false)
            } else if let b = [left, right].compactMap({ $0 }).min() ?? main {
                level(nil, b, pct: true)
            }
            if let c = caseLevel {
                HStack(spacing: 2) {
                    Image(systemName: EarbudsWatcher.caseIcon(name)).font(.system(size: 9))
                    Text("\(c)%").foregroundStyle(c <= 20 ? Color.red : Color.primary)
                }
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
    private func level(_ label: String?, _ p: Int, pct: Bool) -> some View {
        HStack(spacing: 1) {
            if let label { Text(label).foregroundStyle(.secondary) }
            Text(pct ? "\(p)%" : "\(p)").foregroundStyle(p <= 20 ? Color.red : Color.primary)
        }
    }
}

// MARK: - Rain soon: a heads-up in the notch before rain (or snow) starts

final class RainWatch {
    static let shared = RainWatch()
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.check() }.tolerant(0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.check() }
    }

    func check() {
        guard Prefs.bool(Prefs.rainAlerts), let (lat, lon) = WeatherService.shared.coordinates,
              Date().timeIntervalSince(Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "rain.lastAlert"))) > 3 * 3600,
              let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=precipitation,weather_code&minutely_15=precipitation,weather_code&forecast_minutely_15=6&timeformat=unixtime")
        else { return }
        Task {
            guard let (d, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let a = Self.alert(j, now: Date()) else { return }
            await MainActor.run {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "rain.lastAlert")   // at most every 3 hours
                NotchModel.shared.flash(.message(icon: a.icon, text: a.text, tint: .cyan), for: 6)
            }
        }
    }

    /// "Rain in ~15 min" when it's dry now and rain, snow or a storm starts within the hour. Open-Meteo's 15-minute
    /// values cover the 15 minutes *before* each timestamp.
    static func alert(_ j: [String: Any], now: Date) -> (text: String, icon: String)? {
        let wet: (Double, Int) -> Bool = { mm, code in mm >= 0.1 || (61...67).contains(code) || (71...77).contains(code) || (80...86).contains(code) || code >= 95 }
        guard let cur = j["current"] as? [String: Any], let m = j["minutely_15"] as? [String: Any],
              let times = m["time"] as? [Double], let mm = m["precipitation"] as? [Double] else { return nil }
        let codes = m["weather_code"] as? [Int] ?? []
        if wet(cur["precipitation"] as? Double ?? 0, cur["weather_code"] as? Int ?? 0) { return nil }   // already raining
        for i in times.indices where i < mm.count {
            let start = times[i] - 15 * 60, code = i < codes.count ? codes[i] : 0
            guard times[i] > now.timeIntervalSince1970, start - now.timeIntervalSince1970 <= 60 * 60, wet(mm[i], code) else { continue }
            let kind = (71...77).contains(code) || (85...86).contains(code) ? "Snow" : code >= 95 ? "Storm" : "Rain"
            let icon = kind == "Snow" ? "cloud.snow.fill" : kind == "Storm" ? "cloud.bolt.rain.fill" : "cloud.rain.fill"
            let mins = Int(((start - now.timeIntervalSince1970) / 60 / 5).rounded()) * 5
            return (mins <= 5 ? "\(kind) starting soon" : "\(kind) in ~\(mins) min", icon)
        }
        return nil
    }
}
