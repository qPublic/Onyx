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
    var updateItem: NSMenuItem?
    var settingsWindow: NSWindow?
    var optimizeWindow: NSWindow?
    var wallpapersWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var tourWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // Debug: ONYX_UPDATE_TEST=<file> checks GitHub now, logs the result and exits (ONYX_UPDATE_TEST_QUIT=1 quits
        // normally instead, so a downloaded update installs). Pair with ONYX_UPDATE_CURRENT and ONYX_UPDATE_DEST.
        if let path = ProcessInfo.processInfo.environment["ONYX_UPDATE_TEST"] {
            Updater.shared.check(user: true)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                switch Updater.shared.state {
                case .checking, .downloading: return
                case let s:
                    t.invalidate()
                    try? "\(s)\n".write(toFile: path, atomically: true, encoding: .utf8)
                    if ProcessInfo.processInfo.environment["ONYX_UPDATE_TEST_QUIT"] != nil { NSApp.terminate(nil) } else { exit(0) }
                }
            }
            return   // before any services start, so nothing else can ask for anything
        }
        // Debug: ONYX_IMAGINETEST=<dir> runs Create with AI's painting step for real (ONYX_IMAGINETEST_ART, default realistic)
        // and saves what it paints, before any services start.
        if let dir = ProcessInfo.processInfo.environment["ONYX_IMAGINETEST"] {
            let art = ArtStyle(rawValue: ProcessInfo.processInfo.environment["ONYX_IMAGINETEST_ART"] ?? "") ?? .realistic
            let m = LoopMaker.shared, start = Date()
            m.imagine(ProcessInfo.processInfo.environment["ONYX_IMAGINETEST_IDEA"] ?? "a misty alpine lake at dawn", art: art)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard !m.busy else { return }
                    t.invalidate()
                    for (i, img) in m.images.enumerated() {
                        if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/imagine-\(i).png") as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
                        }
                    }
                    let log = "step: \(m.step)\nimages: \(m.images.count)\nname: \(m.name)\neffects: \(m.effects.map(\.rawValue).sorted())\nscene: \(m.scene)\nsubject: \(m.subject)\ncheck: \(m.checkNote ?? "none")\nplan error: \(LoopMaker.planError ?? "none")\nseconds: \(Int(Date().timeIntervalSince(start)))\n"
                    try? log.write(toFile: dir + "/imagine.log", atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
            return
        }
        // Debug: ONYX_SCENESHOT=<dir> renders the GPU scenes to PNGs (see SceneShots), before any services start.
        if let dir = ProcessInfo.processInfo.environment["ONYX_SCENESHOT"] { SceneShots.run(dir) }
        // Debug: ONYX_LOOPTEST=<dir> builds an AI loop end to end (see LoopSelfTest), before any services start.
        if let dir = ProcessInfo.processInfo.environment["ONYX_LOOPTEST"] { Task { @MainActor in await LoopSelfTest.run(dir) }; return }
        // Debug: ONYX_SHEETSHOT=<png>:<create|pick|wallpapers> screenshots the Create with AI sheet (pick uses ONYX_SHEETSHOT_ART
        // as the painting) or the Live Wallpapers window, before any services start, then quits.
        if let spec = ProcessInfo.processInfo.environment["ONYX_SHEETSHOT"], let colon = spec.lastIndex(of: ":") {
            let path = String(spec[..<colon]), which = String(spec[spec.index(after: colon)...])
            var win: NSWindow?
            if which == "onboarding" {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
                w.contentView = NSHostingView(rootView: OnboardingView {})
                w.center(); w.makeKeyAndOrderFront(nil); win = w
            } else if which.hasPrefix("tour"), let n = Int(which.dropFirst(4)) {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
                w.contentView = NSHostingView(rootView: FeatureTour(step: .constant(n)).frame(width: 520, height: 470).background(Color(hex: "0B0B12")).environment(\.colorScheme, .dark))
                w.center(); w.makeKeyAndOrderFront(nil); win = w
            } else if which == "wallpapers" {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
                w.contentViewController = NSHostingController(rootView: WallpapersView()); w.setContentSize(NSSize(width: 960, height: 680))
                w.center(); w.makeKeyAndOrderFront(nil); win = w
            } else {
                if which == "pick", let art = ProcessInfo.processInfo.environment["ONYX_SHEETSHOT_ART"],
                   let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: art) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    let m = LoopMaker.shared
                    m.images = [img, img]; m.name = "Minecraft Sunset"; m.effects = [.petals, .stars]; m.step = .pick
                }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = NSHostingView(rootView: CreateLoopSheet {}); w.center(); w.makeKeyAndOrderFront(nil); win = w
            }
            NSApp.activate()
            win?.level = .floating; win?.orderFrontRegardless()   // above whatever's in front, just for the picture
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let f = win?.frame, let h = NSScreen.screens.first?.frame.maxY {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(h - f.maxY)),\(Int(f.width)),\(Int(f.height))", path]
                    try? p.run(); p.waitUntilExit()
                }
                exit(0)
            }
            return
        }
        // Debug: ONYX_SDTEST=<dir> runs the Stable Diffusion styles and a parallax loop (see SDSelfTest), before any services start.
        if let dir = ProcessInfo.processInfo.environment["ONYX_SDTEST"] { Task { @MainActor in await SDSelfTest.run(dir) }; return }
        // Debug: ONYX_AICHECKTEST=<file> asks Onyx AI a few questions and logs how it checks its answers (see AICheckTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_AICHECKTEST"] { Task { @MainActor in await AICheckTest.run(file) }; return }
        // Debug: ONYX_LAUNCHERPINTEST=<dir> checks pinned apps and the by-category view, with screenshots (see LauncherPinTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_LAUNCHERPINTEST"] { Task { @MainActor in await LauncherPinTest.run(dir) }; return }
        // Debug: ONYX_CLOUDTEST=<file> checks the cloud-model path against a stand-in server (see CloudTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_CLOUDTEST"] { Task { @MainActor in await CloudTest.run(file) }; return }
        // Debug: ONYX_MAILTEST=<file> checks email reading and events (see MailTest; ./test.sh runs it with a stand-in mail server).
        if let file = ProcessInfo.processInfo.environment["ONYX_MAILTEST"] { Task { @MainActor in await MailTest.run(file) }; return }
        // Debug: ONYX_SCHOOLTEST=<file> checks academy sign-up against a stand-in TeachMore (see SchoolTest; ./test.sh starts one).
        if let file = ProcessInfo.processInfo.environment["ONYX_SCHOOLTEST"] { Task { @MainActor in await SchoolTest.run(file) }; return }
        // Debug: ONYX_CALWINDOWTEST=<file> checks the calendar window closes after you click away (it shows a window briefly).
        if let file = ProcessInfo.processInfo.environment["ONYX_CALWINDOWTEST"] { Task { @MainActor in await CalendarWindowTest.run(file) }; return }
        // Debug: ONYX_AIPLUSTEST=<file> checks web answers, search, translation, lettering and picture versions (see AIPlusTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_AIPLUSTEST"] { Task { @MainActor in await AIPlusTest.run(file) }; return }
        // Debug: ONYX_SAFETYTEST=<file> and ONYX_ENERGYTEST=<file> (see SafetyTest and EnergyTest; ./test.sh runs them all).
        if let file = ProcessInfo.processInfo.environment["ONYX_SAFETYTEST"] { Task { @MainActor in await SafetyTest.run(file) }; return }
        if let file = ProcessInfo.processInfo.environment["ONYX_ENERGYTEST"] { EnergyTest.run(file); return }
        // Debug: ONYX_AIEVAL=<file> runs the 100-question AI test suite (ONYX_AIEVAL_QUICK=1: 20 of them) and writes the report.
        if let file = ProcessInfo.processInfo.environment["ONYX_AIEVAL"] {
            Task { @MainActor in
                let quick = ProcessInfo.processInfo.environment["ONYX_AIEVAL_QUICK"] != nil
                // ONYX_AIEVAL_AREAS="Math,Word problems" runs just those areas; ONYX_AIEVAL_TIMES=3 runs them that many times.
                let areas = ProcessInfo.processInfo.environment["ONYX_AIEVAL_AREAS"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let times = Int(ProcessInfo.processInfo.environment["ONYX_AIEVAL_TIMES"] ?? "") ?? 1
                var list = quick ? AIEval.quick : AIEval.cases
                if let areas { list = list.filter { areas.contains($0.area) } }
                list = Array(repeating: list, count: max(1, times)).flatMap { $0 }
                let r = await AIEval.run(list) { d, t in try? "running \(d)/\(t)".write(toFile: file, atomically: true, encoding: .utf8) }
                try? AIEval.report(r).write(toFile: file, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // Debug: ONYX_VIEWSHOT=<dir> renders the new panels offscreen to PNGs (see ViewShot).
        if let dir = ProcessInfo.processInfo.environment["ONYX_VIEWSHOT"] { ViewShot.run(dir); return }
        // Debug: ONYX_EXTRASTEST=<file> checks the launcher actions, file reading, OCR, briefing and more (see ExtrasTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_EXTRASTEST"] { Task { @MainActor in await ExtrasTest.run(file) }; return }
        // Debug: ONYX_TOURTEST=<file> plays the feature tour for 13 s (see TourTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_TOURTEST"] { TourTest.run(file); return }
        // Debug: ONYX_AUTOCLOSETEST=<file> checks a watched window closes once you've clicked away for the set time (see AutoCloseTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_AUTOCLOSETEST"] { AutoCloseTest.run(file); return }
        // Debug: ONYX_LOWBATTERYTEST=<file> checks Low Battery Mode against this Mac's battery (see LowBatteryTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_LOWBATTERYTEST"] { LowBatteryTest.run(file); return }
        // Debug: ONYX_SCENETEST=<dir> plays the GPU scenes on the desktop and measures them (see ScenePerfTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_SCENETEST"] { Task { @MainActor in await ScenePerfTest.run(dir) }; return }
        if Updater.shared.installPendingAtLaunch() { NSApp.terminate(nil); return }   // swap in a downloaded update, then reopen

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
        OnyxReminders.shared.start()            // AI-set reminders that ring in the notch
        MainActor.assumeIsolated { Briefing.watch() }   // the morning briefing
        MainActor.assumeIsolated { MailWatch.shared.start() }   // events from your email (once an account is added)
        MainActor.assumeIsolated { ProtonVPN.shared.start() }   // Proton VPN status (macOS tells Onyx when it changes)
        MainActor.assumeIsolated { LidAwake.shared.start() }    // Lid Awake: whether it's on, and the battery while it is
        PrivateGuard.shared.start()             // private or incognito windows: record and read nothing (always on)
        LinkedCalendars.shared.start()          // calendars pasted as a link, updated every 30 minutes
        MainActor.assumeIsolated { SchoolSignup.shared.start() }   // TeachMore academy sign-up (once it's set up)
        MeetingWatch.shared.start()             // video calls: countdown + Join in the notch
        Updater.shared.start()                  // new GitHub releases download in the background
        NotesSync.shared.start()                // optional two-way sync with Apple Notes
        EarbudsWatcher.shared.start()           // AirPods battery pops up when they connect
        RainWatch.shared.start()                // "Rain in ~15 min" heads-up
        Speaker.shared.start()                  // speaks Onyx AI's answers (Settings › Privacy › AI)
        SettingsSync.shared.start()             // optional: same settings on all your Macs (iCloud Drive)
        WallpaperEngine.shared.start()          // live wallpapers behind the desktop icons (when turned on)
        WeatherWallpaper.shared.start()         // …with the real weather drawn over them
        // Debug: ONYX_AI_TEST=1 runs rendered math problems through Onyx AI at every effort into ai-test.log, then quits.
        if ProcessInfo.processInfo.environment["ONYX_AI_TEST"] != nil {
            Task { @MainActor in try? await Task.sleep(for: .seconds(3)); await AISelfTest.run() }
        }
        // Debug: ONYX_FAKENOTCH=1 draws a pretend camera housing over the notch (see NotchGeometry.fakeNotch).
        // ONYX_NOTCHTEST=<dir> also screenshots the top of the screen closed, with an activity, and open, then quits.
        if NotchGeometry.fakeNotch {
            let g = NotchModel.shared.geometry, f = g.screenFrame
            let cam = NSPanel(contentRect: NSRect(x: f.midX - g.hardwareNotchWidth / 2, y: f.maxY - g.hardwareNotchHeight,
                                                  width: g.hardwareNotchWidth, height: g.hardwareNotchHeight),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            cam.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
            cam.backgroundColor = .clear; cam.isOpaque = false; cam.ignoresMouseEvents = true
            cam.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            cam.contentView = NSHostingView(rootView: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color.black).overlay(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).stroke(Color.red.opacity(0.8))))
            cam.orderFrontRegardless()
            objc_setAssociatedObject(self, "fakeCam", cam, .OBJC_ASSOCIATION_RETAIN)
        }
        if let dir = ProcessInfo.processInfo.environment["ONYX_NOTCHTEST"] {
            func shot(_ name: String) {
                let f = NotchModel.shared.geometry.screenFrame, w = 1000.0, r = "\(Int(f.midX - w / 2)),0,\(Int(w)),360"
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R", r, dir + "/" + name]; try? p.run(); p.waitUntilExit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shot("1-closed.png")
                NotchModel.shared.flash(.message(icon: "checkmark.seal.fill", text: "Updated to 1.5.1", tint: .green), for: 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shot("2-activity.png")
                    NotchModel.shared.flash(.volume(0.6, muted: false), for: 1.5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shot("3-volume.png")
                        NotchModel.shared.pinned = true
                        self.notch.expand(tab: .home)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shot("4-open.png"); NSApp.terminate(nil) }
                    }
                }
            }
        }
        // Debug: ONYX_NOTESYNC_SELFTEST=<file> checks the Apple Notes sync decisions offline, then quits.
        if let path = ProcessInfo.processInfo.environment["ONYX_NOTESYNC_SELFTEST"] { NotesSyncSelfTest.run(path); exit(0) }
        // Debug: ONYX_NOTESYNC_LIVETEST=<file> round-trips notes through a throwaway Apple Notes folder (see NotesSyncLiveTest).
        if let path = ProcessInfo.processInfo.environment["ONYX_NOTESYNC_LIVETEST"] { Task { @MainActor in await NotesSyncLiveTest.run(path) } }
        // Debug: ONYX_FEATURES_TEST=<dir> checks AirPods, rain, weather stations, voice and settings sync (see FeatureSelfTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_FEATURES_TEST"] {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await FeatureSelfTest.run(dir) }
        }
        // Debug: ONYX_WINDOWSHOT=<png>:<onboarding|wallpapers|launcher> opens that window, screenshots it, then quits.
        if let spec = ProcessInfo.processInfo.environment["ONYX_WINDOWSHOT"], let colon = spec.lastIndex(of: ":") {
            let path = String(spec[..<colon]), which = String(spec[spec.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var win: NSWindow?
                switch which {
                case "onboarding": self.showOnboarding(); win = self.onboardingWindow
                case "wallpapers": self.openWallpapers(); win = self.wallpapersWindow
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let f = win?.frame, let h = NSScreen.screens.first?.frame.maxY {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(h - f.maxY)),\(Int(f.width)),\(Int(f.height))", path]
                        try? p.run(); p.waitUntilExit()
                    }
                    exit(0)
                }
            }
        }
        // Debug: ONYX_ENHANCE_TEST=<dir> runs a generated clip through the AI video enhancer (see EnhanceSelfTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_ENHANCE_TEST"], #available(macOS 26, *) { Task.detached { await EnhanceSelfTest.run(dir) } }
        // Debug: ONYX_WALLTEST=<dir> checks live wallpapers and the app launcher (see WallpaperSelfTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_WALLTEST"] {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await WallpaperSelfTest.run(dir) }
        }
        // Debug: ONYX_SPOTLIGHTTEST=<dir> checks taking ⌘Space from Spotlight and giving it back (see SpotlightSelfTest).
        if let dir = ProcessInfo.processInfo.environment["ONYX_SPOTLIGHTTEST"] {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await SpotlightSelfTest.run(dir) }
        }
        // Debug: ONYX_LAUNCHERFOCUS=<file> checks you can type into the App Launcher's search right away (see LauncherFocusTest).
        if let file = ProcessInfo.processInfo.environment["ONYX_LAUNCHERFOCUS"] {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await LauncherFocusTest.run(file) }
        }
        // Debug: ONYX_REMINDER_TEST=1 sets a reminder 5 seconds out to exercise the ringing notch.
        if ProcessInfo.processInfo.environment["ONYX_REMINDER_TEST"] != nil {
            OnyxReminders.shared.add(title: "Test reminder from Onyx", due: Date().addingTimeInterval(5))
        }
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
                let g = NotchModel.shared.geometry
                let s = "trusted=\(MenuBarDodger.shared.trusted) enabled=\(MenuBarDodger.shared.enabled) edge=\(String(describing: MenuBarDodger.frontAppMenusRightEdge())) icons=\(String(describing: MenuBarDodger.statusItemsLeftEdge(in: g.screenFrame))) screen=\(g.screenFrame) centerX=\(g.centerX) notchWidth=\(g.notchWidth) height=\(g.notchHeight) hasNotch=\(g.hasNotch)\n"
                try? s.write(toFile: p, atomically: true, encoding: .utf8)
            }
        }

        Shortcuts.reload()   // user-rebindable global shortcuts (Settings › Behavior › Shortcuts)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.notch.reposition()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") { showOnboarding() }
        NSApp.servicesProvider = services   // right-click › Services › Ask Onyx AI / Summarize with Onyx
        NSUpdateDynamicServices()
        MainActor.assumeIsolated {
            Feedback.checkForCrash()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { WhatsNew.show() } }
        }
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
        menu.addItem(withTitle: "Live Wallpapers…", action: #selector(openWallpapers), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Take the Tour…", action: #selector(showTour), keyEquivalent: "").target = self
        menu.addItem(withTitle: "App Launcher", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set Up Permissions…", action: #selector(showOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What's New…", action: #selector(showWhatsNew), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Report a Problem…", action: #selector(reportProblem), keyEquivalent: "").target = self
        let upd = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        updateItem = upd
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Onyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Keep the "Hide Notch" checkmark and menu-bar icon in sync whenever the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem?.state = notch.userHidden ? .on : .off
        updateStatusIcon()
        if case .ready(let v) = Updater.shared.state { updateItem?.title = "Restart to Install Onyx \(v)" }
        else { updateItem?.title = "Check for Updates…" }
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
    private let services = OnyxServices()

    /// onyx:// links (from Shortcuts, Siri, Spotlight or anywhere).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for u in urls { OnyxLinks.handle(u) } }
    }

    @objc func showWhatsNew() { MainActor.assumeIsolated { WhatsNew.show(force: true) } }
    @objc func reportProblem() { Feedback.report(includeCrash: false) }

    @objc func checkForUpdates() {
        if case .ready = Updater.shared.state { Updater.shared.restartNow() } else { Updater.shared.check(user: true) }
    }
    func applicationWillTerminate(_ notification: Notification) { Updater.shared.installOnQuit() }
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
            w.contentViewController = NSHostingController(rootView: SettingsView().motionAware())
            w.setContentSize(NSSize(width: 760, height: 580))
            w.center()
            settingsWindow = w
            MainActor.assumeIsolated { AutoClose.watch(w) }
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
            MainActor.assumeIsolated { AutoClose.watch(w) }
        }
        NSApp.activate(ignoringOtherApps: true)
        optimizeWindow?.makeKeyAndOrderFront(nil)
    }

    /// Live Wallpapers gets its own window, like Optimization.
    @objc func openWallpapers() {
        notch.collapse()
        if wallpapersWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Live Wallpapers"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentViewController = NSHostingController(rootView: WallpapersView())
            w.setContentSize(NSSize(width: 960, height: 680))
            w.center()
            wallpapersWindow = w
            MainActor.assumeIsolated { AutoClose.watch(w) }
        }
        NSApp.activate(ignoringOtherApps: true)
        wallpapersWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openLauncher() { MainActor.assumeIsolated { AppLauncher.shared.toggle() } }

    /// The feature tour on its own, any time.
    @objc func showTour() {
        notch.collapse()
        tourWindow?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.contentViewController = NSHostingController(rootView: OnboardingView(done: { [weak self] in self?.tourWindow?.close() }, tourOnly: true))
        w.center()
        tourWindow = w
        MainActor.assumeIsolated { AutoClose.watch(w) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc func showOnboarding() {
        notch.collapse()
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
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
