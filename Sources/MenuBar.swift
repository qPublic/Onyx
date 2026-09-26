import AppKit
import ApplicationServices

/// Reads the frontmost app's menu-bar extent via the Accessibility API so the notch can dodge it:
/// app menus (e.g. Chrome's Help) stay uncovered, while the notch keeps its place when there's room.
final class MenuBarDodger {
    static let shared = MenuBarDodger()

    /// Global (top-left origin) X where the frontmost app's menus end, or nil when dodging is off/untrusted.
    private(set) var rightEdge: CGFloat?
    private(set) var iconsEdge: CGFloat?   // only tracked on a screen with a built-in notch
    var onChange: (() -> Void)?
    private var timer: Timer?

    var enabled: Bool { Prefs.bool(AP.dodgeMenus) }
    var trusted: Bool { AXIsProcessTrusted() }

    /// Returns whether Accessibility is granted; pass prompt:true to show the system prompt if not.
    @discardableResult
    func ensureTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// At launch, show the system Accessibility banner if a feature that needs it is on but not granted.
    func promptIfNeeded() {
        guard (enabled || Prefs.bool(AP.interceptVolume)), !trusted else { return }
        ensureTrusted(prompt: true)
    }

    /// Explicit user action (Settings toggle / button): prompt, and if still not granted, open the pane.
    func requestAccess() {
        if ensureTrusted(prompt: true) { refresh(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !self.trusted { self.openAccessibilityPane() }
        }
    }

    func openAccessibilityPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        // Menus can change while an app is frontmost (e.g. Chrome adding menus), so re-check periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }.tolerant()
        refresh()
    }

    private let queue = DispatchQueue(label: "onyx.menubar", qos: .userInitiated)
    private var inFlight = false

    func refresh() {
        // Don't reposition mid-animation or while open (it only matters for the collapsed pill).
        if NotchModel.shared.animating || NotchModel.shared.expanded { return }
        // While Onyx's own Settings/onboarding is in front, stay where we were instead of recentering.
        if enabled, trusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        guard enabled && trusted else {
            if rightEdge != nil { rightEdge = nil; onChange?() }
            return
        }
        // Asking another app for its menus is an IPC round-trip; do it off the main thread.
        guard !inFlight else { return }
        inFlight = true
        let g = NotchModel.shared.geometry, notchScreen = g.hasNotch ? g.screenFrame : nil
        queue.async {
            let edge = Self.frontAppMenusRightEdge()
            let icons = notchScreen.flatMap { Self.statusItemsLeftEdge(in: $0) }
            DispatchQueue.main.async {
                self.inFlight = false
                if edge != self.rightEdge || icons != self.iconsEdge { self.rightEdge = edge; self.iconsEdge = icons; self.onChange?() }
            }
        }
    }

    /// Left edge of the status icons (battery, Wi-Fi, Control Center, third-party extras) on a screen.
    /// They're status-level windows along the top; no Accessibility needed to read their frames.
    static func statusItemsLeftEdge(in screen: NSRect) -> CGFloat? {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let xs = list.compactMap { w -> CGFloat? in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], y < 2, x >= screen.minX, x < screen.maxX,
                  x > screen.midX - 100 else { return nil }   // status icons live on the right half
            return x
        }
        return xs.min()
    }

    /// Right edge (global top-left X) of the last menu-bar item of the frontmost app, if readable.
    static func frontAppMenusRightEdge() -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var mbRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef) == .success,
              let menuBar = mbRef, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let items = childrenRef as? [AXUIElement], !items.isEmpty else { return nil }
        var maxRight: CGFloat = 0
        for item in items {
            var pRef: CFTypeRef?, sRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pRef) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sRef) == .success else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(pRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sRef as! AXValue, .cgSize, &size)
            maxRight = max(maxRight, pos.x + size.width)
        }
        return maxRight > 0 ? maxRight : nil
    }
}
