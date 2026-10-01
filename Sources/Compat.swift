import SwiftUI
import AppKit
import Translation

// MARK: - Onyx runs on macOS 15 and later. Liquid Glass is used where the Mac has it (macOS 26); before that, the
// same places get a frosted blur.

/// What this Mac can do, checked when Onyx runs: one app for macOS 15 and 26, Apple silicon and Intel.
enum OS {
    static var hasLiquidGlass: Bool { if #available(macOS 26, *), !pretendSequoia { true } else { false } }
    /// Self-test pictures only: draws the macOS 15 look on a newer Mac.
    static let pretendSequoia = ProcessInfo.processInfo.environment["ONYX_PRETEND_SEQUOIA"] != nil
    /// Apple's on-device AI needs macOS 26 on Apple silicon (Intel Macs never have it).
    static var mayHaveAppleAI: Bool {
        #if arch(arm64)
        if #available(macOS 26, *), !pretendSequoia { return true }
        #endif
        return false
    }
    static var appleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    /// Why Apple's on-device AI isn't here, in a few words, for settings and messages.
    static var noAppleAIReason: String { appleSilicon ? "needs macOS 26" : "needs an Apple silicon Mac" }
}

/// Half-precision numbers (what Core ML models often hand back), read by hand: Swift's Float16 doesn't exist on Intel Macs.
enum Half {
    static func toFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16, exp = UInt32((h >> 10) & 0x1F), frac = UInt32(h & 0x3FF)
        if exp == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | frac << 13) }   // infinity or NaN
        if exp == 0 { return (sign != 0 ? -1 : 1) * Float(frac) * 0x1p-24 }               // zero or subnormal
        return Float(bitPattern: sign | (exp + 112) << 23 | frac << 13)                    // 127 - 15 = 112
    }
}

/// Liquid Glass, described without needing macOS 26: `.regular`, `.clear`, `.tint(_:)` and `.interactive()`, like Apple's.
struct OnyxGlass {
    enum Kind { case regular, clear }
    var kind = Kind.regular, tint: Color?, isInteractive = false
    static let regular = OnyxGlass(), clear = OnyxGlass(kind: .clear)
    func tint(_ c: Color) -> OnyxGlass { var g = self; g.tint = c; return g }
    func interactive() -> OnyxGlass { var g = self; g.isInteractive = true; return g }

    @available(macOS 26, *) var glass: Glass {
        var g: Glass = kind == .clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        return isInteractive ? g.interactive() : g
    }
}

extension View {
    /// Liquid Glass on macOS 26; a frosted blur in the same shape before that.
    @ViewBuilder func onyxGlass<S: Shape>(_ g: OnyxGlass = .regular, in shape: S) -> some View {
        if #available(macOS 26, *), OS.hasLiquidGlass {
            glassEffect(g.glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(g.kind == .clear ? Material.ultraThin : Material.regular)
                    if let t = g.tint { shape.fill(t) }
                    shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
            }
        }
    }

    /// Glass buttons on macOS 26; ordinary bordered buttons before that.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *), OS.hasLiquidGlass {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups glass shapes so they blend (macOS 26); before that, just the content.
struct OnyxGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *), OS.hasLiquidGlass { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

// MARK: - Apple's Translation on macOS 15: its sessions only come from a SwiftUI view there, so a tiny invisible window
// hosts one. (On macOS 26 Onyx makes a session directly.)

@MainActor final class TranslationHost {
    static let shared = TranslationHost()
    private let model = Model()
    private var window: NSWindow?

    final class Model: ObservableObject {
        @Published var config: TranslationSession.Configuration?
        var job: (id: UUID, text: String, done: CheckedContinuation<String?, Never>)?
        func run(_ session: TranslationSession) async {
            guard let j = job else { return }
            let out = try? await session.translate(j.text).targetText
            finish(j.id, out)
        }
        func finish(_ id: UUID, _ out: String?) {
            guard let j = job, j.id == id else { return }   // already answered, or given up on
            job = nil
            j.done.resume(returning: out)
        }
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        var body: some View {
            Color.clear.frame(width: 1, height: 1)
                .translationTask(model.config) { session in await model.run(session) }
        }
    }

    /// One translation at a time; only for languages already downloaded (it never asks to download them).
    func translate(_ text: String, from: Locale.Language, to: Locale.Language) async -> String? {
        while model.job != nil { try? await Task.sleep(for: .milliseconds(50)) }
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: -100, y: -100, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.alphaValue = 0; w.ignoresMouseEvents = true; w.hasShadow = false; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HostView(model: model))
            w.orderFrontRegardless()
            window = w
        }
        let id = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [model] in model.finish(id, nil) }   // never wait forever
        return await withCheckedContinuation { c in
            model.job = (id, text, c)
            if model.config?.source == from && model.config?.target == to { model.config?.invalidate() }
            else { model.config = TranslationSession.Configuration(source: from, target: to) }
        }
    }
}
