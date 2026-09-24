import AppKit
import SwiftUI
import IOKit.ps
import IOKit.pwr_mgt
import CoreAudio
import CoreImage
import AudioToolbox
import EventKit
import IOBluetooth
import UniformTypeIdentifiers

// MARK: - Now Playing (Spotify + Apple Music via AppleScript)

final class MediaController: ObservableObject {
    static let shared = MediaController()

    enum Player: String {
        case spotify = "com.spotify.client", music = "com.apple.Music"
        var appName: String { self == .spotify ? "Spotify" : "Music" }
        var stateScript: String {
            switch self {
            case .spotify: return """
                tell application "Spotify"
                  if player state is stopped then return "stopped"
                  set t to current track
                  return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & ((duration of t) / 1000) & "||" & (player position) & "||" & (artwork url of t)
                end tell
                """
            case .music: return """
                tell application "Music"
                  if player state is stopped then return "stopped"
                  set t to current track
                  return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (duration of t) & "||" & (player position) & "||" & ""
                end tell
                """
            }
        }
    }

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage? { didSet { artworkColor = artwork.flatMap { $0.averageColor }.map { Color(nsColor: $0) } ?? .clear } }
    @Published var artworkColor: Color = .clear
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var positionDate = Date()
    @Published var source: Player?

    private let queue = DispatchQueue(label: "onyx.media")
    private var artKey = ""
    private var timer: Timer?

    var hasTrack: Bool { !title.isEmpty }

    func currentPosition(at d: Date) -> Double {
        isPlaying ? min(duration, position + d.timeIntervalSince(positionDate)) : position
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(changed), name: .init("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(changed), name: .init("com.apple.Music.playerInfo"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @objc private func changed(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refresh() }
    }

    private func running(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.rawValue).isEmpty
    }

    func refresh() {
        let candidates = [Player.spotify, .music].filter(running)
        queue.async {
            var best: (Player, [String])?
            for p in candidates {
                guard let r = Self.run(p.stateScript), r != "stopped" else { continue }
                let parts = r.components(separatedBy: "||")
                guard parts.count >= 7 else { continue }
                if best == nil || (parts[0] == "playing" && best!.1[0] != "playing") { best = (p, parts) }
            }
            DispatchQueue.main.async { self.apply(best) }
        }
    }

    private static func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    private func apply(_ best: (Player, [String])?) {
        guard let (p, f) = best else {
            if hasTrack { title = ""; artist = ""; album = ""; artwork = nil; isPlaying = false; source = nil; artKey = "" }
            return
        }
        source = p
        isPlaying = f[0] == "playing"
        title = f[1]; artist = f[2]; album = f[3]
        duration = Self.num(f[4]); position = Self.num(f[5]); positionDate = Date()
        let key = p.rawValue + f[1] + f[3]
        if key != artKey {
            artKey = key
            loadArtwork(player: p, url: f[6], key: key)
        }
    }

    private func loadArtwork(player: Player, url: String, key: String) {
        if player == .spotify, let u = URL(string: url) {
            URLSession.shared.dataTask(with: u) { d, _, _ in
                guard let d, let img = NSImage(data: d) else { return }
                DispatchQueue.main.async { if self.artKey == key { self.artwork = img } }
            }.resume()
        } else {
            queue.async {
                var err: NSDictionary?
                let r = NSAppleScript(source: "tell application \"Music\" to get data of artwork 1 of current track")?
                    .executeAndReturnError(&err)
                let img = r.flatMap { NSImage(data: $0.data) }
                DispatchQueue.main.async { if self.artKey == key { self.artwork = img } }
            }
        }
    }

    static func run(_ src: String) -> String? {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src) else { return nil }
        let r = s.executeAndReturnError(&err)
        return err == nil ? r.stringValue : nil
    }

    private func send(_ cmd: String) {
        guard let p = source else { return }
        queue.async {
            _ = Self.run("tell application \"\(p.appName)\" to \(cmd)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh() }
        }
    }

    func playPause() {
        if source == nil { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")); return }
        position = currentPosition(at: Date()); positionDate = Date(); isPlaying.toggle()
        send("playpause")
    }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(_ t: Double) { position = t; positionDate = Date(); send("set player position to \(t)") }
    func openPlayer() {
        guard let p = source, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: u, configuration: .init())
    }
}

// MARK: - Battery

final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published var percent = 100
    @Published var charging = false
    @Published var pluggedIn = false
    @Published var hasBattery = false
    @Published var minutesLeft: Int?
    private var lowShown = false
    private var loaded = false

    func start() {
        update()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { m.update() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = mx > 0 ? cur * 100 / mx : cur
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let chg = d[kIOPSIsChargingKey] as? Bool ?? false
            let t = (plugged ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            if loaded && plugged != pluggedIn && Prefs.bool(Prefs.chargingActivity) {
                NotchModel.shared.flash(.charging(pct, plugged: plugged), for: 3)
            }
            if loaded && !plugged && pct <= 20 && !lowShown {
                lowShown = true
                NotchModel.shared.flash(.lowBattery(pct), for: 4)
            }
            if plugged { lowShown = false }
            percent = pct; pluggedIn = plugged; charging = chg
            minutesLeft = (t ?? -1) > 0 ? t : nil
        }
        loaded = true
    }
}

// MARK: - Volume HUD (CoreAudio listener)

final class VolumeMonitor {
    static let shared = VolumeMonitor()
    private var device = AudioObjectID(0)
    private var watched = Set<AudioObjectID>()
    private var lastVolume: Float = -1
    private var lastMute = false

    private func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.attach()
        }
        attach()
    }

    private func attach() {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        device = dev
        lastVolume = volume() ?? -1
        lastMute = muted()
        guard !watched.contains(dev) else { return }
        watched.insert(dev)
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var pa = addr(sel, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(dev, &pa, .main) { [weak self] _, _ in
                guard let self, dev == self.device else { return }
                self.changed()
            }
        }
    }

    func volume() -> Float? {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    func muted() -> Bool {
        var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m) == noErr && m != 0
    }

    func setVolume(_ v: Float) {
        var val = Float32(max(0, min(1, v)))
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
    }

    func setMute(_ m: Bool) {
        var val = UInt32(m ? 1 : 0)
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }

    private func changed() {
        let v = volume() ?? 0, m = muted()
        defer { lastVolume = v; lastMute = m }
        guard abs(v - lastVolume) > 0.001 || m != lastMute, Prefs.bool(Prefs.volumeHUD) else { return }
        NotchModel.shared.flash(.volume(v, muted: m), for: 1.8)
    }
}

// MARK: - Calendar & Reminders (EventKit)

final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    let store = EKEventStore()
    @Published var authorized = false
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    @Published var dayEvents: [EKEvent] = []
    @Published var upcoming: [EKEvent] = []
    @Published var busyDays = Set<Int>()

    func start() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { self.authorized = granted; self.reload() }
        }
    }

    func select(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        reload()
    }

    func reload() {
        guard authorized else { return }
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: selectedDay)!
        dayEvents = store.events(matching: store.predicateForEvents(withStart: selectedDay, end: dayEnd, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        let now = Date()
        upcoming = Array(store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86400), calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(4))
        if let month = cal.dateInterval(of: .month, for: selectedDay) {
            let evs = store.events(matching: store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil))
            busyDays = Set(evs.map { cal.component(.day, from: $0.startDate) })
        }
    }

    // Used by the AI agent
    func createEvent(title: String, start: Date, minutes: Int) throws -> String {
        guard authorized else { throw NSError(domain: "Onyx", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access not granted"]) }
        let e = EKEvent(eventStore: store)
        e.title = title; e.startDate = start; e.endDate = start.addingTimeInterval(Double(max(minutes, 5)) * 60)
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent)
        return "Created event \"\(title)\" on \(start.formatted(date: .abbreviated, time: .shortened))"
    }

    func createReminder(title: String, due: Date?) async throws -> String {
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard try await store.requestFullAccessToReminders() else { return "Reminders access was denied." }
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return "Added reminder \"\(title)\"" + (due.map { " for \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }
}

// MARK: - Weather (Open-Meteo, no API key)

struct WxHour: Identifiable { let id = UUID(); let time: Date; let temp: Double; let code: Int; let precip: Int }
struct WxDay: Identifiable { let id = UUID(); let date: Date; let hi: Double; let lo: Double; let code: Int }

final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    @Published var temp: Double?
    @Published var high: Double?
    @Published var low: Double?
    @Published var code = 0
    @Published var place = ""
    @Published var hourly: [WxHour] = []
    @Published var daily: [WxDay] = []

    func start() {
        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in Task { await self.refresh() } }
    }

    private func json(_ s: String) async -> [String: Any]? {
        guard let u = URL(string: s), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    func refresh() async {
        var lat = 0.0, lon = 0.0, name = ""
        let city = Prefs.string(Prefs.weatherCity)
        if city.isEmpty {
            guard let j = await json("https://ipwho.is/"), let la = j["latitude"] as? Double, let lo = j["longitude"] as? Double else { return }
            lat = la; lon = lo; name = j["city"] as? String ?? ""
        } else {
            let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
            guard let j = await json("https://geocoding-api.open-meteo.com/v1/search?count=1&name=\(q)"),
                  let r = (j["results"] as? [[String: Any]])?.first,
                  let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double else { return }
            lat = la; lon = lo; name = r["name"] as? String ?? city
        }
        let unit = Prefs.bool(Prefs.fahrenheit) ? "&temperature_unit=fahrenheit" : ""
        guard let j = await json("https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&hourly=temperature_2m,weather_code,precipitation_probability&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=auto&forecast_days=7\(unit)"),
              let cur = j["current"] as? [String: Any] else { return }
        let daily = j["daily"] as? [String: Any]
        let hrs = Self.parseHourly(j["hourly"] as? [String: Any])
        let days = Self.parseDaily(daily)
        await MainActor.run {
            self.place = name
            self.temp = cur["temperature_2m"] as? Double
            self.code = cur["weather_code"] as? Int ?? 0
            self.high = (daily?["temperature_2m_max"] as? [Double])?.first
            self.low = (daily?["temperature_2m_min"] as? [Double])?.first
            self.hourly = hrs
            self.daily = days
        }
    }

    private static func parseHourly(_ h: [String: Any]?) -> [WxHour] {
        guard let h, let times = h["time"] as? [String], let temps = h["temperature_2m"] as? [Double] else { return [] }
        let codes = h["weather_code"] as? [Int] ?? [], precs = h["precipitation_probability"] as? [Int] ?? []
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd'T'HH:mm"; df.timeZone = .current
        let cutoff = Date().addingTimeInterval(-3600)
        var out: [WxHour] = []
        for i in times.indices where i < temps.count {
            guard let t = df.date(from: times[i]), t >= cutoff else { continue }
            out.append(WxHour(time: t, temp: temps[i], code: i < codes.count ? codes[i] : 0, precip: i < precs.count ? precs[i] : 0))
            if out.count >= 12 { break }
        }
        return out
    }

    private static func parseDaily(_ d: [String: Any]?) -> [WxDay] {
        guard let d, let times = d["time"] as? [String],
              let his = d["temperature_2m_max"] as? [Double], let los = d["temperature_2m_min"] as? [Double] else { return [] }
        let codes = d["weather_code"] as? [Int] ?? []
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        var out: [WxDay] = []
        for i in times.indices where i < his.count && i < los.count {
            guard let dt = df.date(from: times[i]) else { continue }
            out.append(WxDay(date: dt, hi: his[i], lo: los[i], code: i < codes.count ? codes[i] : 0))
        }
        return out
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
    var symbol: String { Self.symbol(code) }
}

// MARK: - Clipboard history (text; skips password-manager "concealed" items)

final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()
    struct Clip: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var date: Date
        var app: String?
        var pinned = false
    }
    @Published var clips: [Clip] = []
    private var lastCount = NSPasteboard.general.changeCount
    private var saveWork: DispatchWorkItem?
    private var file: URL { Prefs.supportDir.appendingPathComponent("clipboard.json") }

    func start() {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode([Clip].self, from: d) { clips = c }
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wasPinned = clips.first { $0.text == s }?.pinned ?? false
        clips.removeAll { $0.text == s }
        clips.insert(Clip(text: s, date: Date(), app: NSWorkspace.shared.frontmostApplication?.localizedName, pinned: wasPinned), at: 0)
        if clips.count > 5000 { clips.removeLast(clips.count - 5000) }
        save()
    }

    func copy(_ c: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.text, forType: .string)
    }

    func togglePin(_ c: Clip) {
        if let i = clips.firstIndex(of: c) { clips[i].pinned.toggle(); save() }
    }
    func delete(_ c: Clip) { clips.removeAll { $0.id == c.id }; save() }
    func clear() { clips.removeAll { !$0.pinned }; save() }

    private func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [clips, file] in
            if let d = try? JSONEncoder().encode(clips) { try? d.write(to: file, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: w)
    }
}

// MARK: - Timer + 20-20-20 eye breaks

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    @Published var endDate: Date?
    @Published var total: TimeInterval = 0
    @Published var pausedRemaining: TimeInterval?
    @Published var now = Date()
    private var nextEyeBreak = Date().addingTimeInterval(20 * 60)

    var running: Bool { endDate != nil || pausedRemaining != nil }
    var remaining: TimeInterval {
        if let p = pausedRemaining { return p }
        return max(0, (endDate ?? now).timeIntervalSince(now))
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func begin(minutes: Double) {
        total = minutes * 60
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(total)
    }

    func togglePause() {
        if let p = pausedRemaining { endDate = Date().addingTimeInterval(p); pausedRemaining = nil }
        else if endDate != nil { pausedRemaining = remaining; endDate = nil }
    }

    func cancel() { endDate = nil; pausedRemaining = nil }

    private func tick() {
        now = Date()
        if let e = endDate, now >= e {
            endDate = nil
            if Fun.has(Fun.bomb) {
                SoundBoard.play(.boom)
                NotchModel.shared.flash(.message(icon: "burst.fill", text: "BOOM! Time's up", tint: .orange), for: 5)
            } else {
                NSSound(named: "Glass")?.play()
                NotchModel.shared.flash(.message(icon: "timer", text: "Time's up!", tint: .orange), for: 5)
            }
        }
        if Prefs.bool(Prefs.eyeBreak) {
            if now >= nextEyeBreak {
                nextEyeBreak = now.addingTimeInterval(20 * 60)
                NSSound(named: "Tink")?.play()
                NotchModel.shared.flash(.eyeBreak(until: now.addingTimeInterval(20)), for: 20)
            }
        } else {
            nextEyeBreak = now.addingTimeInterval(20 * 60)
        }
    }
}

// MARK: - Caffeinate + lock

final class Caffeinate: ObservableObject {
    static let shared = Caffeinate()
    @Published var active = false
    @Published var until: Date?
    private var assertion: IOPMAssertionID = 0
    private var offWork: DispatchWorkItem?

    func enable(hours: Double?) {
        disable()
        let r = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Onyx Caffeinate" as CFString, &assertion)
        guard r == kIOReturnSuccess else { return }
        active = true
        if let hours {
            until = Date().addingTimeInterval(hours * 3600)
            let w = DispatchWorkItem { [weak self] in self?.disable() }
            offWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + hours * 3600, execute: w)
        }
    }

    func disable() {
        offWork?.cancel()
        if active { IOPMAssertionRelease(assertion) }
        active = false; until = nil
    }

    static func lockScreen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

// MARK: - Bluetooth fast connect

final class BluetoothService: ObservableObject {
    static let shared = BluetoothService()
    struct Device: Identifiable {
        let id: String
        let name: String
        let connected: Bool
        let ref: IOBluetoothDevice
    }
    struct BTBattery: Equatable {
        var main: Int?, left: Int?, right: Int?, caseLevel: Int?
        /// A single number for glances: the lowest of the in-ear/main levels (ignores the case).
        var low: Int? { [left, right, main].compactMap { $0 }.min() }
        var any: Bool { main != nil || left != nil || right != nil || caseLevel != nil }
    }
    @Published var devices: [Device] = []
    @Published var battery: [String: BTBattery] = [:]   // keyed by device name
    @Published var busy: String?
    private var batteryTimer: Timer?

    /// Battery of the first connected device that reports one (what the glance/widget shows).
    var primaryBattery: (name: String, battery: BTBattery)? {
        if let d = devices.first(where: { $0.connected && (battery[$0.name]?.any ?? false) }) {
            return (d.name, battery[d.name]!)
        }
        return battery.first.map { ($0.key, $0.value) }
    }

    func start() {
        // Battery comes from system_profiler (no Bluetooth permission). IOBluetooth enumeration is
        // deferred to when the Bluetooth tool is actually opened, so just running Onyx never asks for Bluetooth.
        refreshBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refreshBattery() }
    }

    private var lastRefresh = Date.distantPast

    /// Paired devices rarely change; skip the (blocking) lookup if we did one recently.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 30 || devices.isEmpty { refresh() }
    }

    func refresh() {
        lastRefresh = Date()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = paired.map { Device(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Unknown", connected: $0.isConnected(), ref: $0) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// AirPods/headphone battery isn't in IOBluetooth; system_profiler exposes it. Runs off the main thread.
    func refreshBattery() {
        DispatchQueue.global(qos: .utility).async {
            guard let data = Self.runProfiler(), let map = Self.parseBattery(data) else { return }
            DispatchQueue.main.async { if map != self.battery { self.battery = map } }
        }
    }

    private static func runProfiler() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return d
    }

    private static func parseBattery(_ data: Data) -> [String: BTBattery]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]], let bt = arr.first else { return nil }
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        var out: [String: BTBattery] = [:]
        for key in ["device_connected", "device_not_connected"] {
            for entry in (bt[key] as? [[String: Any]]) ?? [] {
                for (name, info) in entry {
                    guard let info = info as? [String: Any] else { continue }
                    let b = BTBattery(main: pct(info["device_batteryLevelMain"]),
                                      left: pct(info["device_batteryLevelLeft"]),
                                      right: pct(info["device_batteryLevelRight"]),
                                      caseLevel: pct(info["device_batteryLevelCase"]))
                    if b.any { out[name] = b }
                }
            }
        }
        return out
    }

    func toggle(_ d: Device) {
        busy = d.id
        DispatchQueue.global().async {
            if d.ref.isConnected() { d.ref.closeConnection() } else { d.ref.openConnection() }
            DispatchQueue.main.async { self.busy = nil; self.refresh() }
        }
    }
}

// MARK: - File shelf

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published var items: [URL] = []
    private let key = "shelfItems"
    private var dropDir: URL {
        let u = Prefs.supportDir.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() { UserDefaults.standard.set(items.map(\.path), forKey: key) }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        save()
    }
    func remove(_ u: URL) { items.removeAll { $0 == u }; save() }
    func clear() { items.removeAll(); save() }

    /// Accepts files, images and text dragged from any app.
    @discardableResult
    func handleDrop(_ providers: [NSItemProvider], airDrop: Bool = false) -> Bool {
        let group = DispatchGroup()
        var dropped: [URL] = []
        let lock = NSLock()
        func collect(_ u: URL) { lock.lock(); dropped.append(u); lock.unlock() }
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { collect(u) }; group.leave() }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let u = self.dropDir.appendingPathComponent("Image \(Self.stamp()).png")
                        if (try? png.write(to: u)) != nil { collect(u) }
                    }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s {
                        let u = self.dropDir.appendingPathComponent("Text \(Self.stamp()).txt")
                        if (try? s.write(to: u, atomically: true, encoding: .utf8)) != nil { collect(u) }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if airDrop { Self.airDrop(dropped) } else { self.add(dropped) }
        }
        return true
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"; return f.string(from: Date())
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }
}

// MARK: - Meeting links in calendar events

extension EKEvent {
    /// A video-call link found in the event's url, notes or location (Zoom/Meet/Teams/Webex/…).
    var meetingURL: URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "whereby.com", "meet.jit.si", "chime.aws", "bluejeans.com", "around.co"]
        var text = ""
        if let u = url?.absoluteString { text += u + " " }
        if let n = notes { text += n + " " }
        if let l = location { text += l }
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for m in detector.matches(in: text, range: range) {
            if let u = m.url, let host = u.host?.lowercased(), hosts.contains(where: { host.contains($0) }) { return u }
        }
        return nil
    }

    /// True from 15 min before start until the event ends — when a Join button is most useful.
    var isJoinable: Bool {
        let now = Date()
        let end = endDate ?? startDate.addingTimeInterval(3600)
        return now >= startDate.addingTimeInterval(-15 * 60) && now <= end
    }
}

// MARK: - Average color of album art (for the Now Playing tint)

extension NSImage {
    var averageColor: NSColor? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}
