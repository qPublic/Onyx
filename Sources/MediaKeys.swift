import AppKit
import CoreGraphics
import ApplicationServices

/// Intercepts the hardware volume keys so Onyx can change the volume itself, show its own HUD, and
/// swallow the key — hiding the built-in macOS volume slider. Needs Accessibility (event tap).
/// Volume only: brightness and other media keys are passed straight through.
final class MediaKeys {
    static let shared = MediaKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?

    var enabled: Bool { Prefs.bool(AP.interceptVolume) }

    func start() {
        refresh()
        // Pick up permission being granted (or the toggle changing) while running.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }.tolerant()
    }

    /// Install or remove the tap to match the current enabled + Accessibility state.
    func refresh() {
        if enabled && AXIsProcessTrusted() { install() } else { uninstall() }
        // Status for troubleshooting: ~/Library/Application Support/Onyx/status.txt
        let s = "trusted=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess()) volumeTap=\(tap != nil) menuEdge=\(MenuBarDodger.shared.rightEdge.map { "\(Int($0))" } ?? "nil") front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"
        try? s.write(to: Prefs.supportDir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED (media keys)
        let cb: CGEventTapCallBack = { _, type, event, _ in MediaKeys.shared.handle(type, event) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func uninstall() {
        guard tap != nil else { return }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
        // NX_KEYTYPE_SOUND_UP = 0, SOUND_DOWN = 1, MUTE = 7, BRIGHTNESS_UP = 2, BRIGHTNESS_DOWN = 3.
        // Brightness is only taken over when the built-in display's brightness is controllable;
        // every other media key is left alone.
        let volumeKey = keyCode == 0 || keyCode == 1 || keyCode == 7
        let brightnessKey = (keyCode == 2 || keyCode == 3) && Brightness.get() != nil
        guard volumeKey || brightnessKey else { return Unmanaged.passUnretained(event) }
        let down = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        if down {
            let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
            DispatchQueue.main.async { self.apply(keyCode, fine: fine) }
        }
        return nil   // consume: macOS never draws its own volume/brightness slider
    }

    private func apply(_ keyCode: Int, fine: Bool) {
        if keyCode == 2 || keyCode == 3 {
            // Snap to the same 1/16 (or 1/64 with ⇧⌥) steps macOS uses.
            let step: Float = fine ? 1.0 / 64 : 1.0 / 16
            let cur = Brightness.get() ?? 0.5
            let next = max(0, min(1, ((cur / step).rounded() + (keyCode == 2 ? 1 : -1)) * step))
            Brightness.set(next)
            NotchModel.shared.flash(.brightness(next), for: 1.8)
            return
        }
        let vm = VolumeMonitor.shared
        if keyCode == 7 { vm.setMute(!vm.muted()); return }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let next = (vm.volume() ?? 0) + (keyCode == 0 ? step : -step)
        if vm.muted() && next > 0 { vm.setMute(false) }
        vm.setVolume(next)
        // VolumeMonitor's CoreAudio listener flashes the Onyx HUD on the resulting change.
    }
}

/// Built-in display brightness via the DisplayServices framework (what the system brightness keys use).
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    /// The built-in panel (nil when the lid is closed or there isn't one).
    private static var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let d = display, let f = getFn else { return nil }
        var b: Float = 0
        return f(d, &b) == 0 ? b : nil
    }

    static func set(_ v: Float) {
        guard let d = display, let f = setFn else { return }
        _ = f(d, max(0, min(1, v)))
    }
}
