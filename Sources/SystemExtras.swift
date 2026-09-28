import AppKit
import SwiftUI
import IOKit
import IOKit.ps
import CoreAudio
import AudioToolbox

// MARK: - Battery health (Optimization › Battery)

struct BatteryHealth {
    var cycles: Int?
    var design: Int?          // mAh when new
    var full: Int?            // mAh it holds now
    var temperature: Double?  // °C
    var condition: String?    // macOS's own verdict: Normal / Service Recommended
    var adapterWatts: Int?
    var health: Int? { guard let d = design, let f = full, d > 0 else { return nil }; return min(100, Int((Double(f) / Double(d) * 100).rounded())) }

    /// From the battery's own controller (AppleSmartBattery); no permission needed.
    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        var h = BatteryHealth()
        h.cycles = d["CycleCount"] as? Int
        h.design = d["DesignCapacity"] as? Int
        h.full = d["AppleRawMaxCapacity"] as? Int ?? d["NominalChargeCapacity"] as? Int
        h.temperature = (d["Temperature"] as? Int).map { Double($0) / 100 }
        h.adapterWatts = (d["AdapterDetails"] as? [String: Any])?["Watts"] as? Int
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let c = desc[kIOPSBatteryHealthKey] as? String { h.condition = c == "Good" ? "Normal" : c == "Poor" ? "Service Recommended" : c }
            }
        }
        return h
    }

    /// The apps using the most energy right now (macOS's own "power" score, from top).
    static func energyUsers() async -> [(name: String, power: Double)] {
        let r = await Shell.read("/usr/bin/top", ["-l", "2", "-n", "8", "-o", "power", "-stats", "command,power"])
        // Two samples: the second has real numbers. Skip the header and Onyx's own `top`.
        guard let last = r.output.components(separatedBy: "COMMAND").last else { return [] }
        return last.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let p = Double(parts.last!), p >= 0.5 else { return nil }
            let name = parts.dropLast().joined(separator: " ")
            return name == "top" ? nil : (name, p)
        }
    }
}

/// Plugged in and reached 80%: a nudge to unplug, which is easier on the battery (Optimization › Battery; off by default).
enum ChargeReminder {
    static let key = "battery.remind80"
    private static var shown = false
    static func check(percent: Int, plugged: Bool) {
        guard Prefs.bool(key) else { return }
        if !plugged || percent < 75 { shown = false; return }
        if percent >= 80 && !shown {
            shown = true
            NotchModel.shared.flash(.message(icon: "battery.75percent", text: "80% charged: unplug to save your battery", tint: .green), for: 5)
        }
    }
}

struct OptBattery: View {
    @ObservedObject var battery = BatteryMonitor.shared
    @AppStorage(ChargeReminder.key) private var remind80 = false
    @State private var health = BatteryHealth.read()
    @State private var users: [(name: String, power: Double)] = []
    @State private var loading = false

    var body: some View {
        Form {
            if let h = health {
                Section("Health") {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 10)
                            Circle().trim(from: 0, to: Double(h.health ?? 0) / 100)
                                .stroke((h.health ?? 100) >= 80 ? Color.green : (h.health ?? 100) >= 70 ? .orange : .red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text(h.health.map { "\($0)%" } ?? "–").font(.system(size: 20, weight: .bold)).monospacedDigit()
                                Text("health").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 92, height: 92)
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent("Condition", value: h.condition ?? "Normal")
                            LabeledContent("Charge cycles", value: h.cycles.map(String.init) ?? "–")
                            LabeledContent("Holds", value: h.full.map { "\($0.formatted()) of \((h.design ?? $0).formatted()) mAh" } ?? "–")
                            LabeledContent("Temperature", value: h.temperature.map { String(format: "%.0f °C", $0) } ?? "–")
                        }
                    }
                    Text("Health is how much charge the battery holds compared with when it was new. Batteries in Macs are designed to keep 80% for 1,000 cycles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Right now") {
                    LabeledContent("Charge", value: "\(battery.percent)%" + (battery.pluggedIn ? (battery.charging ? " · charging" : " · on power") : " · on battery"))
                    if let m = battery.minutesLeft { LabeledContent(battery.pluggedIn ? "Until full" : "Time left", value: "\(m / 60)h \(m % 60)m") }
                    if let w = h.adapterWatts, battery.pluggedIn { LabeledContent("Charger", value: "\(w) W") }
                }
            } else {
                Section { Text("This Mac doesn't have a battery.").foregroundStyle(.secondary) }
            }
            Section("Using the most energy") {
                if users.isEmpty {
                    HStack { if loading { ProgressView().controlSize(.small) }; Text(loading ? "Measuring…" : "Nothing much right now.").foregroundStyle(.secondary) }
                }
                ForEach(users, id: \.name) { u in
                    HStack {
                        Text(u.name).lineLimit(1)
                        Spacer()
                        Capsule().fill(u.power > 20 ? Color.orange : .green).frame(width: min(140, CGFloat(u.power) * 2), height: 6)
                        Text(String(format: "%.0f", u.power)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
                Button("Measure again") { Task { await measure() } }.disabled(loading)
            }
            if health != nil {
                Section("Charging") {
                    Toggle("Remind me to unplug at 80%", isOn: $remind80)
                    Text("Keeping a battery between 20% and 80% makes it last longer. macOS's Optimized Battery Charging (System Settings › Battery) also helps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    private func measure() async {
        loading = true
        health = BatteryHealth.read()
        users = await BatteryHealth.energyUsers()
        loading = false
    }
}

// MARK: - Focus sessions: a timer that blocks distracting apps and sites, and keeps a streak

final class FocusSession: ObservableObject {
    static let shared = FocusSession()
    static let appsKey = "focus.apps", sitesKey = "focus.sites", daysKey = "focus.days"
    @Published private(set) var active = false
    @Published var blockedApps: [String] = UserDefaults.standard.stringArray(forKey: appsKey) ?? [] {   // bundle ids
        didSet { UserDefaults.standard.set(blockedApps, forKey: Self.appsKey) }
    }
    @Published var blockedSites: String = UserDefaults.standard.string(forKey: sitesKey) ?? "youtube.com, instagram.com, tiktok.com, reddit.com, x.com" {
        didSet { UserDefaults.standard.set(blockedSites, forKey: Self.sitesKey) }
    }
    private var watcher: Any?
    private var poll: Timer?
    private var lastBlocked = Date.distantPast

    var sites: [String] {
        blockedSites.lowercased().split { $0 == "," || $0 == " " || $0 == "\n" }.map { s in
            var t = String(s)
            for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }.filter { !$0.isEmpty }
    }

    func begin(minutes: Double) {
        FocusTimer.shared.begin(minutes: minutes)
        active = true
        watcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.check(app)
        }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }.tolerant(0.2)
        if let front = NSWorkspace.shared.frontmostApplication { check(front) }
        NotchModel.shared.flash(.message(icon: "scope", text: "Focus for \(Int(minutes)) minutes. You've got this", tint: .indigo), for: 3)
    }

    /// The timer ran out (a finished session counts toward your streak) or was cancelled.
    func finish(completed: Bool) {
        guard active else { return }
        active = false
        if let watcher { NSWorkspace.shared.notificationCenter.removeObserver(watcher) }; watcher = nil
        poll?.invalidate(); poll = nil
        if completed {
            var days = Set(UserDefaults.standard.stringArray(forKey: Self.daysKey) ?? [])
            days.insert(Self.day(Date()))
            UserDefaults.standard.set(Array(days), forKey: Self.daysKey)
            objectWillChange.send()
            NotchModel.shared.flash(.message(icon: "flame.fill", text: "Focus done! \(streak)-day streak", tint: .orange), for: 5)
        }
    }

    /// Days in a row (up to today) with at least one finished session.
    var streak: Int {
        let days = Set(UserDefaults.standard.stringArray(forKey: Self.daysKey) ?? [])
        var d = Date(), n = 0
        if !days.contains(Self.day(d)) { d = Calendar.current.date(byAdding: .day, value: -1, to: d) ?? d }   // today's doesn't break it yet
        while days.contains(Self.day(d)) { n += 1; d = Calendar.current.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }
    var doneToday: Bool { (UserDefaults.standard.stringArray(forKey: Self.daysKey) ?? []).contains(Self.day(Date())) }
    static func day(_ d: Date) -> String { d.formatted(.iso8601.year().month().day()) }

    private func tick() {
        if active && !FocusTimer.shared.running { finish(completed: false); return }   // cancelled from the Timer
        if let front = NSWorkspace.shared.frontmostApplication { checkSite(front) }
    }

    private func check(_ app: NSRunningApplication) {
        guard active, let id = app.bundleIdentifier, blockedApps.contains(id) else { return }
        app.hide()
        blocked(app.localizedName ?? "That app")
    }

    /// In Safari or a Chromium browser, a blocked site's tab is sent to a blank page.
    private func checkSite(_ app: NSRunningApplication) {
        guard active, !sites.isEmpty, let id = app.bundleIdentifier else { return }
        let chromium = ["com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser", "com.microsoft.edgemac": "Microsoft Edge",
                        "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi"]
        let sites = self.sites
        DispatchQueue.global(qos: .utility).async {
            let getURL: String, blank: String
            if id == "com.apple.Safari" {
                getURL = "tell application \"Safari\" to return URL of front document"
                blank = "tell application \"Safari\" to set URL of front document to \"about:blank\""
            } else if let name = chromium[id] {
                getURL = "tell application \"\(name)\" to return URL of active tab of front window"
                blank = "tell application \"\(name)\" to set URL of active tab of front window to \"about:blank\""
            } else { return }
            guard let url = MediaController.run(getURL), let host = URL(string: url)?.host?.lowercased() else { return }
            guard let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) }) else { return }
            _ = MediaController.run(blank)
            DispatchQueue.main.async { self.blocked(site) }
        }
    }

    private func blocked(_ what: String) {
        guard Date().timeIntervalSince(lastBlocked) > 3 else { return }
        lastBlocked = Date()
        let left = Int(FocusTimer.shared.remaining / 60) + 1
        NotchModel.shared.flash(.message(icon: "hand.raised.fill", text: "\(what) is blocked · \(left) min left", tint: .indigo), for: 3)
    }
}

struct FocusSessionView: View {
    @ObservedObject var session = FocusSession.shared
    @ObservedObject var timer = FocusTimer.shared
    @State private var minutes = 25.0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: session.active && timer.total > 0 ? timer.remaining / timer.total : 0)
                        .stroke(.indigo, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(session.active ? format(timer.remaining) : "\(Int(minutes)):00").font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(session.streak > 0 ? "🔥 \(session.streak) day\(session.streak == 1 ? "" : "s")" : "no streak yet").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)
                if session.active {
                    Button("End early", role: .destructive) { FocusTimer.shared.cancel(); session.finish(completed: false) }.controlSize(.small)
                } else {
                    Picker("", selection: $minutes) { ForEach([15.0, 25, 50, 90], id: \.self) { Text("\(Int($0))m").tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150).controlSize(.small)
                    Button { session.begin(minutes: minutes) } label: { Label("Start focus", systemImage: "scope") }
                        .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Block these sites").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                TextField("youtube.com, reddit.com", text: $session.blockedSites, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).lineLimit(2...3).disabled(session.active)
                HStack {
                    Text("And these apps").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu { ForEach(runningApps, id: \.0) { id, name in Button(name) { session.blockedApps.append(id) } } } label: { Image(systemName: "plus.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(session.active)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.blockedApps, id: \.self) { id in
                            HStack(spacing: 3) {
                                Text(appName(id)).font(.system(size: 10.5))
                                if !session.active { Button { session.blockedApps.removeAll { $0 == id } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain) }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Color.indigo.opacity(0.2), in: Capsule())
                        }
                        if session.blockedApps.isEmpty { Text("None").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    }
                }
                Text("Sites are blocked in Safari, Chrome, Arc, Brave and Edge (macOS asks once to let Onyx see the page). Finish a session to keep your streak.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !session.blockedApps.contains($0.0) }
            .sorted { $0.1 < $1.1 }
    }
    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
}

// MARK: - Quick toggles (Tools › System)

@MainActor final class QuickToggles: ObservableObject {
    static let shared = QuickToggles()
    static let dndShortcut = "Onyx Do Not Disturb"
    @Published private(set) var dark = false
    @Published private(set) var iconsHidden = false
    @Published private(set) var micMuted = false
    private var savedMicVolume: Float32 = 0.75

    func refresh() {
        dark = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
        iconsHidden = (CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool) == false
        micMuted = Self.micIsMuted()
    }

    func toggleDark() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MediaController.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func toggleDesktopIcons() {
        let hide = !iconsHidden
        Task {
            _ = await Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hide ? "false" : "true"])
            _ = await Shell.run("/usr/bin/killall", ["Finder"])
            refresh()
        }
    }

    /// macOS has no public switch for Do Not Disturb, so this runs a one-action shortcut you make once in Shortcuts.
    func toggleDND() {
        Task {
            let list = await Shell.read("/usr/bin/shortcuts", ["list"])
            if list.output.split(separator: "\n").contains(where: { $0 == Self.dndShortcut }) {
                _ = await Shell.read("/usr/bin/shortcuts", ["run", Self.dndShortcut])
            } else {
                let a = NSAlert()
                a.messageText = "One-time setup for Do Not Disturb"
                a.informativeText = "macOS only lets apps switch Focus through Shortcuts. In the Shortcuts app, make a new shortcut named \"\(Self.dndShortcut)\" with one action: Set Focus › Do Not Disturb › Toggle. Then this button switches it on and off."
                a.addButton(withTitle: "Open Shortcuts"); a.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
        }
    }

    // Microphone: mute the default input if it can be muted, else turn its input volume down to 0 and back.
    private static func input() -> AudioObjectID? {
        var dev = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr && dev != 0 ? dev : nil
    }
    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    }
    static func micIsMuted() -> Bool {
        guard let d = input() else { return false }
        var a = addr(kAudioDevicePropertyMute), m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(d, &a), AudioObjectGetPropertyData(d, &a, 0, nil, &size, &m) == noErr, m == 1 { return true }
        var v = addr(kAudioDevicePropertyVolumeScalar), vol = Float32(1); size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectHasProperty(d, &v) && AudioObjectGetPropertyData(d, &v, 0, nil, &size, &vol) == noErr && vol < 0.01
    }
    func toggleMic() {
        guard let d = Self.input() else { return }
        let mute = !micMuted
        var a = Self.addr(kAudioDevicePropertyMute), settable = DarwinBoolean(false)
        if AudioObjectHasProperty(d, &a), AudioObjectIsPropertySettable(d, &a, &settable) == noErr, settable.boolValue {
            var m = UInt32(mute ? 1 : 0)
            AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        } else {
            var v = Self.addr(kAudioDevicePropertyVolumeScalar), size = UInt32(MemoryLayout<Float32>.size)
            if mute { var cur = Float32(0); if AudioObjectGetPropertyData(d, &v, 0, nil, &size, &cur) == noErr, cur > 0.01 { savedMicVolume = cur } }
            var vol: Float32 = mute ? 0 : savedMicVolume
            AudioObjectSetPropertyData(d, &v, 0, nil, size, &vol)
        }
        refresh()
        NotchModel.shared.flash(.message(icon: micMuted ? "mic.slash.fill" : "mic.fill", text: micMuted ? "Microphone muted" : "Microphone on", tint: micMuted ? .red : .green), for: 1.8)
    }
}

struct QuickTogglesGrid: View {
    @ObservedObject var t = QuickToggles.shared
    @ObservedObject var caf = Caffeinate.shared
    @ObservedObject var focus = FocusMonitor.shared

    var body: some View {
        HStack(spacing: 6) {
            tile(t.dark ? "moon.fill" : "sun.max.fill", "Dark", on: t.dark, tint: .indigo) { t.toggleDark() }
            tile("moon.zzz.fill", "Do Not Disturb", on: focus.isFocused == true, tint: .purple) { t.toggleDND() }
            tile("cup.and.saucer.fill", "Keep awake", on: caf.active, tint: .orange) { caf.active ? caf.disable() : caf.enable(hours: nil) }
            tile(t.iconsHidden ? "eye.slash.fill" : "menubar.dock.rectangle", "Hide icons", on: t.iconsHidden, tint: .teal) { t.toggleDesktopIcons() }
            tile(t.micMuted ? "mic.slash.fill" : "mic.fill", "Mute mic", on: t.micMuted, tint: .red) { t.toggleMic() }
        }
        .onAppear { t.refresh() }
    }

    private func tile(_ icon: String, _ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? .white : .primary)
                Text(title).font(.system(size: 8.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(on ? tint.opacity(0.85) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).help(title)
    }
}
