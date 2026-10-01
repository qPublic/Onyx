import AppKit
import SwiftUI
import Combine

// MARK: - Lid Awake: keeps the Mac running with the lid closed (a download, a render, music to a speaker). macOS always
// sleeps when the lid closes, unless sleep is turned off for the whole system, which only an administrator can do, so
// macOS asks for your password (Onyx never sees it). Turning it on also starts a small watcher that runs until Lid Awake
// is off again: it turns sleep back on if the battery runs down to the level you picked, or as soon as you switch Lid
// Awake off in Onyx, without asking for the password again. Nothing is left running after it's off, or after a restart.

@MainActor final class LidAwake: ObservableObject {
    static let shared = LidAwake()
    static let warnKey = "lid.warnAt", offKey = "lid.offAt"
    static let marker = "onyx-lid-watch"   // finds the watcher among running processes

    @Published private(set) var on = false
    @Published private(set) var problem: String?
    private var warned = false, bag = Set<AnyCancellable>()

    /// When the watcher sees this file, it turns sleep back on and stops.
    nonisolated static var offFlag: URL { Prefs.supportDir.appendingPathComponent("lid-awake-off") }

    func start() {
        refresh()
        // Still on from before a restart: the watcher is gone, so say so once.
        Task {
            try? await Task.sleep(for: .seconds(5))
            if on, await !Self.watcherRunning() {
                NotchModel.shared.flash(.message(icon: "laptopcomputer", text: "Lid Awake is still on. Turn it off in Settings › Behavior if you're done", tint: .orange), for: 5)
            }
        }
        let b = BatteryMonitor.shared
        b.$percent.combineLatest(b.$pluggedIn).removeDuplicates { $0 == $1 }.receive(on: DispatchQueue.main)
            .sink { [weak self] p, plugged in self?.battery(p, plugged: plugged) }.store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LidAwake.shared.refresh() }
        }
    }

    /// Whether macOS has sleep turned off right now (by Onyx or anything else).
    func refresh() {
        Task {
            let r = await Shell.read("/usr/bin/pmset", ["-g"])
            on = Self.sleepDisabled(r.output)
        }
    }
    nonisolated static func sleepDisabled(_ pmset: String) -> Bool {
        pmset.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1") }
    }

    func set(_ wanted: Bool) {
        if wanted { turnOn() } else { turnOff() }
    }

    private func turnOn() {
        let b = BatteryMonitor.shared
        if b.hasBattery && !b.pluggedIn {   // worth a word before it starts: a closed Mac in a bag keeps using power and gets warm
            let a = NSAlert()
            a.messageText = "Keep running with the lid closed on battery?"
            a.informativeText = "Your Mac will stay awake in a bag or backpack, keep using battery and can get warm. Onyx turns it off by itself at \(Self.offAt)% battery\(Self.offAt == 0 ? " (you picked never, so it won't)" : "")."
            a.addButton(withTitle: "Keep Running"); a.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        try? FileManager.default.removeItem(at: Self.offFlag)
        let cmd = "/usr/bin/pmset -a disablesleep 1; " + Self.startWatcher(pmset: "/usr/bin/pmset", flag: Self.offFlag.path, offAt: Self.offAt, interval: 5)
        Task {
            problem = await Self.asAdmin(cmd)
            refresh(); warned = false
            if problem == nil {
                NotchModel.shared.flash(.message(icon: "laptopcomputer", text: "Lid Awake on: your Mac keeps running with the lid closed", tint: .orange), for: 3)
            }
        }
    }

    private func turnOff() {
        Task {
            if await Self.watcherRunning() {   // the watcher turns sleep back on: no password needed
                FileManager.default.createFile(atPath: Self.offFlag.path, contents: nil)
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(250)); if await !Self.watcherRunning() { break } }
            } else {
                problem = await Self.asAdmin("/usr/bin/pmset -a disablesleep 0")
            }
            refresh()
        }
    }

    // MARK: Battery

    static var warnAt: Int { UserDefaults.standard.object(forKey: warnKey) as? Int ?? 20 }
    static var offAt: Int { UserDefaults.standard.object(forKey: offKey) as? Int ?? 10 }

    private func battery(_ percent: Int, plugged: Bool) {
        guard on, BatteryMonitor.shared.hasBattery else { return }
        if plugged { warned = false; return }
        if !warned && percent <= Self.warnAt {
            warned = true
            NotchModel.shared.flash(.message(icon: "battery.25percent", text: "Lid Awake is on and the battery is at \(percent)%", tint: .red), for: 6)
            NSSound(named: "Funk")?.play()
        }
    }

    // MARK: The watcher

    /// A shell command that starts the watcher in the background: every `interval` seconds it checks for the off flag and,
    /// on battery, the charge; at either it turns sleep back on and stops. Only numbers and a quoted path go into it.
    nonisolated static func startWatcher(pmset: String, flag: String, offAt: Int, interval: Int, battery: String = "/usr/bin/pmset -g batt") -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let loop = """
            : \(marker); while :; do [ -e \(q(flag)) ] && break; B=$(\(battery)); case "$B" in *"Battery Power"*) \
            P=$(echo "$B" | grep -Eo '[0-9]+%' | head -1 | tr -d '%'); [ -n "$P" ] && [ \(max(0, offAt)) -gt 0 ] && [ "$P" -le \(max(0, offAt)) ] && break;; esac; \
            sleep \(max(1, interval)); done; \(pmset) -a disablesleep 0; rm -f \(q(flag))
            """
        return "/usr/bin/nohup /bin/sh -c \(q(loop)) >/dev/null 2>&1 &"
    }

    nonisolated static func watcherRunning() async -> Bool {
        let r = await Shell.read("/usr/bin/pgrep", ["-f", marker])
        return !r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// macOS's own administrator prompt. nil if it worked, otherwise what went wrong (nothing for a cancelled prompt).
    static func asAdmin(_ command: String) async -> String? {
        let r = await Shell.runAdmin(command)
        if r.output.contains("-128") || r.output.localizedCaseInsensitiveContains("canceled") { return nil }   // you pressed Cancel
        return r.status == 0 ? nil : "macOS didn't allow it: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
    }
}

// MARK: - Settings › Behavior › Lid closed

struct LidAwakeSection: View {
    @ObservedObject var lid = LidAwake.shared
    @ObservedObject var battery = BatteryMonitor.shared
    @AppStorage(LidAwake.warnKey) private var warnAt = 20
    @AppStorage(LidAwake.offKey) private var offAt = 10

    var body: some View {
        Section {
            Toggle("Keep running with the lid closed", isOn: Binding(get: { lid.on }, set: { lid.set($0) }))
            if battery.hasBattery {
                Picker("Warn me when the battery is at", selection: $warnAt) { ForEach([30, 25, 20, 15], id: \.self) { Text("\($0)%").tag($0) } }
                Picker("Let it sleep again at", selection: $offAt) {
                    ForEach([20, 15, 10, 5], id: \.self) { Text("\($0)%").tag($0) }
                    Text("Never").tag(0)
                }
            }
            if let p = lid.problem { Text(p).font(.caption).foregroundStyle(.orange) }
            Text("For a download, a render or music to a speaker with the lid shut. macOS asks for your password to turn it on (Onyx never sees it). Turning it off in Onyx doesn't need it again, and it turns off by itself when the battery gets to the level above. A closed Mac in a bag stays awake and can get warm, so turn it off before you pack it. Change the levels before you turn it on.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Lid closed") }
        .onAppear { lid.refresh() }
    }
}
