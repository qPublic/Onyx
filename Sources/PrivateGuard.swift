import AppKit
import SwiftUI
import CoreServices
import ApplicationServices

// MARK: - Private windows: always on, and it can't be turned off. While any private or incognito browser window is open,
// Onyx records nothing and reads nothing from your screen, your browser or your clipboard.

final class PrivateGuard: @unchecked Sendable {
    static let shared = PrivateGuard()

    /// Whether a private window is open. Readable from any thread.
    static var active: Bool { shared.lock.withLock { shared.on || shared.forced } }
    /// What's open, like "a Chrome Incognito window".
    static var reason: String { shared.lock.withLock { shared.what } }

    private let lock = NSLock()
    private var on = false, what = "", forced = false
    private var observers: [pid_t: AXObserver] = [:]
    private var pending = false
    private var safariSeen = 0            // Safari windows open when one in front was private
    private let queue = DispatchQueue(label: "onyx.private", qos: .utility)   // browsers are asked one at a time, off the main thread

    static let chromium = ["com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome", "com.google.Chrome.canary": "Chrome",
                           "com.brave.Browser": "Brave", "com.microsoft.edgemac": "Edge", "com.vivaldi.Vivaldi": "Vivaldi",
                           "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium", "company.thebrowser.Browser": "Arc"]
    static let firefox = ["org.mozilla.firefox": "Firefox", "org.mozilla.firefoxdeveloperedition": "Firefox", "org.mozilla.nightly": "Firefox",
                          "app.zen-browser.zen": "Zen", "io.gitlab.librewolf-community": "LibreWolf"]
    static func isBrowser(_ id: String) -> Bool { chromium[id] != nil || firefox[id] != nil || id == "com.apple.Safari" }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.watch(app) }
            self?.soon()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observers[app.processIdentifier] = nil }
            self?.soon()
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.soon() }
        NSWorkspace.shared.runningApplications.forEach(watch)
        // Window events can slip past (a window closed in the background): look again every 10 seconds while a browser runs.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            if NSWorkspace.shared.runningApplications.contains(where: { Self.isBrowser($0.bundleIdentifier ?? "") }) { self?.soon() }
        }.tolerant(0.3)
        soon()
    }

    /// Hears a browser open, close or switch windows, and looks again.
    private func watch(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, Self.isBrowser(id), observers[app.processIdentifier] == nil, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, ctx in
            guard let ctx else { return }
            Unmanaged<PrivateGuard>.fromOpaque(ctx).takeUnretainedValue().soon()
        }, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[app.processIdentifier] = obs
    }

    private func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.pending = false
            let apps = NSWorkspace.shared.runningApplications.filter { Self.isBrowser($0.bundleIdentifier ?? "") }
            self.queue.async { self.set(self.find(apps)) }
        }
    }

    /// The first private window found, if any.
    private func find(_ apps: [NSRunningApplication]) -> String? {
        for app in apps {
            guard let id = app.bundleIdentifier else { continue }
            if let name = Self.chromium[id], chromiumPrivate(app, id: id) { return "a \(name) Incognito window" }
            if let name = Self.firefox[id], titles(app).contains(where: { $0.localizedCaseInsensitiveContains("Private Browsing") }) { return "a \(name) private window" }
            if id == "com.apple.Safari", safariPrivate(app) { return "a Safari private window" }
        }
        if !apps.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) { safariSeen = 0 }
        return nil
    }

    private func set(_ found: String?) {
        let now = found != nil
        let changed: Bool = lock.withLock { let c = on != now; on = now; what = found ?? ""; return c }
        guard changed else { return }
        DispatchQueue.main.async {
            if now {
                QuickCapture.shared.stopIfRecording()
                NotchModel.shared.flash(.message(icon: "eye.slash.fill", text: "Private window open: Onyx isn't recording or reading anything", tint: .purple), for: 4)
            }
            NotificationCenter.default.post(name: .init("onyx.private"), object: nil)
        }
    }

    /// For anything that captures or reads: true while a private window is open, and the notch says why.
    static func blocks() -> Bool {
        guard active else { return false }
        DispatchQueue.main.async { NotchModel.shared.flash(.message(icon: "eye.slash.fill", text: "Paused while a private window is open", tint: .purple), for: 2.5) }
        return true
    }

    /// Self-test: act as if a private window were open (or not).
    func force(_ on: Bool) { lock.withLock { forced = on } }

    // MARK: Asking each browser

    /// Chromium browsers say which windows are incognito when Onyx may control them (it never asks for that here);
    /// otherwise their Incognito badge shows in the window's toolbar.
    private func chromiumPrivate(_ app: NSRunningApplication, id: String) -> Bool {
        if Self.mayControl(id) {
            let arc = id == "company.thebrowser.Browser"
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "with timeout of 2 seconds", "-e", "tell application id \"\(id)\" to get \(arc ? "incognito" : "mode") of every window", "-e", "end timeout"]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
                p.waitUntilExit()
                if p.terminationStatus == 0 { return arc ? out.contains("true") : out.contains("incognito") }
            }
        }
        return windows(app).contains { contains($0, ["Incognito", "InPrivate"], depth: 5) }
    }

    /// Safari doesn't tell other apps which windows are private, but its Window menu does for the one in front
    /// ("Move Tab to New Private Window"). Once seen, Onyx stays paused until a Safari window closes.
    private func safariPrivate(_ app: NSRunningApplication) -> Bool {
        let all = windows(app), count = all.count
        if all.contains(where: { (string($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains("Private Browsing") }) || frontIsPrivate(app) {
            safariSeen = max(safariSeen, count); return true
        }
        if safariSeen > 0, count >= safariSeen { return true }   // the private window may be behind another one
        safariSeen = 0
        return false
    }

    private func frontIsPrivate(_ app: NSRunningApplication) -> Bool {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        guard let bar = element(el, kAXMenuBarAttribute) else { return false }
        for item in children(bar) where string(item, kAXTitleAttribute) == "Window" {
            for menu in children(item) {
                if children(menu).contains(where: { (string($0, kAXTitleAttribute) ?? "").contains("New Private Window") && (string($0, kAXTitleAttribute) ?? "").hasPrefix("Move") }) { return true }
            }
        }
        return false
    }

    static func mayControl(_ bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let data = Data(bundleID.utf8)
        let made = data.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, data.count, &target) }
        guard made == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
    }

    private func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }
    private func titles(_ app: NSRunningApplication) -> [String] { windows(app).compactMap { string($0, kAXTitleAttribute) } }
    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
    }
    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success ? v as? [AXUIElement] ?? [] : []
    }
    /// A badge like "Incognito" near the top of a window (not deep in the page, so a web page can't trip it).
    private func contains(_ el: AXUIElement, _ words: [String], depth: Int) -> Bool {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(el, a), words.contains(where: { s == $0 || s.hasPrefix($0 + " ") }) { return true }
        }
        guard depth > 0, string(el, kAXRoleAttribute) != "AXWebArea" else { return false }
        return children(el).prefix(40).contains { contains($0, words, depth: depth - 1) }
    }
}

// MARK: - Settings › Privacy

struct PrivateWindowsSection: View {
    @State private var active = PrivateGuard.active

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: active ? "eye.slash.fill" : "eye.slash").foregroundStyle(.purple)
                Text(active ? "Paused now: \(PrivateGuard.reason) is open." : "No private windows are open.")
                Spacer()
                Text("Always on").font(.caption).foregroundStyle(.secondary)
            }
            Text("While a private or incognito window is open in Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera or Firefox, Onyx records nothing and reads nothing from your screen, your browser or your clipboard. A screen recording stops. Screenshots, Circle to Search and Copy Text wait. Onyx AI can't look at your screen or what you've selected. Clipboard history skips what you copy. Focus sessions don't read websites, and academy sign-up waits. This can't be turned off.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Private windows") }
        .onReceive(NotificationCenter.default.publisher(for: .init("onyx.private"))) { _ in active = PrivateGuard.active }
    }
}
