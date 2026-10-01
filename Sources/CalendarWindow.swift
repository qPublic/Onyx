import AppKit
import SwiftUI

// MARK: - The calendar window: the Home calendar box opens the whole calendar in a window of its own. Click somewhere
// else and it closes by itself after a while (Settings › Calendar & Mail sets how long, or never). Pinned, it stays
// open and on top.

@MainActor final class CalendarWindow: NSObject, NSWindowDelegate {
    static let shared = CalendarWindow()
    static let hideKey = "cal.windowHide"   // seconds after you click away: 0 right away, -1 never
    static var hideAfter: Int { testHideAfter ?? UserDefaults.standard.object(forKey: hideKey) as? Int ?? 5 }
    static var testHideAfter: Int?   // self-test: a delay without touching your setting
    static let pinKey = "cal.windowPinned"
    static var pinned: Bool { testPinned ?? Prefs.bool(pinKey) }
    static var testPinned: Bool?

    private(set) var window: NSWindow?
    private var hide: DispatchWorkItem?
    private var monitors: [Any] = []
    let state = State()
    private var turn = 0   // each open or close; a close that finishes after the window was opened again leaves it be

    /// Drives the calendar growing into place inside the window.
    final class State: ObservableObject { @Published var open = false }

    func setPinned(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.pinKey)
        applyPin()
    }
    func applyPin() {
        window?.level = Self.pinned ? .floating : .normal
        if Self.pinned { clickedInside() }
    }

    func show() {
        hide?.cancel(); hide = nil
        CalendarService.shared.select(Date())
        let w = window ?? make()
        applyPin()
        watchClicks()
        turn += 1
        if !w.isVisible || w.alphaValue < 1 {
            // Drops a little from the notch as it fades in, while the calendar grows into place. Reduce Motion: a quick fade.
            let rest = w.isVisible ? resting ?? w.frame : w.frame, still = Motion.reduced
            resting = rest
            if !w.isVisible { w.alphaValue = 0; if !still { w.setFrame(rest.offsetBy(dx: 0, dy: 14), display: false) } }
            state.open = false
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = still ? 0.12 : 0.3
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                w.animator().alphaValue = 1
                if !still { w.animator().setFrame(rest, display: true) }
            }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { state.open = true }
        } else {
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
    private var resting: NSRect?   // where the window sits when it isn't moving in or out

    func close() {
        hide?.cancel(); hide = nil
        stopWatching()
        guard let w = window, w.isVisible else { return }
        turn += 1
        let mine = turn, rest = w.frame, still = Motion.reduced
        resting = rest
        // Lifts back toward the notch as it fades out.
        withAnimation(.easeIn(duration: 0.16)) { state.open = false }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = still ? 0.1 : 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
            if !still { w.animator().setFrame(rest.offsetBy(dx: 0, dy: 10), display: false) }
        }) {
            Task { @MainActor in
                guard mine == CalendarWindow.shared.turn else { return }   // opened again meanwhile
                w.orderOut(nil); w.setFrame(rest, display: false); w.alphaValue = 1
                CalendarService.shared.select(Date())
            }
        }
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Calendar"
        w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true; w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.09, alpha: 1)
        w.minSize = NSSize(width: 560, height: 340)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        w.contentView = NSHostingView(rootView: CalendarWindowView(state: state))
        // Its first time: just under the menu bar, in the middle (where the notch is). After that, where you left it.
        if !w.setFrameUsingName("OnyxCalendarWindow"), let s = NSScreen.main {
            let v = s.visibleFrame
            w.setFrameOrigin(NSPoint(x: v.midX - w.frame.width / 2, y: v.maxY - w.frame.height - 8))
        }
        w.setFrameAutosaveName("OnyxCalendarWindow")
        window = w
        return w
    }

    // Any click: outside the window (another app, the notch, the desktop) starts the countdown; inside, it stays.
    private func watchClicks() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated { CalendarWindow.shared.clickedAway() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { e in
            let inside = e.window != nil && e.window === MainActor.assumeIsolated({ CalendarWindow.shared.window })
            MainActor.assumeIsolated { inside ? CalendarWindow.shared.clickedInside() : CalendarWindow.shared.clickedAway() }
            return e
        }) { monitors.append(l) }
    }
    private func stopWatching() { monitors.forEach(NSEvent.removeMonitor); monitors = [] }

    /// Clicked somewhere else: close after the time you picked (counted from the first click away).
    func clickedAway() {
        guard window?.isVisible == true, !Self.pinned, hide == nil else { return }
        let after = Self.hideAfter
        guard after >= 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.hide = nil; self?.close() }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(after), execute: w)
    }
    /// Back in the window before the time's up: it stays.
    func clickedInside() { hide?.cancel(); hide = nil }

    // Switching apps from the keyboard counts too.
    func windowDidResignKey(_ n: Notification) { clickedAway() }
    func windowDidBecomeKey(_ n: Notification) { clickedInside() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

struct CalendarWindowView: View {
    @ObservedObject var state: CalendarWindow.State
    var body: some View {
        FullCalendarView(onClose: { CalendarWindow.shared.close() })
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 30)   // the top clears the window's buttons
            .scaleEffect(state.open ? 1 : 0.96, anchor: .top)
            .opacity(state.open ? 1 : 0)
            .environment(\.colorScheme, .dark)
            .motionAware()
    }
}
