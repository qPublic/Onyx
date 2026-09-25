import AppKit
import SwiftUI
import Combine

// MARK: - Appearance & behavior preferences (all live-updating)

enum NotchStyle: String, CaseIterable, Identifiable {
    case solid, glass, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Liquid Glass"
        case .blur: "Frosted"
        }
    }
}

enum Placement: String, CaseIterable, Identifiable {
    case attached, floating
    var id: String { rawValue }
    var title: String { self == .attached ? "Attached to top" : "Floating island" }
}

enum AnimationStyle: String, CaseIterable, Identifiable {
    case bouncy, smooth, snappy, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OpenTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var title: String { self == .hover ? "Hover" : "Click" }
}

enum AP {
    static let style = "ap.style"
    static let glassVariant = "ap.glassVariant"
    static let styleCollapsed = "ap.styleCollapsed"
    static let bgColor = "ap.bgColor"
    static let tint = "ap.tint"
    static let tintStrength = "ap.tintStrength"
    static let accent = "ap.accent"
    static let expW = "ap.expW"
    static let expH = "ap.expH"
    static let collW = "ap.collW"
    static let collH = "ap.collH"
    static let earScale = "ap.earScale"
    static let placement = "ap.placement"
    static let topGap = "ap.topGap"
    static let hOffset = "ap.hOffset"
    static let display = "ap.display"
    static let radius = "ap.radius"
    static let collRadius = "ap.collRadius"
    static let shadow = "ap.shadow"
    static let border = "ap.border"
    static let animation = "ap.animation"
    static let openOn = "ap.openOn"
    static let closeOnLeave = "ap.closeOnLeave"
    static let closeDelay = "ap.closeDelay"
    static let haptics = "ap.haptics"
    static let hideFullscreen = "ap.hideFullscreen"
    static let hideIdle = "ap.hideIdle"
    static let userHidden = "ap.userHidden"
    static let dodgeMenus = "ap.dodgeMenus"
    static let interceptVolume = "ap.interceptVolume"
    static let hideFromCapture = "ap.hideFromCapture"
    static let hudPopup = "ap.hudPopup"
    static let bookshelf = "ap.bookshelf"
    static let shelfStays = "ap.shelfStays"
    static let snapLayouts = "ap.snapLayouts"
    static let clearBlur = "ap.clearBlur"
    static let clearDropBelow = "ap.clearDropBelow"
    static let musicCow = "ap.musicCow"
    static let cowBeat = "ap.cowBeat"
    static let tabs = "ap.tabs"
    static let defaultTab = "ap.defaultTab"
    static let homeAfterIdle = "ap.homeAfterIdle"
    static let homeAfterSeconds = "ap.homeAfterSeconds"
    static let menuBarIcon = "ap.menuBarIcon"
    static let collLeft = "ap.collLeft"
    static let collMid = "ap.collMid"
    static let collRight = "ap.collRight"

    static let defaults: [String: Any] = [
        style: NotchStyle.solid.rawValue,
        glassVariant: "regular",
        styleCollapsed: false,
        bgColor: "000000",
        tint: "000000",
        tintStrength: 0.25,
        accent: "FF5FA2",
        expW: 680.0,
        expH: 270.0,
        collW: 0.0,
        collH: 0.0,
        earScale: 1.0,
        placement: Placement.attached.rawValue,
        topGap: 8.0,
        hOffset: 0.0,
        display: "auto",
        radius: 26.0,
        collRadius: 10.0,
        shadow: 0.5,
        border: false,
        animation: AnimationStyle.bouncy.rawValue,
        openOn: OpenTrigger.hover.rawValue,
        closeOnLeave: true,
        closeDelay: 1.5,
        haptics: true,
        hideFullscreen: true,
        hideIdle: false,
        userHidden: false,
        dodgeMenus: true,
        interceptVolume: true,
        hideFromCapture: true,
        hudPopup: true,
        bookshelf: true,
        shelfStays: true,
        snapLayouts: true,
        clearBlur: true,
        clearDropBelow: false,
        musicCow: false,
        cowBeat: true,
        tabs: NotchTab.allCases.map(\.rawValue).joined(separator: ","),
        defaultTab: "last",
        homeAfterIdle: true,
        homeAfterSeconds: 5.0,
        menuBarIcon: true,
        collLeft: "battery",
        collMid: "",
        collRight: "weather",
    ]

    static func reset() { defaults.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    private static var d: UserDefaults { .standard }
    static var notchStyle: NotchStyle { NotchStyle(rawValue: Prefs.string(style)) ?? .solid }
    static var placementValue: Placement { Placement(rawValue: Prefs.string(placement)) ?? .attached }
    static var openTrigger: OpenTrigger { OpenTrigger(rawValue: Prefs.string(openOn)) ?? .hover }
    static var enabledTabs: [NotchTab] {
        var seen = Set<NotchTab>()
        let t = Prefs.list(tabs).compactMap(NotchTab.init(rawValue:)).filter { seen.insert($0).inserted }
        return t.isEmpty ? [.home] : t   // in the user's order
    }
    static func setTabs(_ t: [NotchTab]) { d.set(t.map(\.rawValue).joined(separator: ","), forKey: tabs) }
    static var accentColor: Color { Color(hex: Prefs.string(accent)) }
    /// Widgets shown in the collapsed notch's ears when idle (nil = nothing on that side).
    static var collapsedLeft: NotchWidget? { NotchWidget(rawValue: Prefs.string(collLeft)) }
    static var collapsedMid: NotchWidget? { NotchWidget(rawValue: Prefs.string(collMid)) }
    static var collapsedRight: NotchWidget? { NotchWidget(rawValue: Prefs.string(collRight)) }
    static var glass: Glass {
        if Prefs.string(glassVariant) == "clear" { return .clear }   // Apple's see-through glass: no tint, just edge lensing
        let base: Glass = .regular
        return base.tint(Color(hex: Prefs.string(tint)).opacity(d.double(forKey: tintStrength)))
    }

    static var animationValue: Animation? {
        switch AnimationStyle(rawValue: Prefs.string(animation)) ?? .bouncy {
        case .bouncy: .spring(response: 0.42, dampingFraction: 0.72)
        case .smooth: .spring(response: 0.5, dampingFraction: 1.0)
        case .snappy: .spring(response: 0.24, dampingFraction: 0.9)
        case .none: nil
        }
    }
}

/// Re-publishes whenever any preference changes so SwiftUI views refresh live.
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()
    private var c: AnyCancellable?
    init() {
        c = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

// MARK: - Color <-> hex

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Binding that stores a Color as a hex string in UserDefaults.
func hexColorBinding(_ key: String) -> Binding<Color> {
    Binding(get: { Color(hex: Prefs.string(key)) }, set: { UserDefaults.standard.set($0.hex, forKey: key) })
}

// MARK: - Behind-window blur for the "Frosted" style

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Hide while a fullscreen app is in front

final class FullscreenWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isFullscreen = false
    private var timer: Timer?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                // The fullscreen animation takes ~0.7s; check again once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.check() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.check() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }.tolerant()
    }

    func check() {
        if NotchModel.shared.animating { return }
        let fs = Prefs.bool(AP.hideFullscreen) && Self.frontAppIsFullscreen(on: NotchGeometry.targetScreen())
        if fs != isFullscreen { isFullscreen = fs; onChange?(fs) }
    }

    static func frontAppIsFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if axFullscreen(app.processIdentifier, on: screen) { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            // A maximized window leaves room for the menu bar; a fullscreen one covers the whole display.
            return (b["Width"] ?? 0) >= size.width && (b["Height"] ?? 0) >= size.height
        }
    }

    /// Native fullscreen, as the app itself reports it. (On notched Macs a fullscreen window stops
    /// below the notch, so it never covers the whole display and the size check alone misses it.)
    private static func axFullscreen(_ pid: pid_t, on screen: NSScreen) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let win,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return false }
        let w = win as! AXUIElement
        var fs: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs) == .success, (fs as? Bool) == true else { return false }
        // Only count it when that window is on the notch's screen (AX uses top-left global coordinates).
        guard let p = SnapController.position(w) else { return true }
        let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
        return screen.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: p.x + 1, y: primaryH - p.y - 1))
    }
}

// MARK: - Styled notch background (solid / Liquid Glass / frosted)

struct NotchBackground<S: Shape>: View {
    let shape: S
    let expanded: Bool
    @ObservedObject var appearance = AppearanceStore.shared

    var body: some View {
        let d = UserDefaults.standard
        let shadowAmt = d.double(forKey: AP.shadow)
        let fancy = expanded || d.bool(forKey: AP.styleCollapsed)
        let border = d.bool(forKey: AP.border)

        ZStack {
            if !fancy {
                shape.fill(Color.black)                    // blend with a real notch when idle
            } else {
                switch AP.notchStyle {
                case .solid:
                    shape.fill(Color(hex: Prefs.string(AP.bgColor)))
                case .glass:
                    glass(shape)
                case .blur:
                    VisualEffectBlur().clipShape(shape)
                        .overlay(shape.fill(Color(hex: Prefs.string(AP.tint)).opacity(d.double(forKey: AP.tintStrength))))
                }
            }
        }
        .overlay { if border { shape.stroke(.white.opacity(0.18), lineWidth: 1) } }
        .compositingGroup()
        .shadow(color: .black.opacity(expanded ? 0.55 * shadowAmt : 0),
                radius: expanded ? 24 * shadowAmt : 0, y: expanded ? 10 * shadowAmt : 0)
    }

    @ViewBuilder private func glass(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            ZStack {
                // Clear glass + "blur what's behind": soften text into colored blobs so it isn't distracting,
                // while the glass on top keeps its see-through look and edge lensing.
                if Prefs.string(AP.glassVariant) == "clear" && Prefs.bool(AP.clearBlur) {
                    shape.fill(.ultraThinMaterial)
                }
                Color.clear.glassEffect(AP.glass, in: shape)
            }
        } else {
            VisualEffectBlur().clipShape(shape)
        }
    }
}
