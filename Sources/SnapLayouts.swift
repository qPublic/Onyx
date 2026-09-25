import AppKit
import SwiftUI
import ApplicationServices

// MARK: - Snap layouts: drag a window to the notch, drop it on a zone (Windows 11 / Sapphire style)

struct SnapZone: Identifiable { let id: String; let rect: CGRect }   // unit rect, top-left origin
struct SnapLayout: Identifiable {
    let id: String
    let zones: [SnapZone]

    private static func z(_ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> SnapZone {
        SnapZone(id: id, rect: CGRect(x: x, y: y, width: w, height: h))
    }
    static let all: [SnapLayout] = [
        SnapLayout(id: "halves", zones: [z("l", 0, 0, 0.5, 1), z("r", 0.5, 0, 0.5, 1)]),
        SnapLayout(id: "topBottom", zones: [z("t", 0, 0, 1, 0.5), z("b", 0, 0.5, 1, 0.5)]),
        SnapLayout(id: "twoThirds", zones: [z("l", 0, 0, 2.0 / 3, 1), z("r", 2.0 / 3, 0, 1.0 / 3, 1)]),
        SnapLayout(id: "thirds", zones: [z("l", 0, 0, 1.0 / 3, 1), z("c", 1.0 / 3, 0, 1.0 / 3, 1), z("r", 2.0 / 3, 0, 1.0 / 3, 1)]),
        SnapLayout(id: "quarters", zones: [z("tl", 0, 0, 0.5, 0.5), z("tr", 0.5, 0, 0.5, 0.5), z("bl", 0, 0.5, 0.5, 0.5), z("br", 0.5, 0.5, 0.5, 0.5)]),
        SnapLayout(id: "mainSide", zones: [z("l", 0, 0, 0.5, 1), z("tr", 0.5, 0, 0.5, 0.5), z("br", 0.5, 0.5, 0.5, 0.5)]),
        SnapLayout(id: "full", zones: [z("f", 0, 0, 1, 1)]),
        SnapLayout(id: "center", zones: [z("c", 0.15, 0.1, 0.7, 0.8)]),
    ]
}

final class SnapModel: ObservableObject {
    @Published var visible = false
    @Published var hover: String?        // "layoutID/zoneID"
}

final class SnapController {
    static let shared = SnapController()
    let model = SnapModel()
    private var panel: NSPanel?
    private var preview: NSPanel?        // see-through outline of where the window will land
    private var monitors: [Any] = []
    private var candidate: AXUIElement?
    private var startPos: CGPoint?
    private var downPoint: CGPoint?      // where the mouse went down; the window lookup waits for a real drag
    private var dragging = false
    private var hideWork: DispatchWorkItem?

    static let tileW: CGFloat = 96, tileH: CGFloat = 60, spacing: CGFloat = 10, pad: CGFloat = 12, inset: CGFloat = 2

    private var enabled: Bool { Prefs.bool(AP.snapLayouts) && AXIsProcessTrusted() }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e.type) }) {
            monitors.append(g)
        }
    }

    // MARK: Drag tracking

    private func handle(_ type: NSEvent.EventType) {
        guard enabled else { return }
        let p = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            // No Accessibility calls on a plain click; only once the mouse actually drags.
            dragging = false; candidate = nil; startPos = nil
            downPoint = p
        case .leftMouseDragged:
            if let d = downPoint {
                downPoint = nil
                candidate = Self.window(at: d)
                startPos = candidate.flatMap(Self.position)
            }
            guard let w = candidate else { return }
            if !dragging {
                // It's a window drag once the window itself starts moving (not a text selection etc.).
                guard let s = startPos, let now = Self.position(w), hypot(now.x - s.x, now.y - s.y) > 2 else { return }
                dragging = true
            }
            if model.visible {
                updateHover(p)
                if !stayRect.contains(p) { hide() }
            } else if triggerRect.contains(p) {
                show()
            }
        case .leftMouseUp:
            if model.visible, let h = model.hover, let w = candidate { snap(w, to: h) }
            hide()
            candidate = nil; dragging = false; downPoint = nil
        default: break
        }
    }

    private var geometry: NotchGeometry? { NotchController.current?.model.geometry }

    /// Bring the dragged window up to the notch to open the picker.
    private var triggerRect: NSRect {
        guard let g = geometry else { return .zero }
        let w = g.notchWidth + 160
        return NSRect(x: g.centerX - w / 2, y: g.screenFrame.maxY - 44, width: w, height: 44)
    }

    /// Keep the picker open while the pointer is on it or on the way to it.
    private var stayRect: NSRect {
        let p = panel?.frame.insetBy(dx: -40, dy: -40) ?? .zero
        return p.union(triggerRect.insetBy(dx: -20, dy: 0))
    }

    private var panelSize: CGSize {
        let n = CGFloat(SnapLayout.all.count)
        return CGSize(width: Self.pad * 2 + n * Self.tileW + (n - 1) * Self.spacing, height: Self.pad * 2 + Self.tileH)
    }

    private func show() {
        guard let g = geometry else { return }
        hideWork?.cancel()
        let size = panelSize
        let x = min(max(g.centerX - size.width / 2, g.screenFrame.minX + 8), g.screenFrame.maxX - size.width - 8)
        let frame = NSRect(x: x, y: g.screenFrame.maxY - g.notchHeight - 10 - size.height, width: size.width, height: size.height)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
            p.ignoresMouseEvents = true             // we track the pointer ourselves during the drag
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SnapPickerView(model: model))
            panel = p
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { model.visible = true }
    }

    private func hide() {
        guard model.visible else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.visible = false; model.hover = nil }
        showPreview(nil)
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// Screen-space rect of one zone cell inside the picker (must match SnapPickerView's layout).
    private func zoneRect(layout i: Int, zone z: SnapZone) -> NSRect {
        guard let pf = panel?.frame else { return .zero }
        let tileX = Self.pad + CGFloat(i) * (Self.tileW + Self.spacing)
        let x = tileX + z.rect.minX * Self.tileW + Self.inset
        let y = Self.pad + z.rect.minY * Self.tileH + Self.inset
        let w = z.rect.width * Self.tileW - Self.inset * 2, h = z.rect.height * Self.tileH - Self.inset * 2
        return NSRect(x: pf.minX + x, y: pf.maxY - y - h, width: w, height: h)
    }

    private func updateHover(_ p: CGPoint) {
        var hit: String?
        outer: for (i, l) in SnapLayout.all.enumerated() {
            for z in l.zones where zoneRect(layout: i, zone: z).insetBy(dx: -2, dy: -2).contains(p) {
                hit = "\(l.id)/\(z.id)"; break outer
            }
        }
        if hit != model.hover {
            withAnimation(.easeOut(duration: 0.1)) { model.hover = hit }
            showPreview(hit.flatMap(targetRect))
        }
    }

    private func showPreview(_ r: CGRect?) {
        guard let r else { preview?.orderOut(nil); return }
        let frame = r.insetBy(dx: 6, dy: 6)
        if preview == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)   // under the picker
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SnapPreviewView())
            preview = p
        }
        guard let p = preview else { return }
        if p.isVisible {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; p.animator().setFrame(frame, display: true) }
        } else {
            p.setFrame(frame, display: true)
            p.orderFrontRegardless()
        }
    }

    // MARK: Snapping

    /// Where a zone ("layoutID/zoneID") puts the window, in screen coordinates.
    private func targetRect(_ key: String) -> CGRect? {
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count == 2, let l = SnapLayout.all.first(where: { $0.id == parts[0] }),
              let z = l.zones.first(where: { $0.id == parts[1] }), let g = geometry else { return nil }
        let screen = NSScreen.screens.first { $0.frame == g.screenFrame } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return CGRect(x: vf.minX + z.rect.minX * vf.width, y: vf.maxY - z.rect.maxY * vf.height,
                      width: z.rect.width * vf.width, height: z.rect.height * vf.height)
    }

    private func snap(_ w: AXUIElement, to key: String) {
        guard let r = targetRect(key) else { return }
        // Let the window server finish the drag first, then place it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Self.setFrame(w, r) }
    }

    // MARK: Accessibility helpers (AX uses top-left global coordinates)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func window(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(primaryHeight - p.y), &el) == .success,
              let el else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == (kAXWindowRole as String) { return el }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &win) == .success, let win,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        return (win as! AXUIElement)
    }

    static func position(_ w: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var origin = CGPoint(x: r.minX, y: primaryHeight - r.maxY)
        var size = r.size
        let pos = AXValueCreate(.cgPoint, &origin)!, sz = AXValueCreate(.cgSize, &size)!
        // position → size → position again: some apps clamp size against the old position.
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
    }
}

struct SnapPreviewView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AP.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AP.accentColor.opacity(0.8), lineWidth: 2))
            .background(VisualEffectBlur().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).opacity(0.5))
    }
}

struct SnapPickerView: View {
    @ObservedObject var model: SnapModel
    typealias C = SnapController

    var body: some View {
        HStack(spacing: C.spacing) {
            ForEach(SnapLayout.all) { l in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
                    ForEach(l.zones) { z in
                        let hot = model.hover == "\(l.id)/\(z.id)"
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(hot ? AP.accentColor : Color.white.opacity(0.24))
                            .frame(width: z.rect.width * C.tileW - C.inset * 2, height: z.rect.height * C.tileH - C.inset * 2)
                            .offset(x: z.rect.minX * C.tileW + C.inset, y: z.rect.minY * C.tileH + C.inset)
                    }
                }
                .frame(width: C.tileW, height: C.tileH)
            }
        }
        .padding(C.pad)
        .background(
            ZStack {
                VisualEffectBlur()
                Color.black.opacity(0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .scaleEffect(model.visible ? 1 : 0.92, anchor: .top)
        .opacity(model.visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }
}
