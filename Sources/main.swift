import AppKit
import QuartzCore
import SwiftUI
import ServiceManagement
import Intents
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var notch: NotchController!
    var statusItem: NSStatusItem!
    var hideItem: NSMenuItem?
    var settingsWindow: NSWindow?
    var optimizeWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        // Lazy services: only what the idle notch needs starts now; heavier ones start on first use.
        MediaController.shared.start()
        BatteryMonitor.shared.start()
        VolumeMonitor.shared.start()
        WeatherService.shared.start()
        ClipboardHistory.shared.start()
        FocusTimer.shared.start()
        CalendarService.shared.start()
        SportsService.shared.start()
        MarketsService.shared.start()
        BluetoothService.shared.start()
        FunController.shared.start()
        BackdropSampler.shared.start()
        CanvasService.shared.start()
        DownloadMonitor.shared.start()

        notch = NotchController()
        notch.show()
        Snapshot.runIfRequested()
        setupStatusItem()
        MemoryTrimmer.shared.observe()
        MenuBarDodger.shared.promptIfNeeded()   // ask for Accessibility if a feature that needs it is on
        MediaKeys.shared.start()                // replace the native volume slider (when granted + enabled)
        SnapController.shared.start()           // drag a window to the notch → snap layouts
        // Cap every Accessibility call (snap layouts, fullscreen check, menu dodge) so a frozen app
        // can't stall Onyx for the 6s default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        OptimizeService.shared.start()          // low-disk alert + optional weekly clean
        AutoQuit.shared.start()                 // optional: quit apps that have no windows
        MemoryWatch.shared.start()              // optional: per-app memory limit (warn or quit)
        // Debug: ONYX_OPTIMIZE_TEST=1 dry-runs every Optimization action into optimize-dryrun.log, then quits.
        if ProcessInfo.processInfo.environment["ONYX_OPTIMIZE_TEST"] != nil {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await OptimizeSelfTest.run() }
        }
        // Debug: ONYX_CAPTURETEST=screen|record takes a full-screen shot / 3s recording shortly after launch.
        if let t = ProcessInfo.processInfo.environment["ONYX_CAPTURETEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if t == "record" {
                    QuickCapture.shared.toggleRecording()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { QuickCapture.shared.toggleRecording() }
                } else { QuickCapture.shared.screenshot(.screen) }
            }
        }
        // Debug: ONYX_SLIDETEST=1 nudges the notch sideways and back to exercise the glide animation.
        if ProcessInfo.processInfo.environment["ONYX_SLIDETEST"] != nil {
            let old = UserDefaults.standard.double(forKey: AP.hOffset)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { UserDefaults.standard.set(old + 300, forKey: AP.hOffset) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { UserDefaults.standard.set(old, forKey: AP.hOffset) }
        }
        // Debug: ONYX_HUDTEST=<png path> flashes the volume pop-out and screenshots the real screen.
        // ONYX_HUDTEST_VISIBLE=1 temporarily turns off "hide from screen recordings" for the shot.
        if let path = ProcessInfo.processInfo.environment["ONYX_HUDTEST"] {
            let visible = ProcessInfo.processInfo.environment["ONYX_HUDTEST_VISIBLE"] != nil
            let old = Prefs.bool(AP.hideFromCapture)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if visible { UserDefaults.standard.set(false, forKey: AP.hideFromCapture) }
                NotchModel.shared.flash(.volume(0.6, muted: false), for: 3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", path]; try? p.run(); p.waitUntilExit()
                    UserDefaults.standard.set(old, forKey: AP.hideFromCapture)
                }
            }
        }
        // Debug: ONYX_FOCUSTEST=<dir> captures the volume pop-out unfocused (A.png) then focused (B.png).
        if let dir = ProcessInfo.processInfo.environment["ONYX_FOCUSTEST"] {
            func shot(_ name: String) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", dir + "/" + name]; try? p.run(); p.waitUntilExit()
                // Also capture just the notch window (no backdrop from other apps).
                if let wid = NotchController.current?.panel.windowNumber {
                    let q = Process(); q.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    q.arguments = ["-x", "-o", "-l\(wid)", dir + "/win-" + name]; try? q.run(); q.waitUntilExit()
                }
            }
            let old = Prefs.bool(AP.hideFromCapture)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UserDefaults.standard.set(false, forKey: AP.hideFromCapture)
                NotchModel.shared.flash(.volume(0.6, muted: false), for: 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    shot("A.png")
                    let prev = NSWorkspace.shared.frontmostApplication
                    NSApp.activate(ignoringOtherApps: true)
                    NotchController.current?.panel.makeKey()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let key = NotchController.current?.panel.isKeyWindow ?? false
                        shot("B.png")
                        try? "panelKey=\(key) appActive=\(NSApp.isActive)\n".write(toFile: dir + "/focus.txt", atomically: true, encoding: .utf8)
                        NotchController.current?.panel.resignKey()
                        prev?.activate()
                        UserDefaults.standard.set(old, forKey: AP.hideFromCapture)
                    }
                }
            }
        }
        // Debug: ONYX_SOUNDDUMP=<dir> writes every synthesized fun sound as a WAV and quits.
        if let dir = ProcessInfo.processInfo.environment["ONYX_SOUNDDUMP"] {
            for s in FunSound.allCases {
                let samples = Synth.samples(s)
                try? Synth.wav(samples).write(to: URL(fileURLWithPath: dir + "/\(s.rawValue).wav"))
            }
            exit(0)
        }
        // Debug: ONYX_NOTCHSOUNDTEST=<file> exercises the open/close sounds silently and logs what would play.
        if let path = ProcessInfo.processInfo.environment["ONYX_NOTCHSOUNDTEST"] {
            var log: [String] = []
            SoundBoard.testLog = { s, v in log.append("\(s.rawValue)@\(String(format: "%.1f", v))") }
            let d = UserDefaults.standard
            let keys = [Fun.enabled, Fun.goose, Fun.notchSounds, Fun.openSound, Fun.closeSound]
            let domain = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            let saved = keys.map { domain[$0] }      // only explicitly-set values (nil = was using the default)
            d.set(true, forKey: Fun.enabled); d.set(false, forKey: Fun.goose)
            let steps: [(String, () -> Void)] = [
                ("open", { self.notch.expand(tab: .home) }),
                ("open-again", { self.notch.expand(tab: .home) }),
                ("close", { self.notch.collapse() }),
                ("close-again", { self.notch.collapse() }),
                ("set goose/none", { d.set("goose", forKey: Fun.openSound); d.set("none", forKey: Fun.closeSound) }),
                ("open", { self.notch.expand(tab: .home) }),
                ("close", { self.notch.collapse() }),
                ("toggle off", { d.set(false, forKey: Fun.notchSounds) }),
                ("open", { self.notch.expand(tab: .home) }),
                ("close", { self.notch.collapse() }),
            ]
            NotchModel.shared.pinned = true
            for (i, st) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 0.4) {
                    let before = log.count
                    st.1()
                    log.append("-- \(st.0): \(log.count > before ? "played" : "silent")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(steps.count) * 0.4 + 0.3) {
                for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
                NotchModel.shared.pinned = false
                SoundBoard.testLog = nil
                try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // Debug: ONYX_SEARCHTEST=<file> writes the top settings-search hits for sample queries, then quits.
        if let path = ProcessInfo.processInfo.environment["ONYX_SEARCHTEST"] {
            let qs = ["goose", "volume", "brightness", "dark", "shortcut", "hotkey", "liquid glass", "bigger", "move left",
                      "chrome help", "zoom", "screenshot", "startup", "celcius", "trnsparent", "shut down", "hide", "fun", "xyzzy"]
            let out = qs.map { q in "\(q) → " + SettingsIndex.search(q).prefix(3).map { "\($0.title) [\($0.section.title)]" }.joined(separator: " | ") }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
        // Debug: ONYX_HOMETEST=<file> checks "go back to Home after being closed" (default 5 s).
        if let path = ProcessInfo.processInfo.environment["ONYX_HOMETEST"] {
            var log: [String] = []
            SoundBoard.testLog = { _, _ in }
            let n = self.notch!
            NotchModel.shared.pinned = true
            let at: [(Double, () -> Void)] = [
                (3.0, { n.expand(tab: .tools) }),
                (3.5, { n.collapse() }),
                (4.5, { log.append("before: expanded=\(NotchModel.shared.expanded)"); n.expand(tab: nil); log.append("reopened after 1s → \(NotchModel.shared.tab.rawValue)") }),
                (5.0, { n.collapse() }),
                (17.0, { log.append("before: expanded=\(NotchModel.shared.expanded) defaultTab=\(Prefs.string(AP.defaultTab)) homeAfterIdle=\(Prefs.bool(AP.homeAfterIdle)) secs=\(Prefs.double(AP.homeAfterSeconds))"); n.expand(tab: nil); log.append("reopened after 12s → \(NotchModel.shared.tab.rawValue)") }),
                (17.5, { n.collapse(); NotchModel.shared.pinned = false; SoundBoard.testLog = nil
                         try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }),
            ]
            for (t, f) in at { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        }
        // Debug: ONYX_BACKDROPTEST=<file> turns on Clear glass briefly and records what the sampler sees.
        if let path = ProcessInfo.processInfo.environment["ONYX_BACKDROPTEST"] {
            let d = UserDefaults.standard
            let old = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[AP.glassVariant]
            d.set("clear", forKey: AP.glassVariant)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let b = BackdropSampler.shared
                try? "enabled=\(BackdropSampler.enabled) luminance=\(String(format: "%.2f", b.lastLuminance)) isLight=\(b.isLight) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"
                    .write(toFile: path, atomically: true, encoding: .utf8)
                if let old { d.set(old, forKey: AP.glassVariant) } else { d.removeObject(forKey: AP.glassVariant) }
            }
        }
        // Debug: ONYX_EXTRASDUMP=<file> lists Control Center's menu bar items as Accessibility sees them.
        if let path = ProcessInfo.processInfo.environment["ONYX_EXTRASDUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var out: [String] = []
                for app in NSWorkspace.shared.runningApplications where ["com.apple.controlcenter", "com.apple.systemuiserver"].contains(app.bundleIdentifier ?? "") {
                    let ax = AXUIElementCreateApplication(app.processIdentifier)
                    var bar: CFTypeRef?
                    AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar)
                    var kids: CFTypeRef?
                    if let bar { AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) }
                    for k in (kids as? [AXUIElement]) ?? [] {
                        func attr(_ n: String) -> String { var v: CFTypeRef?; AXUIElementCopyAttributeValue(k, n as CFString, &v); return v.map { "\($0)" } ?? "-" }
                        out.append("\(app.bundleIdentifier!) | desc=\(attr("AXDescription")) | title=\(attr("AXTitle")) | id=\(attr("AXIdentifier")) | help=\(attr("AXHelp")) | value=\(attr("AXValue"))")
                    }
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // Debug: ONYX_FOCUSAPITEST=<file> checks whether the official Focus status API works for Onyx.
        if let path = ProcessInfo.processInfo.environment["ONYX_FOCUSAPITEST"] {
            INFocusStatusCenter.default.requestAuthorization { st in
                let f = INFocusStatusCenter.default.focusStatus.isFocused
                try? "auth=\(st.rawValue) isFocused=\(f.map { "\($0)" } ?? "nil")\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // Debug: ONYX_SETTINGSTEST=1 opens Settings at 3 s and closes it at 7 s.
        if ProcessInfo.processInfo.environment["ONYX_SETTINGSTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.openSettings() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { self.settingsWindow?.close() }
        }
        // Debug: ONYX_EXPANDPERF=<file> opens the notch under several styles and records main-thread frame gaps.
        if let path = ProcessInfo.processInfo.environment["ONYX_EXPANDPERF"] {
            ExpandPerf.run(notch: self.notch, path: path)
        }
        // Debug: ONYX_BIGTEST=<dir> checks flashcards, Canvas error handling, and the aquarium/cow boxes.
        if let dir = ProcessInfo.processInfo.environment["ONYX_BIGTEST"] {
            func write(_ name: String, _ s: String) { try? s.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
            Task { @MainActor in
                let sample = """
                Cell Biology
                Mitochondria: the powerhouse of the cell, makes ATP through cellular respiration.
                Ribosomes build proteins by reading mRNA.
                The nucleus stores DNA and controls the cell.
                Photosynthesis happens in chloroplasts and turns light, water and CO2 into glucose and oxygen.
                """
                do {
                    let cards = try await FlashcardMaker.make(from: sample)
                    write("raw.txt", FlashcardMaker.lastRaw)
                    write("cards.txt", "AI available: \(Assistant.shared.unavailableReason == nil)\n" + cards.map { "Q: \($0.q)\n   A: \($0.a)" }.joined(separator: "\n"))
                } catch { write("cards.txt", "error: \(error.localizedDescription)") }
                await CanvasService.shared.connect(url: "canvas.instructure.com", token: "not-a-real-token")
                write("canvas.txt", "status=\(CanvasService.shared.status ?? "nil") connected=\(CanvasService.shared.connected) savedBase=\(Prefs.string(CanvasService.baseKey))")
            }
            let d = UserDefaults.standard
            let oldCow = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[AP.musicCow]
            let oldHide = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[AP.hideFromCapture]
            let oldPanels = HomeLayout.shared.panels
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                d.set(true, forKey: AP.musicCow)
                d.set(false, forKey: AP.hideFromCapture)
                HomeLayout.shared.panels = ProcessInfo.processInfo.environment["ONYX_BIGTEST_THREE"] != nil ? [.aquarium, .music, .clock] : [.aquarium, .music]
                NotchModel.shared.pinned = true
                SoundBoard.testLog = { _, _ in }
                self.notch.expand(tab: .home)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", dir + "/aqua.png"]; try? p.run(); p.waitUntilExit()
                self.notch.collapse()
                NotchModel.shared.pinned = false; SoundBoard.testLog = nil
                HomeLayout.shared.panels = oldPanels
                if let oldCow { d.set(oldCow, forKey: AP.musicCow) } else { d.removeObject(forKey: AP.musicCow) }
                if let oldHide { d.set(oldHide, forKey: AP.hideFromCapture) } else { d.removeObject(forKey: AP.hideFromCapture) }
                write("done.txt", "ok")
            }
        }
        if let p = ProcessInfo.processInfo.environment["ONYX_AXDEBUG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let s = "trusted=\(MenuBarDodger.shared.trusted) enabled=\(MenuBarDodger.shared.enabled) edge=\(String(describing: MenuBarDodger.frontAppMenusRightEdge()))\n"
                try? s.write(toFile: p, atomically: true, encoding: .utf8)
            }
        }

        Shortcuts.reload()   // user-rebindable global shortcuts (Settings › Behavior › Shortcuts)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.notch.reposition()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") { showOnboarding() }
    }

    private func setupStatusItem() {
        guard Prefs.bool(AP.menuBarIcon) else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Open Notch", #selector(openNotch), .toggleNotch))
        let hide = item("Hide Notch", #selector(toggleHide), .toggleHide)
        menu.addItem(hide)
        hideItem = hide
        menu.addItem(.separator())
        menu.addItem(item("Circle to Search", #selector(circleSearch), .circleSearch))
        menu.addItem(item("Ask AI", #selector(askAI), .askAI))
        menu.addItem(item("Screenshot Region", #selector(captureRegion), .captureRegion))
        menu.addItem(item("Record Screen", #selector(toggleRecording), .toggleRecording))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Optimization…", action: #selector(openOptimization), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set Up Permissions…", action: #selector(showOnboarding), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Onyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Keep the "Hide Notch" checkmark and menu-bar icon in sync whenever the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem?.state = notch.userHidden ? .on : .off
        updateStatusIcon()
        // Show each item's current (possibly rebound) shortcut.
        for i in menu.items {
            guard let raw = i.representedObject as? String, let a = HotAction(rawValue: raw),
                  let base = menuTitles[raw] else { continue }
            var title = base
            if a == .toggleRecording && QuickCapture.shared.recording { title = "Stop Recording" }
            i.title = title + (Shortcuts.get(a).map { "  " + $0.display } ?? "")
        }
    }

    /// Menu item tied to a shortcut action; its base title is remembered so the shortcut can be re-appended.
    private var menuTitles: [String: String] = [:]
    private func item(_ title: String, _ sel: Selector, _ a: HotAction) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.representedObject = a.rawValue
        menuTitles[a.rawValue] = title
        return i
    }

    @objc func captureRegion() { QuickCapture.shared.screenshot(.region) }
    @objc func toggleRecording() { QuickCapture.shared.toggleRecording() }

    private func updateStatusIcon() {
        let name = notch?.userHidden == true ? "eye.slash" : "capsule.fill"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Onyx")
    }

    @objc func toggleHide() {
        notch.setHidden(!notch.userHidden)
        hideItem?.state = notch.userHidden ? .on : .off
        updateStatusIcon()
    }

    @objc func openNotch() { notch.setHidden(false); updateStatusIcon(); notch.expand(tab: .home) }
    @objc func circleSearch() { CircleToSearch.shared.begin() }
    @objc func askAI() { notch.expand(tab: .ai, focus: true) }

    @objc func openSettings() {
        notch.collapse()   // never let the high-level notch cover the Settings window
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Onyx Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 760, height: 580))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Optimization lives in its own window (opened from the notch header or the menu bar icon).
    @objc func openOptimization() {
        notch.collapse()
        if optimizeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Onyx Optimization"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentViewController = NSHostingController(rootView: OptimizeWindowView())
            w.setContentSize(NSSize(width: 720, height: 600))
            w.center()
            optimizeWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        optimizeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showOnboarding() {
        notch.collapse()
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in
                UserDefaults.standard.set(true, forKey: "didOnboard")
                self?.onboardingWindow?.close()
            })
            w.center()
            onboardingWindow = w
        }
        // Keep setup on top: Onyx has no Dock icon, and after macOS relaunches it (Screen Recording's
        // "Quit & Reopen") the window would otherwise open behind other apps with no way to reach it.
        onboardingWindow?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Onyx login item: \(error)") }
    }
}

// MARK: - Memory: trim caches when the notch is idle

final class MemoryTrimmer {
    static let shared = MemoryTrimmer()
    private var bag = Set<AnyCancellable>()

    func observe() {
        NotchModel.shared.$expanded
            .removeDuplicates()
            .debounce(for: .seconds(8), scheduler: RunLoop.main)
            .sink { expanded in if !expanded { Self.trim() } }
            .store(in: &bag)
    }

    /// Release decoded images and hand freed pages back to the OS while idle.
    static func trim() {
        ImageCache.shared.purge()
        Assistant.shared.releaseIfIdle()
        malloc_zone_pressure_relief(nil, 0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Hidden Edit menu so ⌘X/C/V/A/Z work in text fields (menu-bar apps have no menu bar of their own).
let mainMenu = NSMenu(), editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
app.run()

/// Frame-timing probe for the expand animation (debug only).
final class ExpandPerf: NSObject {
    static var shared: ExpandPerf?
    private var stamps: [CFTimeInterval] = []
    private var link: CADisplayLink?
    @objc func tick(_ l: CADisplayLink) { stamps.append(l.timestamp) }

    static func run(notch: NotchController, path: String) {
        let me = ExpandPerf(); shared = me
        let d = UserDefaults.standard
        let keys = [AP.style, AP.glassVariant, AP.clearBlur]
        let domain = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let saved = keys.map { domain[$0] }
        let cases: [(String, [String: Any])] = ProcessInfo.processInfo.environment["ONYX_EXPANDPERF_PANELS"] != nil ? [
            ("clock only", ["panels": [HomePanel.clock]]),
            ("music only", ["panels": [HomePanel.music]]),
            ("bluetooth only", ["panels": [HomePanel.bluetooth]]),
            ("music+bluetooth", ["panels": [HomePanel.music, .bluetooth]]),
        ] : [
            ("clear+blur", [AP.style: "glass", AP.glassVariant: "clear", AP.clearBlur: true]),
            ("clear", [AP.style: "glass", AP.glassVariant: "clear", AP.clearBlur: false]),
            ("regular glass", [AP.style: "glass", AP.glassVariant: "regular", AP.clearBlur: true]),
            ("solid", [AP.style: "solid", AP.glassVariant: "regular", AP.clearBlur: true]),
        ]
        let savedPanels = HomeLayout.shared.panels
        SoundBoard.testLog = { _, _ in }
        NotchModel.shared.pinned = true
        var out: [String] = []
        func step(_ i: Int) {
            guard i < cases.count else {
                for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
                NotchModel.shared.pinned = false; SoundBoard.testLog = nil; HomeLayout.shared.panels = savedPanels
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            for (k, v) in cases[i].1 { if k == "panels" { HomeLayout.shared.panels = v as! [HomePanel] } else { d.set(v, forKey: k) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                me.stamps = []
                me.link = NSScreen.main?.displayLink(target: me, selector: #selector(ExpandPerf.tick(_:)))
                me.link?.add(to: .main, forMode: .common)
                var t0 = 0.0, t1 = 0.0
                if ProcessInfo.processInfo.environment["ONYX_EXPANDPERF_PREGROW"] != nil { notch.prepareExpand() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { t0 = CACurrentMediaTime(); notch.expand(tab: .home); t1 = CACurrentMediaTime() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    me.link?.invalidate()
                    let gaps = zip(me.stamps.dropFirst(), me.stamps).map { ($0 - $1) * 1000 }
                    let longest = gaps.max() ?? 0, dropped = gaps.filter { $0 > 25 }.count
                    let gi = gaps.firstIndex(of: longest) ?? 0
                    let gapStart = (me.stamps[gi] - t0) * 1000
                    out.append(String(format: "   expand() call took %.1f ms; longest gap starts %.1f ms after expand began", (t1 - t0) * 1000, gapStart))
                    out.append(String(format: "%-14@ frames=%3d  longest gap=%5.1f ms  gaps>25ms=%d", cases[i].0 as NSString, me.stamps.count, longest, dropped))
                    notch.collapse()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step(i + 1) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { step(0) }
    }
}
