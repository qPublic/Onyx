import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - User-rebindable global shortcuts

struct Shortcut: Equatable {
    var keyCode: Int
    var mods: UInt   // NSEvent.ModifierFlags raw value (command/option/control/shift only)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
                                      100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        data.withUnsafeBytes { buf in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            _ = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        let s = String(utf16CodeUnits: chars, count: len).uppercased()
        return s.isEmpty ? "#\(code)" : s
    }
}

enum HotAction: String, CaseIterable, Identifiable {
    case toggleNotch, toggleHide, circleSearch, askAI, captureRegion, captureScreen, toggleRecording, openLauncher, askSelection, clipboardPicker, copyText
    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleNotch: "Open / close notch"
        case .toggleHide: "Hide / show notch"
        case .circleSearch: "Circle to Search"
        case .askAI: "Ask AI"
        case .captureRegion: "Screenshot region"
        case .captureScreen: "Screenshot full screen"
        case .toggleRecording: "Start / stop screen recording"
        case .openLauncher: "Open App Launcher"
        case .askSelection: "Ask AI about selected text"
        case .clipboardPicker: "Clipboard history (paste)"
        case .copyText: "Copy text from screen"
        }
    }

    var defaultShortcut: Shortcut? {
        let co = NSEvent.ModifierFlags([.control, .option]).rawValue
        switch self {
        case .toggleNotch: return Shortcut(keyCode: 45, mods: co)      // ⌃⌥N
        case .toggleHide: return Shortcut(keyCode: 4, mods: co)        // ⌃⌥H
        case .circleSearch: return Shortcut(keyCode: 49, mods: co)     // ⌃⌥Space
        case .askAI: return Shortcut(keyCode: 0, mods: co)             // ⌃⌥A
        case .captureRegion: return Shortcut(keyCode: 21, mods: co)    // ⌃⌥4
        case .captureScreen: return Shortcut(keyCode: 20, mods: co)    // ⌃⌥3
        case .toggleRecording: return Shortcut(keyCode: 23, mods: co)  // ⌃⌥5
        case .openLauncher: return nil                                 // none until you pick one
        case .askSelection: return Shortcut(keyCode: 1, mods: co)      // ⌃⌥S
        case .clipboardPicker: return Shortcut(keyCode: 9, mods: co)   // ⌃⌥V
        case .copyText: return Shortcut(keyCode: 17, mods: co)         // ⌃⌥T
        }
    }

    func perform() {
        let d = NSApp.delegate as? AppDelegate
        switch self {
        case .toggleNotch:
            if let n = NotchController.current, n.model.expanded { n.collapse() } else { d?.openNotch() }
        case .toggleHide: d?.toggleHide()
        case .circleSearch: CircleToSearch.shared.begin()
        case .askAI: NotchController.current?.expand(tab: .ai, focus: true)
        case .captureRegion: QuickCapture.shared.screenshot(.region)
        case .captureScreen: QuickCapture.shared.screenshot(.screen)
        case .toggleRecording: QuickCapture.shared.toggleRecording()
        case .openLauncher: MainActor.assumeIsolated { AppLauncher.shared.toggle() }   // hotkeys fire on the main thread
        case .askSelection: Task { @MainActor in await SelectionGrabber.askAI() }
        case .clipboardPicker: MainActor.assumeIsolated { ClipboardPicker.shared.toggle() }
        case .copyText: MainActor.assumeIsolated { TextGrabber.fromScreen() }
        }
    }
}

enum Shortcuts {
    private static func key(_ a: HotAction) -> String { "hk." + a.rawValue }

    /// The user's binding, the default if never changed, or nil if cleared.
    static func get(_ a: HotAction) -> Shortcut? {
        guard let s = UserDefaults.standard.string(forKey: key(a)) else { return a.defaultShortcut }
        let p = s.split(separator: ",")
        guard p.count == 2, let c = Int(p[0]), let m = UInt(p[1]) else { return nil }
        return Shortcut(keyCode: c, mods: m)
    }

    static func set(_ a: HotAction, _ s: Shortcut?) {
        // A combo can only do one thing: take it away from any other action first.
        if let s { for other in HotAction.allCases where other != a && get(other) == s { UserDefaults.standard.set("", forKey: key(other)) } }
        UserDefaults.standard.set(s.map { "\($0.keyCode),\($0.mods)" } ?? "", forKey: key(a))
        reload()
    }

    static func reset() {
        HotAction.allCases.forEach { UserDefaults.standard.removeObject(forKey: key($0)) }
        reload()
        if SpotlightKey.isOn { Task { await SpotlightKey.set(false) } }   // the default is Spotlight on ⌘Space
    }

    static func reload() {
        HotKeys.shared.unregisterAll()
        for a in HotAction.allCases {
            if let s = get(a) { HotKeys.shared.register(keyCode: s.keyCode, modifiers: s.flags) { a.perform() } }
        }
    }
}

// MARK: - ⌘Space for the App Launcher

/// Takes ⌘Space from Spotlight for the App Launcher. Spotlight moves to ⌥⌘Space, and Finder's search window, which
/// macOS also puts on ⌥⌘Space, is turned off. What was there before is saved and put back when this is turned off.
enum SpotlightKey {
    static let key = "spotlight.swapped"
    private static let savedKey = "spotlight.saved"
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let list = "AppleSymbolicHotKeys" as CFString
    static let spotlight = "64", finderSearch = "65"   // macOS's ids for these two shortcuts
    static let cmdSpace = Shortcut(keyCode: 49, mods: NSEvent.ModifierFlags.command.rawValue)
    static let cmd = 1 << 20, opt = 1 << 19

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    private static func entry(_ mods: Int, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [32, 49, mods], "type": "standard"]]
    }
    /// macOS leaves a shortcut out of the list while it's still the default.
    private static let builtIn = [spotlight: entry(cmd), finderSearch: entry(cmd | opt)]

    static func read() -> [String: Any] {
        CFPreferencesCopyValue(list, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private static func write(_ d: [String: Any]) {
        CFPreferencesSetValue(list, d as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func enabled(_ d: [String: Any], _ id: String) -> Bool {
        ((d[id] ?? builtIn[id]) as? [String: Any])?["enabled"] as? Bool ?? false
    }

    /// Whether that shortcut is turned on and set to Space with exactly these modifiers.
    static func uses(_ d: [String: Any], _ id: String, mods: Int) -> Bool {
        guard enabled(d, id), let v = ((d[id] ?? builtIn[id]) as? [String: Any])?["value"] as? [String: Any],
              let p = v["parameters"] as? [Int], p.count == 3 else { return false }
        return p[1] == 49 && p[2] & 0x1E0000 == mods
    }

    /// Makes macOS pick up the new shortcuts now instead of at the next login.
    private static func activate() async {
        _ = await Shell.read("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    @MainActor static func set(_ on: Bool) async {
        guard on != isOn else { return }
        var d = read()
        if on {
            var saved: [String: Any] = [:]   // the old entry, or "default" if there wasn't one
            if uses(d, spotlight, mods: cmd) {
                saved[spotlight] = d[spotlight] ?? "default"
                d[spotlight] = entry(cmd | opt)
                if uses(d, finderSearch, mods: cmd | opt) {
                    saved[finderSearch] = d[finderSearch] ?? "default"
                    d[finderSearch] = entry(cmd | opt, enabled: false)
                }
            }
            UserDefaults.standard.set(saved, forKey: savedKey)
            UserDefaults.standard.set(true, forKey: key)
            if !saved.isEmpty { write(d); await activate() }
            Shortcuts.set(.openLauncher, cmdSpace)
        } else {
            let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
            var wasDefault: [String] = []
            func restore(_ id: String) {
                if let old = saved[id] as? [String: Any] { d[id] = old } else { d[id] = builtIn[id]; wasDefault.append(id) }
            }
            // Only put back what's still the way Onyx left it, in case it was changed in System Settings since.
            if saved[spotlight] != nil, uses(d, spotlight, mods: cmd | opt) { restore(spotlight) }
            if saved[finderSearch] != nil, !enabled(d, finderSearch) { restore(finderSearch) }
            UserDefaults.standard.removeObject(forKey: savedKey)
            UserDefaults.standard.set(false, forKey: key)
            if !saved.isEmpty {
                // macOS only applies shortcuts that are written out, so write the defaults, apply them, then drop them again.
                write(d); await activate()
                if !wasDefault.isEmpty { wasDefault.forEach { d.removeValue(forKey: $0) }; write(d) }
            }
            for a in HotAction.allCases where Shortcuts.get(a) == cmdSpace { Shortcuts.set(a, nil) }   // Spotlight has it again
        }
    }
}

// MARK: - Recorder control for Settings

struct ShortcutRecorder: View {
    let action: HotAction
    @State private var recording = false
    @State private var current: Shortcut?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : (current?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : (current == nil ? .secondary : .primary))
                    .frame(minWidth: 96)
            }
            if current != nil && !recording {
                Button { Shortcuts.set(action, nil); current = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
            }
        }
        .onAppear { current = Shortcuts.get(action) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if !recording { current = Shortcuts.get(action) }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        HotKeys.shared.unregisterAll()   // so pressing an existing combo records it instead of firing it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                     // Esc cancels
            let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !m.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }  // needs ⌘, ⌥ or ⌃
            let s = Shortcut(keyCode: Int(e.keyCode), mods: m.rawValue)
            current = s
            stop()
            Shortcuts.set(action, s)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Shortcuts.reload()
    }
}
