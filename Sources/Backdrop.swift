import AppKit
import SwiftUI
import ScreenCaptureKit

/// With Clear Liquid Glass the notch is see-through, so fixed white text can vanish over a light page.
/// This samples what's behind the notch (Onyx's own windows excluded) about once a second and says
/// whether the backdrop is light, so the notch can flip its text to black.
final class BackdropSampler: ObservableObject {
    static let shared = BackdropSampler()
    @Published private(set) var isLight = false
    private(set) var lastLuminance = -1.0
    private var timer: Timer?
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var busy = false

    /// Adaptive text is on whenever the notch uses Clear glass.
    static var enabled: Bool { AP.notchStyle == .glass && Prefs.string(AP.glassVariant) == "clear" }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard Self.enabled, !busy, !NotchModel.shared.animating, CGPreflightScreenCaptureAccess(),
              let panel = NotchController.current?.panel, panel.isVisible, let screen = panel.screen else {
            if !Self.enabled && isLight { isLight = false }
            return
        }
        let m = NotchModel.shared, g = m.geometry
        let size = m.expanded ? g.expandedSize : CGSize(width: g.notchWidth + 120, height: g.notchHeight)
        // ScreenCaptureKit wants display-local points with a top-left origin.
        let rect = CGRect(x: g.centerX - size.width / 2 - screen.frame.minX, y: g.topGap, width: size.width, height: size.height)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                if self.content == nil || Date().timeIntervalSince(self.contentAt) > 10 {
                    self.content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    self.contentAt = Date()
                }
                guard let content = self.content,
                      let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = rect
                cfg.width = 64
                cfg.height = max(8, Int(64 * rect.height / max(rect.width, 1)))
                cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let lum = Self.luminance(img)
                self.lastLuminance = lum
                // Hysteresis so it doesn't flicker on mid-grey backgrounds.
                let light = self.isLight ? lum > 0.5 : lum > 0.62
                if light != self.isLight { withAnimation(.easeInOut(duration: 0.3)) { self.isLight = light } }
            } catch {}
        }
    }

    static func luminance(_ img: CGImage) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }
}
