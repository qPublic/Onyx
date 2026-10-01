import AppKit
import SwiftUI
import NaturalLanguage
import Translation

// MARK: - Quick Translate: select text anywhere, press ⌃⌥L, and the translation shows under the notch. Apple's translation
// does it on this Mac (each language downloads once in System Settings); with a cloud model picked in Settings › Privacy ›
// AI, any language works. Like everything that reads what you've selected, it waits while a private window is open.

@MainActor final class QuickTranslate: ObservableObject {
    static let shared = QuickTranslate()
    static let targetKey = "translate.target"   // a language code, or "" for automatic
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt-BR", "Portuguese"),
        ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"), ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"),
        ("th", "Thai"), ("id", "Indonesian"),
    ]

    @Published private(set) var original = ""
    @Published private(set) var result: String?
    @Published private(set) var from = ""
    @Published private(set) var to = ""
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    private var panel: NSPanel?
    private var monitors: [Any] = []

    /// The shortcut: translates what's selected in the app in front.
    func run() async {
        guard let text = await SelectionGrabber.grab(), !text.isEmpty else {
            if !PrivateGuard.active {
                NotchModel.shared.flash(.message(icon: "character.bubble", text: "Select some text first, then press the shortcut", tint: .blue), for: 2.5)
            }
            return
        }
        await translate(text)
    }

    func translate(_ text: String) async {
        let text = String(text.prefix(5000))
        let rec = NLLanguageRecognizer(); rec.processString(text)
        let src = rec.dominantLanguage?.rawValue ?? "en", target = Self.target(for: src)
        original = text; result = nil; problem = nil; busy = true
        from = Self.name(src); to = Self.name(target)
        show()
        defer { busy = false }
        if let r = await Self.onDevice(text, from: src, to: target) { result = r; return }
        if CloudAI.active, let r = try? await CloudAI.complete(system: "You translate text. Reply with only the translation, nothing else.",
                                                               prompt: "Translate into \(to):\n\n\(text)", maxTokens: 1500) {
            result = r.trimmingCharacters(in: .whitespacesAndNewlines); return
        }
        problem = "\(from) to \(to) isn't downloaded on this Mac yet. Add both in System Settings › General › Language & Region › Translation Languages, or pick a cloud model in Onyx's Settings › Privacy › AI."
    }

    /// Automatic: into your Mac's language, or the other way if the text is already in it. A picked language: into that,
    /// or into your Mac's language if the text is already in the picked one.
    static func target(for src: String) -> String {
        let mine = Locale.current.language.languageCode?.identifier ?? "en"
        let chosen = Prefs.string(targetKey)
        let first = chosen.isEmpty ? mine : chosen
        if !same(src, first) { return first }
        let other = chosen.isEmpty ? (same(mine, "en") ? "es" : "en") : mine
        return same(src, other) ? (same(other, "en") ? "es" : "en") : other
    }
    static func same(_ a: String, _ b: String) -> Bool { a.prefix(2).lowercased() == b.prefix(2).lowercased() }
    static func name(_ code: String) -> String { Locale.current.localizedString(forIdentifier: code) ?? code }

    /// Apple's translation, only for languages already downloaded (it never asks to download them).
    static func onDevice(_ text: String, from: String, to: String) async -> String? {
        let s = Locale.Language(identifier: from), t = Locale.Language(identifier: to)
        guard await LanguageAvailability().status(from: s, to: t) == .installed else { return nil }
        if #available(macOS 26, *) { return try? await TranslationSession(installedSource: s, target: t).translate(text).targetText }
        return await TranslationHost.shared.translate(text, from: s, to: t)   // macOS 15
    }

    // MARK: The panel under the notch

    private func show() {
        let p = panel ?? make()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        p.setFrame(NSRect(x: screen.frame.midX - 230, y: top - 250 - 6, width: 460, height: 250), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.reduced ? 0.08 : 0.18; p.animator().alphaValue = 1 }
        guard monitors.isEmpty else { return }
        // A click anywhere else puts it away.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in MainActor.assumeIsolated { QuickTranslate.shared.close() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { e in
            MainActor.assumeIsolated { if e.window !== QuickTranslate.shared.panel { QuickTranslate.shared.close() } }
            return e
        }) { monitors.append(l) }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true
        p.isReleasedWhenClosed = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: QuickTranslateView(model: self).motionAware())
        panel = p
        return p
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = Motion.reduced ? 0.06 : 0.14; p.animator().alphaValue = 0 }) {
            Task { @MainActor in p.orderOut(nil) }
        }
    }

    /// Self-test pictures: shows a finished translation without asking anything.
    func preview(_ text: String, _ translated: String, from: String, to: String) { original = text; result = translated; self.from = from; self.to = to }

    func copy() {
        guard let r = result else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r, forType: .string)
        NotchModel.shared.flash(.message(icon: "doc.on.doc.fill", text: "Copied the translation", tint: .green), for: 1.5)
        close()
    }
}

struct QuickTranslateView: View {
    @ObservedObject var model: QuickTranslate
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble.fill").foregroundStyle(.blue)
                Text("\(model.from) → \(model.to)").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.result != nil { Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.small) }
                Button { model.close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.busy && model.result == nil { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Translating…").foregroundStyle(.secondary) } }
                    if let r = model.result { Text(r).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let p = model.problem {
                        Text(p).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Open Language & Region") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                            model.close()
                        }.controlSize(.small)
                    }
                    Text(model.original).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 460, height: 250)
        .onyxGlass(OnyxGlass.regular.tint(.black.opacity(0.45)), in: .rect(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}
