import AppKit
import SwiftUI

// MARK: - onyx:// links: every main action has one, so Shortcuts (and through it Siri and Spotlight) can run it

enum OnyxLinks {
    struct Action: Identifiable { let id: String; let title: String; let url: String; let icon: String }
    /// The actions offered in Settings › Behavior › Shortcuts & Siri, with a sensible example link each.
    static let actions: [Action] = [
        Action(id: "ask", title: "Ask Onyx AI", url: "onyx://ask", icon: "sparkles"),
        Action(id: "focus", title: "Start a 25-minute focus session", url: "onyx://focus?minutes=25", icon: "scope"),
        Action(id: "timer", title: "Start a 10-minute timer", url: "onyx://timer?minutes=10", icon: "timer"),
        Action(id: "briefing", title: "Brief me on my day", url: "onyx://briefing", icon: "sun.horizon.fill"),
        Action(id: "copytext", title: "Copy text from the screen", url: "onyx://copy-text", icon: "text.viewfinder"),
        Action(id: "clipboard", title: "Open clipboard history", url: "onyx://clipboard", icon: "doc.on.clipboard"),
        Action(id: "screenshot", title: "Take a screenshot", url: "onyx://screenshot", icon: "camera.viewfinder"),
        Action(id: "launcher", title: "Open the App Launcher", url: "onyx://launcher", icon: "square.grid.3x3.fill"),
        Action(id: "wallpaper", title: "Create a wallpaper with AI", url: "onyx://create-wallpaper", icon: "wand.and.sparkles"),
        Action(id: "dark", title: "Switch Dark Mode", url: "onyx://dark-mode", icon: "moon.fill"),
        Action(id: "awake", title: "Keep my Mac awake", url: "onyx://keep-awake", icon: "cup.and.saucer.fill"),
        Action(id: "workspace", title: "Open a workspace (edit the name)", url: "onyx://workspace?name=School", icon: "rectangle.3.group"),
    ]

    /// Runs an onyx:// link. Returns what it did (for tests); `dry` only says what it would do.
    @MainActor @discardableResult static func handle(_ url: URL, dry: Bool = false) -> String {
        guard url.scheme == "onyx" else { return "not an Onyx link" }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let what = (url.host ?? url.path).lowercased()
        let minutes = Double(q["minutes"] ?? "")
        func run(_ label: String, _ f: () -> Void) -> String { if !dry { f() }; return label }
        switch what {
        case "ask":
            let text = q["q"] ?? q["text"] ?? ""
            return run(text.isEmpty ? "open AI" : "ask \(text)") {
                NotchController.current?.expand(tab: .ai, focus: true)
                if !text.isEmpty { Assistant.shared.send(text) }
            }
        case "focus": return run("focus \(Int(minutes ?? 25))") { FocusSession.shared.begin(minutes: minutes ?? 25) }
        case "timer": return run("timer \(Int(minutes ?? 10))") { FocusTimer.shared.begin(minutes: minutes ?? 10) }
        case "briefing": return run("briefing") { NotchController.current?.expand(tab: .ai); Task { await Briefing.post() } }
        case "copy-text": return run("copy text") { TextGrabber.fromScreen() }
        case "clipboard": return run("clipboard") { ClipboardPicker.shared.open() }
        case "screenshot": return run("screenshot \(q["mode"] ?? "region")") { QuickCapture.shared.screenshot(q["mode"] == "screen" ? .screen : q["mode"] == "window" ? .window : .region) }
        case "launcher": return run("launcher") { AppLauncher.shared.open() }
        case "wallpapers": return run("wallpapers") { (NSApp.delegate as? AppDelegate)?.openWallpapers() }
        case "create-wallpaper":
            return run("create wallpaper \(q["idea"] ?? "")") {
                (NSApp.delegate as? AppDelegate)?.openWallpapers()
                if let idea = q["idea"], !idea.isEmpty { LoopMaker.shared.imagine(idea, art: ArtStyle(rawValue: UserDefaults.standard.string(forKey: "loop.art") ?? "") ?? .realistic) }
            }
        case "dark-mode": return run("dark mode") { QuickToggles.shared.toggleDark() }
        case "keep-awake":
            let hours = Double(q["hours"] ?? "")
            return run("keep awake") { Caffeinate.shared.active ? Caffeinate.shared.disable() : Caffeinate.shared.enable(hours: hours) }
        case "workspace":
            let name = q["name"] ?? ""
            guard let w = Workspaces.shared.list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return "no workspace \(name)" }
            return run("workspace \(w.name)") { Task { await Workspaces.shared.restore(w, hideOthers: false) } }
        case "settings": return run("settings") { (NSApp.delegate as? AppDelegate)?.openSettings() }
        case "whats-new": return run("what's new") { WhatsNew.show(force: true) }
        default: return "unknown link \(what)"
        }
    }

    /// A one-action shortcut ("Open URL: onyx://…") in Shortcuts' file format.
    static func shortcutFile(name: String, url: String) -> Data? {
        let plist: [String: Any] = [
            "WFWorkflowClientVersion": "2605.0.5", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowActions": [
                ["WFWorkflowActionIdentifier": "is.workflow.actions.url", "WFWorkflowActionParameters": ["WFURLActionURL": url]],
                ["WFWorkflowActionIdentifier": "is.workflow.actions.openurl", "WFWorkflowActionParameters": [:]],
            ],
            "WFWorkflowName": name,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// Makes the shortcut, has Shortcuts sign it (for your account), and opens it so Shortcuts asks to add it.
    /// If signing isn't possible, it copies the link and opens Shortcuts with directions instead.
    @MainActor static func addToShortcuts(_ a: Action) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-shortcuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "Onyx – " + a.title.replacingOccurrences(of: " (edit the name)", with: "")
        let raw = dir.appendingPathComponent("unsigned.shortcut"), signed = dir.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).shortcut")
        if let d = shortcutFile(name: name, url: a.url), (try? d.write(to: raw)) != nil {
            try? FileManager.default.removeItem(at: signed)
            let r = await Shell.read("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", raw.path, "--output", signed.path])
            if r.status == 0, FileManager.default.fileExists(atPath: signed.path) { NSWorkspace.shared.open(signed); return }
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.url, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Add it in Shortcuts"
        alert.informativeText = "The link \(a.url) is on your clipboard. In Shortcuts, make a new shortcut, add the \"Open URLs\" action and paste the link. Name it whatever you'll say to Siri."
        alert.addButton(withTitle: "Open Shortcuts"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
    }
}

/// Settings › Behavior › Shortcuts & Siri.
struct ShortcutsSettings: View {
    var body: some View {
        Text("Add any of these to the Shortcuts app with one click. Then run them with Siri (\"Hey Siri, Onyx focus\"), from Spotlight, or in your own automations. Each one is just an onyx:// link, which also works from anywhere links do.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(OnyxLinks.actions) { a in
            HStack {
                Label(a.title, systemImage: a.icon)
                Spacer()
                Text(a.url).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                Button("Add to Shortcuts") { Task { await OnyxLinks.addToShortcuts(a) } }.controlSize(.small)
            }
        }
        Text("In any app, select text and use right-click › Services › Ask Onyx AI or Summarize with Onyx, too.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Services menu: select text anywhere › Services › Ask Onyx AI / Summarize with Onyx

final class OnyxServices: NSObject {
    @objc func askAI(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { take(pboard, prompt: nil) }
    @objc func summarize(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { take(pboard, prompt: "Summarize this in a few sentences.") }

    private func take(_ pboard: NSPasteboard, prompt: String?) {
        guard let text = pboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            Assistant.shared.document = AIDocument(name: "Selected text", text: text, selection: true)
            NotchController.current?.expand(tab: .ai, focus: true)
            if let prompt { Assistant.shared.send(prompt) }
        }
    }
}

// MARK: - What's new: after an update, the new version's highlights (from the changelog bundled in the app)

enum WhatsNew {
    static let key = "whatsnew.seen"
    private static var window: NSWindow?

    /// The version's bullet points from CHANGELOG.md, as (title, detail) pairs.
    static func notes(for version: String) -> [(String, String)] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false, out: [(String, String)] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { if inSection { break }; inSection = line == "## \(version)"; continue }
            guard inSection, line.hasPrefix("- ") else { continue }
            var s = String(line.dropFirst(2))
            var title = ""
            if s.hasPrefix("**"), let end = s.range(of: "**", range: s.index(s.startIndex, offsetBy: 2)..<s.endIndex) {
                title = String(s[s.index(s.startIndex, offsetBy: 2)..<end.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                s = String(s[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            out.append((title, s.replacingOccurrences(of: "**", with: "")))
        }
        return out
    }

    /// Once per new version (not on a fresh install).
    @MainActor static func show(force: Bool = false) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let seen = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(v, forKey: key)
        guard force || (seen != nil && seen != v && UserDefaults.standard.bool(forKey: "didOnboard")) else { return }
        let items = notes(for: v)
        guard !items.isEmpty else { return }
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: WhatsNewView(version: v, items: items) { w.close() })
        w.center()
        window = w
        AutoClose.watch(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct WhatsNewView: View {
    let version: String
    let items: [(String, String)]
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 0) {
                    Text("What's new in Onyx \(version)").font(.system(size: 20, weight: .bold))
                    Text("Here's what changed since your last version.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        VStack(alignment: .leading, spacing: 2) {
                            if !it.0.isEmpty { Text(it.0).font(.system(size: 13, weight: .semibold)) }
                            Text(it.1).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Take the Tour") { close(); (NSApp.delegate as? AppDelegate)?.showTour() }
                Spacer()
                Button("Got it", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }
}

// MARK: - Feedback: crash reports macOS already keeps, and a pre-filled GitHub issue

enum Feedback {
    static let lastCrashKey = "feedback.lastCrash"

    /// macOS's newest crash report for Onyx (~/Library/Logs/DiagnosticReports), if any.
    static func latestCrash() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix("Onyx") && ["ips", "crash"].contains($0.pathExtension) }.max { date($0) < date($1) }
    }

    /// The useful part of a crash report: what went wrong and where (no file contents, no personal data beyond paths).
    static func summary(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let parts = text.components(separatedBy: "\n")
        guard parts.count > 1, let body = try? JSONSerialization.jsonObject(with: Data(parts.dropFirst().joined(separator: "\n").utf8)) as? [String: Any] else {
            return String(text.prefix(1500))
        }
        var s = ""
        if let ex = body["exception"] as? [String: Any] { s += "Exception: \(ex["type"] as? String ?? "?") \(ex["signal"] as? String ?? "")\n" }
        if let term = (body["termination"] as? [String: Any])?["indicator"] as? String { s += "Termination: \(term)\n" }
        if let t = body["faultingThread"] as? Int, let threads = body["threads"] as? [[String: Any]], t < threads.count,
           let frames = threads[t]["frames"] as? [[String: Any]] {
            let images = (body["usedImages"] as? [[String: Any]]) ?? []
            for f in frames.prefix(14) {
                let img = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                s += "  \(img)  \(f["symbol"] as? String ?? "0x" + String(f["imageOffset"] as? Int ?? 0, radix: 16))\n"
            }
        }
        return s
    }

    /// Opens a new GitHub issue with Onyx's version, macOS, the Mac model and the AI model in use (never keys), plus the
    /// latest crash if you want. You see it all before anything is posted.
    static func report(includeCrash: Bool) {
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.model", &model, &size, nil, 0)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var body = "**What happened?**\n\n\n**What did you expect?**\n\n\n---\nOnyx \(v) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(String(cString: model)) · AI: \(CloudAI.label)\n"
        if includeCrash, let c = latestCrash() { body += "\nLatest crash (\(c.lastPathComponent)):\n```\n\(summary(of: c).prefix(1800))```\n" }
        var comps = URLComponents(string: "https://github.com/qPublic/Onyx/issues/new")!
        comps.queryItems = [URLQueryItem(name: "title", value: includeCrash ? "Onyx quit unexpectedly" : ""), URLQueryItem(name: "body", value: body)]
        if let u = comps.url { NSWorkspace.shared.open(u) }
    }

    /// At launch: if Onyx crashed since last time, say so once in the notch.
    @MainActor static func checkForCrash() {
        guard let c = latestCrash() else { return }
        let stamp = c.lastPathComponent
        let last = UserDefaults.standard.string(forKey: lastCrashKey)
        UserDefaults.standard.set(stamp, forKey: lastCrashKey)
        guard last != nil, last != stamp else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            NotchModel.shared.flash(.message(icon: "exclamationmark.bubble.fill", text: "Onyx quit unexpectedly. Report it from the menu bar icon", tint: .orange), for: 6)
        }
    }
}

// MARK: - Reduce Motion (System Settings › Accessibility › Display)

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
