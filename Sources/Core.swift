import AppKit
import SwiftUI
import Carbon.HIToolbox

extension Timer {
    /// Give background timers some slack so macOS can batch their wake-ups (saves battery).
    @discardableResult func tolerant(_ fraction: Double = 0.2) -> Timer { tolerance = timeInterval * fraction; return self }
}

// MARK: - Preferences

enum Prefs {
    static let volumeHUD = "volumeHUD"
    static let chargingActivity = "chargingActivity"
    static let musicActivity = "musicActivity"
    static let sportsActivity = "sportsActivity"
    static let tickerActivity = "tickerActivity"
    static let downloadActivity = "downloadActivity"
    static let downloadToShelf = "downloadToShelf"
    static let leagues = "leagues"
    static let favoriteTeams = "favoriteTeams"
    static let watchlist = "watchlist"
    static let weatherCity = "weatherCity"
    static let fahrenheit = "fahrenheit"
    static let eyeBreak = "eyeBreak"
    static let hoverDelay = "hoverDelay"
    static let notes = "notes"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            volumeHUD: true,
            chargingActivity: true,
            musicActivity: true,
            sportsActivity: true,
            tickerActivity: false,
            downloadActivity: true,
            downloadToShelf: true,
            leagues: "nfl,nba,mlb,nhl,epl",
            favoriteTeams: "",
            watchlist: "AAPL,NVDA,^GSPC,BTC-USD",
            weatherCity: "",
            fahrenheit: Locale.current.measurementSystem == .us,
            eyeBreak: false,
            hoverDelay: 0.12,
            notes: "",
        ].merging(AP.defaults) { a, _ in a }.merging(Fun.defaults) { a, _ in a })
    }

    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func double(_ k: String) -> Double { UserDefaults.standard.double(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func list(_ k: String) -> [String] {
        string(k).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

// MARK: - Global hotkeys (Carbon; no Accessibility permission needed)

final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(keyCode: Int, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        if !installed { install() }
        var mods: UInt32 = 0
        if modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mods |= UInt32(optionKey) }
        if modifiers.contains(.control) { mods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
        let id = nextID; nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), mods, EventHotKeyID(signature: OSType(0x4F4E5958), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    /// Drop every registered shortcut (used when the user rebinds them, and while recording a new one).
    func unregisterAll() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll(); handlers.removeAll()
    }

    private func install() {
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Notch model

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, ai, live, tools
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        case .ai: "sparkles"
        case .live: "sportscourt.fill"
        case .tools: "square.grid.2x2.fill"
        }
    }
    var title: String {
        switch self {
        case .home: "Home"
        case .shelf: "Shelf"
        case .ai: "AI"
        case .live: "Live"
        case .tools: "Tools"
        }
    }
}

enum HUDEvent: Equatable {
    case volume(Float, muted: Bool)
    case brightness(Float)
    case charging(Int, plugged: Bool)
    case lowBattery(Int)
    case message(icon: String, text: String, tint: Color)
    case eyeBreak(until: Date)
}

struct NotchGeometry: Equatable {
    var hasNotch = false
    var hardwareNotchWidth: CGFloat = 0
    var notchWidth: CGFloat = 190          // collapsed idle width (after user adjustment)
    var notchHeight: CGFloat = 32          // collapsed height
    var screenFrame: NSRect = .zero
    var expandedSize = CGSize(width: 680, height: 270)
    var floating = false
    var topGap: CGFloat = 0
    var centerX: CGFloat = 0               // screen coordinates
    var earScale: CGFloat = 1

    /// Full-size window, used only while expanded.
    var windowSize: CGSize {
        CGSize(width: max(expandedSize.width, notchWidth + 300 * earScale) + 80, height: topGap + expandedSize.height + 44)
    }
    /// Small window used while collapsed — just big enough for the widest live activity.
    /// Keeping it small saves backing-store memory and compositing work most of the time.
    var collapsedWindowSize: CGSize {
        // Extra height is room for the volume/brightness pop-out to drop down (transparent + click-through).
        CGSize(width: notchWidth + 2 * 124 * earScale + 24, height: topGap + notchHeight + 52)
    }
    /// The expanded header only needs a gap for the camera when the notch sits right over it.
    var avoidsCamera: Bool { hasNotch && !floating && abs(centerX - screenFrame.midX) < 2 && notchWidth >= hardwareNotchWidth - 1 }

    init() {}
    init(screen: NSScreen) {
        let d = UserDefaults.standard
        screenFrame = screen.frame
        let top = screen.safeAreaInsets.top
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        var baseW: CGFloat = 190, baseH: CGFloat
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            hardwareNotchWidth = screen.frame.width - l.width - r.width + 4
            baseW = hardwareNotchWidth
            baseH = top
        } else {
            baseH = menuBar > 10 ? max(menuBar - 1, 24) : 30
        }
        notchWidth = max(80, baseW + d.double(forKey: AP.collW))
        notchHeight = max(18, baseH + d.double(forKey: AP.collH))
        floating = AP.placementValue == .floating
        topGap = floating ? d.double(forKey: AP.topGap) : 0
        let w = min(max(d.double(forKey: AP.expW), 520), screen.frame.width - 20)
        expandedSize = CGSize(width: w, height: min(max(d.double(forKey: AP.expH), 220), screen.frame.height * 0.8))
        earScale = max(0.6, d.double(forKey: AP.earScale))
        let maxOff = max(0, screen.frame.width / 2 - w / 2 - 8)
        centerX = screen.frame.midX + min(max(d.double(forKey: AP.hOffset), -maxOff), maxOff)
    }

    /// With see-through (Clear) glass, the opened notch hangs just below the menu bar so menu text is
    /// never under the glass's lensing edge. The collapsed pill stays in the menu bar.
    static func menuBarLift(_ g: NotchGeometry, expanded: Bool) -> CGFloat {
        expanded && !g.floating && BackdropSampler.enabled && Prefs.bool(AP.clearDropBelow) ? g.notchHeight : 0
    }

    static func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        switch Prefs.string(AP.display) {
        case "", "auto": break
        case "primary": return screens[0]
        case "builtin":
            if let s = screens.first(where: {
                CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0) != 0
            }) { return s }
        case "mouse": return ScreenReader.screenUnderMouse()
        case let name: if let s = screens.first(where: { $0.localizedName == name }) { return s }
        }
        return screens.first { $0.safeAreaInsets.top > 0 } ?? screens[0]
    }
}

final class NotchModel: ObservableObject {
    static let shared = NotchModel()
    @Published var expanded = false
    @Published var tab: NotchTab = .home
    @Published var hud: HUDEvent?
    @Published var pinned = false
    @Published var geometry = NotchGeometry()
    @Published var focusRequest = 0
    /// When the notch last opened/closed; periodic background checks hold off briefly so they
    /// never land on the main thread in the middle of the animation.
    var lastToggle = Date.distantPast
    var animating: Bool { Date().timeIntervalSince(lastToggle) < 0.9 }
    private var hudWork: DispatchWorkItem?

    func flash(_ e: HUDEvent, for seconds: Double = 2.2) {
        hudWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { hud = e }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self?.hud = nil }
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

// MARK: - Window + hover/drag controller

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The notch is almost never the focused window, and macOS draws Liquid Glass lighter in unfocused
    // windows. Always report the "active" appearance so its color stays the same focused or not.
    // (AppKit-internal hooks; harmless no-ops if a future macOS stops calling them.)
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

final class NotchController {
    static weak var current: NotchController?
    let model = NotchModel.shared
    var panel: NotchPanel!
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var dragStartCount = 0

    init() { NotchController.current = self }

    func show() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NotchRootView().environmentObject(model))
        host.sizingOptions = []
        panel.contentView = host
        panel.ignoresMouseEvents = true
        reposition()
        panel.orderFrontRegardless()
        startWatchers()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e.type) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e.type); return e }) {
            monitors.append(l)
        }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53, self?.model.expanded == true { self?.collapse(); return nil }
            return e
        }) { monitors.append(k) }

        applyVisibility()   // respect a persisted manual-hide from a previous session
    }

    func reposition() {
        var g = NotchGeometry(screen: NotchGeometry.targetScreen())
        dodgeMenus(&g)
        if g != model.geometry { model.geometry = g }
        applyFrame(large: model.expanded, animated: true)
    }

    /// Shift the notch right so its collapsed pill never covers the frontmost app's menus.
    private func dodgeMenus(_ g: inout NotchGeometry) {
        guard MenuBarDodger.shared.enabled, let edge = MenuBarDodger.shared.rightEdge else { return }
        let ear = max(AP.collapsedLeft?.glanceWidth ?? 0, AP.collapsedRight?.glanceWidth ?? 0)
        let pillW = g.notchWidth + 2 * ear
        // Clear glass bends whatever sits just past its edge, so keep menu text well outside that lens zone.
        let gap: CGFloat = BackdropSampler.enabled && Prefs.bool(AP.styleCollapsed) ? 34 : 10
        if g.centerX - pillW / 2 < edge + gap {
            // Split the difference: center the notch in the free space between the app's menus
            // and the status icons (battery, Wi-Fi, …).
            let right = MenuBarDodger.statusItemsLeftEdge(in: g.screenFrame) ?? g.screenFrame.maxX
            let mid = (edge + right) / 2
            g.centerX = min(max(mid, g.screenFrame.minX + pillW / 2 + 8), g.screenFrame.maxX - pillW / 2 - 8)
        }
    }

    private var shrinkWork: DispatchWorkItem?

    private func applyFrame(large: Bool, animated: Bool = false) {
        let g = model.geometry
        let s = large ? g.windowSize : g.collapsedWindowSize
        let r = NSRect(x: (g.centerX - s.width / 2).rounded(), y: (g.screenFrame.maxY - s.height).rounded(),
                       width: s.width.rounded(), height: s.height.rounded())
        guard panel.frame != r else { return }
        if let p = ProcessInfo.processInfo.environment["ONYX_FRAMELOG"] {
            let line = "\(Date().timeIntervalSince1970) animated=\(animated) visible=\(panel.isVisible) sameSize=\(panel.frame.size == r.size) sameY=\(panel.frame.minY == r.minY) from=\(Int(panel.frame.minX)) to=\(Int(r.minX)) active=\(NSApp.isActive)\n"
            if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() } else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
        }
        // Glide when it's only sliding sideways on the same screen (e.g. dodging a new app's menus);
        // growing/shrinking for expand/collapse stays instant so SwiftUI drives that animation.
        // Compare with a little tolerance: macOS snaps window frames to whole pixels.
        let f = panel.frame
        if animated, panel.isVisible, abs(f.width - r.width) < 2, abs(f.height - r.height) < 2, abs(f.minY - r.minY) < 2,
           abs(panel.frame.minX - r.minX) < g.screenFrame.width {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.35, 1.0)   // smooth ease-out
                panel.animator().setFrame(r, display: true)
            }
        } else {
            panel.setFrame(r, display: false)
        }
    }

    private var collapsedHitRect: NSRect {
        let g = model.geometry, f = g.screenFrame
        let w = g.notchWidth + 150 * g.earScale, h = g.notchHeight + g.topGap + 8
        return NSRect(x: g.centerX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private var expandedRect: NSRect {
        let g = model.geometry, f = g.screenFrame, s = g.expandedSize
        let lift = NotchGeometry.menuBarLift(g, expanded: true)   // includes the strip it hangs below
        return NSRect(x: g.centerX - s.width / 2, y: f.maxY - s.height - g.topGap - lift, width: s.width, height: s.height + g.topGap + lift)
    }

    /// It stays open only while you're actively working in it: pinned, typing (panel is key),
    /// one of its menus is open, or you're editing widgets/home. Otherwise it closes after the
    /// close delay once the pointer leaves. (Clicking another app never dismisses it directly.)
    private var sticky: Bool {
        model.pinned || WidgetLayout.shared.editing || HomeLayout.shared.editing
            || (model.tab == .ai && (panel?.isKeyWindow ?? false)) || model.tab == .shelf || menuTracking || !Prefs.bool(AP.closeOnLeave)
    }

    /// Switching to another app is a stronger "I'm done" signal than the pointer leaving, so it
    /// collapses even while typing (panel key) or with close-on-leave off — but never mid-interaction.
    private var appSwitchSticky: Bool {
        model.pinned || WidgetLayout.shared.editing || HomeLayout.shared.editing || menuTracking
    }

    private func handle(_ type: NSEvent.EventType) {
        guard !userHidden, !hiddenForFullscreen else { return }
        let p = NSEvent.mouseLocation
        if !model.expanded && Prefs.string(AP.display) == "mouse" && !NSMouseInRect(p, model.geometry.screenFrame, false) {
            reposition()
        }
        if type == .leftMouseDown {
            dragStartCount = NSPasteboard(name: .drag).changeCount
            if !model.expanded {
                // A click on the collapsed notch always reopens it (whatever the open-trigger setting),
                // so it's never "stuck" needing the menu bar.
                if collapsedHitRect.contains(p) { expand(tab: nil) }
            } else if !expandedRect.insetBy(dx: -8, dy: -8).contains(p) && !appSwitchSticky {
                // A click anywhere outside the open notch — including its own Settings window, which the
                // notch would otherwise cover — closes it immediately. Its ⋯ menu / editing / pinned keep it up.
                collapse()
            }
            return
        }
        if model.expanded {
            if expandedRect.insetBy(dx: -24, dy: -24).contains(p) {
                collapseWork?.cancel(); collapseWork = nil
            } else if !sticky && collapseWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.model.expanded, !self.sticky else { return }
                    // Re-check: don't close if the pointer came back over the panel.
                    if !self.expandedRect.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { self.collapse() }
                }
                collapseWork = w
                let delay = max(0, UserDefaults.standard.double(forKey: AP.closeDelay))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            }
        } else if collapsedHitRect.contains(p) {
            if type == .leftMouseDragged {
                if NSPasteboard(name: .drag).changeCount != dragStartCount { expand(tab: .shelf) }
            } else if AP.openTrigger == .hover && hoverWork == nil {
                prepareExpand()   // use the hover delay to get the bigger window ready
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverWork = nil
                    if self.collapsedHitRect.contains(NSEvent.mouseLocation) { self.expand(tab: nil) }
                }
                hoverWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + UserDefaults.standard.double(forKey: Prefs.hoverDelay), execute: w)
            }
        } else {
            hoverWork?.cancel(); hoverWork = nil
        }
    }

    /// Grow the (transparent, click-through) window ahead of opening, so macOS allocates the bigger
    /// window surface before the animation starts instead of during its first frames.
    func prepareExpand() {
        guard !model.expanded else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        applyFrame(large: true)
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.applyFrame(large: false)   // hover didn't turn into an open; give the memory back
        }
        shrinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func expand(tab: NotchTab?, focus: Bool = false) {
        collapseWork?.cancel(); collapseWork = nil
        let enabled = AP.enabledTabs
        if let tab { model.tab = tab }
        else if !model.expanded, let def = NotchTab(rawValue: Prefs.string(AP.defaultTab)) { model.tab = def }
        else if !model.expanded, Prefs.bool(AP.homeAfterIdle),
                Date().timeIntervalSince(lastClosed) >= Prefs.double(AP.homeAfterSeconds) { model.tab = .home }   // "Last used" + been away a while
        if !enabled.contains(model.tab) && tab == nil { model.tab = enabled[0] }
        shrinkWork?.cancel(); shrinkWork = nil
        applyFrame(large: true)   // grow first (invisible — the window is transparent), then animate
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()   // never leave it behind another window
        if !model.expanded && Prefs.bool(AP.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if !model.expanded { SoundBoard.notch(opening: true) }   // only on a real open, not tab switches
        model.lastToggle = Date()
        withAnimation(AP.animationValue) { model.expanded = true }
        // Poll the pointer while open: global mouse-moved events don't fire reliably over the menu
        // bar / top edge, so without this the notch wouldn't auto-close when you leave it upward.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.handle(.mouseMoved) }
        }
        if focus || model.tab == .ai {
            panel.makeKey()
            model.focusRequest += 1
        }
    }

    private var lastClosed = Date.distantPast

    func collapse() {
        if model.expanded { SoundBoard.notch(opening: false); lastClosed = Date() }   // not when "closing" an already-closed notch
        collapseWork?.cancel(); collapseWork = nil
        pollTimer?.invalidate(); pollTimer = nil
        panel.ignoresMouseEvents = true
        WidgetLayout.shared.editing = false
        HomeLayout.shared.editing = false
        model.lastToggle = Date()
        withAnimation(AP.animationValue) { model.expanded = false }
        if panel.isKeyWindow { panel.resignKey() }
        // Shrink the window once the collapse animation has finished.
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.applyFrame(large: false)
        }
        shrinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: Manual hide (for tests, presentations, etc.)

    /// User-toggled "hide the notch entirely" — persists across launches and hotkey/menu/Settings.
    var userHidden: Bool { Prefs.bool(AP.userHidden) }

    func setHidden(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: AP.userHidden)
        applyVisibility()
    }

    /// Show or fully order-out the panel based on the manual-hide and fullscreen states.
    func applyVisibility() {
        // Excluded from screenshots, recordings and screen shares when enabled; still visible on screen.
        panel.sharingType = Prefs.bool(AP.hideFromCapture) ? .none : .readOnly
        if userHidden {
            hoverWork?.cancel(); hoverWork = nil
            collapseWork?.cancel(); collapseWork = nil
            if model.expanded { collapse() }
            panel.orderOut(nil)
        } else if !hiddenForFullscreen {
            panel.orderFrontRegardless()
        }
    }

    // MARK: Live settings + fullscreen

    private var hiddenForFullscreen = false
    private var menuTracking = false
    private let fullscreen = FullscreenWatcher()
    private var prefsObserver: Any?
    private var repositionWork: DispatchWorkItem?

    func startWatchers() {
        // Keep the panel open while any of its menus (⋯, Add widget, …) are open.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true
            self?.collapseWork?.cancel(); self?.collapseWork = nil
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false
        }
        // Collapse the expanded notch the moment you switch to another app (its own Settings/menu don't count).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.model.expanded, !self.appSwitchSticky else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            self.collapse()
        }
        fullscreen.onChange = { [weak self] fs in
            guard let self else { return }
            self.hiddenForFullscreen = fs
            if fs { if self.model.expanded { self.collapse() }; self.panel.orderOut(nil) }
            else if !self.userHidden { self.panel.orderFrontRegardless() }
        }
        fullscreen.start()
        MenuBarDodger.shared.onChange = { [weak self] in self?.reposition() }
        MenuBarDodger.shared.start()
        prefsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.repositionWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MenuBarDodger.shared.refresh(); self?.reposition(); self?.fullscreen.check(); self?.applyVisibility() }
            self.repositionWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
        }
    }
}
