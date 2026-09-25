import AppKit
import SwiftUI
import FoundationModels
import ScreenCaptureKit
import Vision

// MARK: - Screen capture + OCR

enum ScreenReader {
    static func screenUnderMouse() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Captures the display under the mouse, excluding Onyx's own windows.
    static func capture(screen: NSScreen = screenUnderMouse()) async throws -> CGImage {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw NSError(domain: "Onyx", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Onyx needs Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Onyx", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
        cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func ocr(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func labels(_ img: CGImage) -> [String] {
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.25 }.prefix(3)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    static func screenText() async throws -> String {
        let img = try await capture()
        return await Task.detached { ocr(img) }.value
    }
}

// MARK: - Agent tools (dynamic schemas — no macros needed)

struct AgentTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let params: [(name: String, info: String, optional: Bool)]
    /// The tool only runs if the user's message mentions one of these (the small on-device model
    /// sometimes calls tools nobody asked for, like making up a calendar event for a math question).
    var requires: [String] = []
    let run: @Sendable (GeneratedContent) async throws -> String

    var parameters: GenerationSchema {
        let props = params.map {
            DynamicGenerationSchema.Property(name: $0.name, description: $0.info,
                                             schema: DynamicGenerationSchema(type: String.self), isOptional: $0.optional)
        }
        return try! GenerationSchema(root: DynamicGenerationSchema(name: name + "_args", properties: props), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let request = Assistant.currentRequest.lowercased()
        if !requires.isEmpty && !requires.contains(where: request.contains) {
            return "Not done: the user didn't ask for this. Don't use tools for this message; answer it directly in words."
        }
        let out = try await run(arguments)
        await MainActor.run { Assistant.shared.log(tool: name, result: out) }
        return out
    }
}

private func arg(_ a: GeneratedContent, _ k: String) -> String? {
    guard let s = try? a.value(String.self, forProperty: k) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func parseDate(_ s: String) -> Date? {
    for f in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
        let df = DateFormatter(); df.dateFormat = f
        if let d = df.date(from: s) { return d }
    }
    let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    return det?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
}

private func findApp(_ name: String) -> URL? {
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
    let target = name.lowercased().replacingOccurrences(of: ".app", with: "")
    for d in dirs {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
        if let hit = items.first(where: { $0.lowercased() == target + ".app" })
            ?? items.first(where: { $0.lowercased().hasPrefix(target) && $0.hasSuffix(".app") }) {
            return URL(fileURLWithPath: d).appendingPathComponent(hit)
        }
    }
    return nil
}

enum AgentTools {
    static var all: [AgentTool] {
        [
            AgentTool(name: "open_app", description: "Launch or switch to a Mac app by name", params: [("name", "App name, e.g. Safari", false)], requires: ["open", "launch", "start", "switch to"]) { a in
                guard let n = arg(a, "name") else { return "Missing app name" }
                guard let u = findApp(n) else { return "Couldn't find an app named \(n)" }
                await MainActor.run { NSWorkspace.shared.openApplication(at: u, configuration: .init()) }
                return "Opened \(u.deletingPathExtension().lastPathComponent)"
            },
            AgentTool(name: "open_url", description: "Open a website in the default browser", params: [("url", "Full URL", false)], requires: ["open", "go to", "website", "site", "http", ".com", "visit", "link"]) { a in
                guard var s = arg(a, "url") else { return "Missing URL" }
                if !s.contains("://") { s = "https://" + s }
                guard let u = URL(string: s) else { return "Invalid URL" }
                await MainActor.run { _ = NSWorkspace.shared.open(u) }
                return "Opened \(s)"
            },
            AgentTool(name: "web_search", description: "Search the web in the browser", params: [("query", "Search terms", false)], requires: ["search", "google", "look up", "lookup", "web", "online"]) { a in
                guard let q = arg(a, "query"),
                      let u = URL(string: "https://www.google.com/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q))
                else { return "Missing query" }
                await MainActor.run { _ = NSWorkspace.shared.open(u) }
                return "Searched the web for \(q)"
            },
            AgentTool(name: "find_files", description: "Find files in the user's home folder by name; returns paths", params: [("query", "Part of the file name", false)], requires: ["file", "folder", "find", "document", "where is", "locate"]) { a in
                guard let q = arg(a, "query") else { return "Missing query" }
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", NSHomeDirectory(), "-name", q]
                p.standardOutput = pipe
                try p.run(); p.waitUntilExit()
                let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").filter { !$0.contains("/Library/") }.prefix(8)
                return lines.isEmpty ? "No files found for \(q)" : lines.joined(separator: "\n")
            },
            AgentTool(name: "open_file", description: "Open a file or folder at a path (reveal=yes to show it in Finder)", params: [("path", "Absolute path", false), ("reveal", "yes to reveal in Finder", true)], requires: ["file", "folder", "open", "reveal", "document", "show"]) { a in
                guard let p = arg(a, "path"), FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath) else { return "File not found" }
                let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                await MainActor.run {
                    if arg(a, "reveal")?.lowercased().hasPrefix("y") == true { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    else { NSWorkspace.shared.open(u) }
                }
                return "Opened \(u.lastPathComponent)"
            },
            AgentTool(name: "create_reminder", description: "Set a reminder that goes off in the Onyx notch at a time. Use for 'remind me to…'", params: [("title", "What to remind the user about, in their words", false), ("in_minutes", "Minutes from now, if they said 'in N minutes/hours'", true), ("at", "Date/time as yyyy-MM-dd HH:mm, if they gave a clock time", true)], requires: ["remind", "reminder"]) { a in
                guard let t = arg(a, "title") else { return "Missing title" }
                guard Assistant.grounded(t) else { return Assistant.ungrounded }
                guard let due = OnyxReminders.dueDate(inMinutes: arg(a, "in_minutes"), at: arg(a, "at"), request: Assistant.currentRequest) else {
                    return "Not set: no time given. Ask the user when they want to be reminded."
                }
                await MainActor.run { _ = OnyxReminders.shared.add(title: t, due: due) }
                let when = Calendar.current.isDateInToday(due) ? due.formatted(date: .omitted, time: .shortened) : due.formatted(date: .abbreviated, time: .shortened)
                return "Reminder set for \(when). The notch will ring then."
            },
            AgentTool(name: "list_reminders", description: "List the user's upcoming Onyx reminders", params: [], requires: ["remind", "reminder"]) { _ in
                await MainActor.run {
                    let r = OnyxReminders.shared.upcoming
                    return r.isEmpty ? "No upcoming reminders" : r.map { "\($0.title) — \($0.due.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
                }
            },
            AgentTool(name: "cancel_reminder", description: "Cancel an upcoming Onyx reminder by (part of) its title", params: [("title", "Words from the reminder's title", false)], requires: ["cancel", "delete", "remove", "stop", "clear"]) { a in
                guard let t = arg(a, "title") else { return "Missing title" }
                let gone = await MainActor.run { OnyxReminders.shared.cancel(matching: t) }
                return gone.isEmpty ? "No upcoming reminder matches \(t)" : "Cancelled: " + gone.map(\.title).joined(separator: ", ")
            },
            AgentTool(name: "add_to_reminders_app", description: "Add an item to Apple's Reminders app (only when the user asks for the Reminders app)", params: [("title", "What to remember", false), ("due", "Due date/time as yyyy-MM-dd HH:mm", true)], requires: ["reminders app", "apple reminders", "reminders list", "in reminders"]) { a in
                guard let t = arg(a, "title") else { return "Missing title" }
                guard Assistant.grounded(t) else { return Assistant.ungrounded }
                return try await CalendarService.shared.createReminder(title: t, due: arg(a, "due").flatMap(parseDate))
            },
            AgentTool(name: "create_event", description: "Add an event to the calendar", params: [("title", "Event title", false), ("start", "Start as yyyy-MM-dd HH:mm", false), ("minutes", "Duration in minutes", true)], requires: ["calendar", "event", "meeting", "schedule", "appointment", "book"]) { a in
                guard let t = arg(a, "title"), let s = arg(a, "start"), let d = parseDate(s) else { return "Need a title and a valid start time" }
                guard Assistant.grounded(t) else { return Assistant.ungrounded }
                let m = Int(arg(a, "minutes") ?? "") ?? 60
                return try await MainActor.run { try CalendarService.shared.createEvent(title: t, start: d, minutes: m) }
            },
            AgentTool(name: "compose_email", description: "Open a pre-filled email draft for the user to review and send", params: [("to", "Recipient email", true), ("subject", "Subject", false), ("body", "Email body", false)], requires: ["email", "e-mail", "mail"]) { a in
                var c = URLComponents(); c.scheme = "mailto"; c.path = arg(a, "to") ?? ""
                c.queryItems = [URLQueryItem(name: "subject", value: arg(a, "subject") ?? ""), URLQueryItem(name: "body", value: arg(a, "body") ?? "")]
                guard let u = c.url else { return "Couldn't build email" }
                await MainActor.run { _ = NSWorkspace.shared.open(u) }
                return "Opened an email draft (not sent — the user will review it)"
            },
            AgentTool(name: "set_timer", description: "Start a countdown timer in the notch", params: [("minutes", "Number of minutes", false)], requires: ["timer", "countdown", "minute", "min", "hour", "second"]) { a in
                guard let m = Double(arg(a, "minutes") ?? ""), m > 0 else { return "Invalid minutes" }
                await MainActor.run { FocusTimer.shared.begin(minutes: m) }
                return "Started a \(Int(m))-minute timer"
            },
            AgentTool(name: "copy_to_clipboard", description: "Copy text to the clipboard", params: [("text", "Text to copy", false)], requires: ["copy", "clipboard"]) { a in
                guard let t = arg(a, "text") else { return "Nothing to copy" }
                await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
                return "Copied to clipboard"
            },
            AgentTool(name: "read_screen", description: "Read the text currently visible on the user's screen", params: [], requires: ["screen", "on my", "this page", "this window", "looking at", "read", "see"]) { _ in
                String(try await ScreenReader.screenText().prefix(2000))
            },
            AgentTool(name: "control_music", description: "Control music playback", params: [("action", "play, pause, next, previous, or status", false)], requires: ["play", "pause", "skip", "next", "previous", "song", "music", "track", "resume", "stop", "listening"]) { a in
                let act = arg(a, "action")?.lowercased() ?? "status"
                return await MainActor.run {
                    let m = MediaController.shared
                    switch act {
                    case "play", "pause", "toggle": m.playPause(); return "Toggled playback"
                    case "next", "skip": m.next(); return "Skipped to next track"
                    case "previous", "back": m.previous(); return "Went to previous track"
                    default: return m.hasTrack ? "\(m.isPlaying ? "Playing" : "Paused"): \(m.title) by \(m.artist)" : "Nothing playing"
                    }
                }
            },
            AgentTool(name: "get_schedule", description: "Get the user's upcoming calendar events", params: [], requires: ["schedule", "calendar", "event", "meeting", "today", "tomorrow", "free", "busy", "week", "agenda", "plans"]) { _ in
                await MainActor.run {
                    let c = CalendarService.shared
                    guard c.authorized else { return "Calendar access not granted" }
                    let evs = c.upcoming
                    return evs.isEmpty ? "No upcoming events this week" :
                        evs.map { "\($0.title ?? "") — \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
                }
            },
        ]
    }
}

// MARK: - Assistant (Apple on-device model — free, private, offline)

final class Assistant: ObservableObject {
    static let shared = Assistant()
    enum Role { case user, assistant, tool, error }
    struct Msg: Identifiable { let id = UUID(); let role: Role; var text: String }

    @Published var messages: [Msg] = []
    @Published var busy = false
    @Published var agentMode = true
    @Published var seeScreen = false
    private var session: LanguageModelSession?
    private var sessionIsAgent = true
    /// The message being answered; tools check it before acting.
    static var currentRequest = ""
    static let ungrounded = "Not done: that title isn't something the user said. Ask the user what to call it instead of inventing one."

    /// True if the title shares a real word with what the user asked (so the model didn't make it up).
    static func grounded(_ title: String) -> Bool {
        let req = Set(currentRequest.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return title.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { $0.count >= 3 && req.contains(String($0)) }
    }

    /// "what is 32/40", "15% of 80?", "5 ft in cm": answered instantly by the calculator, no model needed.
    static func quickMath(_ text: String) -> String? {
        var q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = q.last, "?.!".contains(last) { q.removeLast() }
        for lead in ["what is", "what's", "whats", "how much is", "calculate", "calc", "compute", "convert", "solve", "="] where q.hasPrefix(lead + " ") {
            q = String(q.dropFirst(lead.count + 1)); break
        }
        q = q.trimmingCharacters(in: .whitespaces)
        guard q.contains(where: \.isNumber), Double(q) == nil, let r = Calc.evaluate(q) else { return nil }
        return "\(q) = \(r.display)"
    }
    private var task: Task<Void, Never>?

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use the free on-device AI."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading. Try again soon."
        case .unavailable: return "The on-device model is unavailable."
        }
    }

    private func instructions(agent: Bool) -> String {
        let now = Date().formatted(date: .complete, time: .shortened)
        var s = "You are Onyx, a friendly assistant built into the user's Mac notch. Now: \(now). Keep answers short (under 120 words) and use plain text."
        if agent {
            s += " You can act on the Mac with tools, but only when the user explicitly asks for that action. For questions (math, facts, explanations, advice) answer directly in words and do not call any tool. Never invent names, people, titles, places or times; only use details the user gave you. Only say an action happened if a tool confirmed it. Emails are only drafted, never sent. Dates for tools use yyyy-MM-dd HH:mm."
        }
        return s
    }

    func reset() { task?.cancel(); session = nil; messages = []; busy = false }
    /// Free the on-device model session while idle to reclaim memory; the chat log stays.
    func releaseIfIdle() { if !busy { session = nil } }
    func stop() { task?.cancel(); busy = false }

    func log(tool: String, result: String) {
        messages.append(Msg(role: .tool, text: "\(tool.replacingOccurrences(of: "_", with: " ")): \(result.prefix(140))"))
    }

    func send(_ text: String, context: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if context == nil, let answer = Self.quickMath(text) {
            messages.append(Msg(role: .user, text: text))
            messages.append(Msg(role: .assistant, text: answer))
            return
        }
        if let r = unavailableReason { messages.append(Msg(role: .error, text: r)); return }
        messages.append(Msg(role: .user, text: text))
        busy = true
        Self.currentRequest = text
        let agent = agentMode, look = seeScreen
        task = Task { @MainActor in
            defer { self.busy = false }
            do {
                var prompt = text
                if let context {
                    prompt = "Selected content:\n\"\"\"\n\(context.prefix(2500))\n\"\"\"\n\n\(text)"
                } else if look {
                    let screen = try await ScreenReader.screenText()
                    prompt = "Text visible on my screen right now:\n\"\"\"\n\(screen.prefix(2500))\n\"\"\"\n\nMy request: \(text)"
                }
                if session == nil || sessionIsAgent != agent {
                    session = agent
                        ? LanguageModelSession(tools: AgentTools.all, instructions: instructions(agent: true))
                        : LanguageModelSession(instructions: instructions(agent: false))
                    sessionIsAgent = agent
                }
                var idx: Int?
                // Low temperature: steadier answers, far fewer made-up tool calls.
                for try await snap in session!.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3)) {
                    if idx == nil { messages.append(Msg(role: .assistant, text: "")); idx = messages.count - 1 }
                    messages[idx!].text = snap.content
                }
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                session = nil
                messages.append(Msg(role: .error, text: "That conversation got too long, so I started a fresh one. Please ask again."))
            } catch is CancellationError {
            } catch {
                messages.append(Msg(role: .error, text: error.localizedDescription))
            }
        }
    }

    /// One-shot question used by Circle to Search.
    static func quickAnswer(about content: String, question: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            Task {
                do {
                    if let r = Assistant.shared.unavailableReason { throw NSError(domain: "Onyx", code: 4, userInfo: [NSLocalizedDescriptionKey: r]) }
                    let s = LanguageModelSession(instructions: "You explain things a user circled on their screen. Be concise: at most 90 words, plain text.")
                    for try await snap in s.streamResponse(to: "\(question)\n\nCircled content:\n\"\"\"\n\(content.prefix(2500))\n\"\"\"") {
                        cont.yield(snap.content)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
    }
}

// MARK: - Circle to Search

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CircleToSearch {
    static let shared = CircleToSearch()
    private var panel: OverlayPanel?

    func begin() {
        guard panel == nil else { return }
        let screen = ScreenReader.screenUnderMouse()
        Task { @MainActor in
            do {
                let img = try await ScreenReader.capture(screen: screen)
                self.present(img, on: screen)
            } catch {
                NotchModel.shared.flash(.message(icon: "exclamationmark.triangle.fill", text: "Allow Screen Recording", tint: .yellow), for: 3)
                let a = NSAlert(); a.messageText = "Circle to Search"; a.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
        }
    }

    private func present(_ img: CGImage, on screen: NSScreen) {
        let p = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setFrame(screen.frame, display: true)
        let view = CircleOverlayView(image: img, screenSize: screen.frame.size) { [weak self] in self?.end() }
        p.contentView = NSHostingView(rootView: view)
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func end() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CircleOverlayView: View {
    let image: CGImage
    let screenSize: CGSize
    let close: () -> Void

    @State private var points: [CGPoint] = []
    @State private var selection: CGRect?
    @State private var crop: CGImage?
    @State private var text = ""
    @State private var labels: [String] = []
    @State private var answer = ""
    @State private var thinking = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: CGFloat(image.width) / screenSize.width)
                .resizable()
                .frame(width: screenSize.width, height: screenSize.height)
            Color.black.opacity(selection == nil ? 0.35 : 0.5)
                .mask {
                    Rectangle().overlay {
                        if let r = selection {
                            RoundedRectangle(cornerRadius: 12).frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY).blendMode(.destinationOut)
                        }
                    }.compositingGroup()
                }
            Path { p in if let f = points.first { p.move(to: f); points.dropFirst().forEach { p.addLine(to: $0) } } }
                .stroke(LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .shadow(color: .purple.opacity(0.8), radius: 8)

            if selection == nil {
                hint
            } else if let r = selection {
                resultCard.frame(width: 380).position(cardPosition(for: r))
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if selection != nil { return }
                points.append(v.location)
            }
            .onEnded { _ in finishSelection() })
        .onExitCommand { close() }
        .background(KeyCatcher(onEscape: close))
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw.fill")
            Text("Circle anything to search · Esc to cancel")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.75), in: Capsule())
        .position(x: screenSize.width / 2, y: 70)
    }

    private func cardPosition(for r: CGRect) -> CGPoint {
        let h: CGFloat = 330
        var y = r.maxY + 16 + h / 2
        if y + h / 2 > screenSize.height { y = max(h / 2 + 10, r.minY - 16 - h / 2) }
        let x = min(max(r.midX, 200), screenSize.width - 200)
        return CGPoint(x: x, y: y)
    }

    private func finishSelection() {
        guard selection == nil else { return }
        guard points.count > 3 else { points = []; return }
        let xs = points.map(\.x), ys = points.map(\.y)
        var r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        if r.width < 12 || r.height < 12 { points = []; return }
        r = r.insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: screenSize))
        selection = r
        let s = CGFloat(image.width) / screenSize.width
        crop = image.cropping(to: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s))
        guard let crop else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let t = ScreenReader.ocr(crop), l = ScreenReader.labels(crop)
            DispatchQueue.main.async { text = t; labels = l }
        }
    }

    private var query: String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? labels.joined(separator: " ") : String(t.prefix(200))
    }

    private func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        close()
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let crop {
                    Image(decorative: crop, scale: 2).resizable().scaledToFit()
                        .frame(maxWidth: 90, maxHeight: 70).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.isEmpty ? (labels.isEmpty ? "Analyzing…" : "Looks like: " + labels.joined(separator: ", ")) : text)
                        .font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                chip("magnifyingglass", "Google") { open("https://www.google.com/search?q=\(enc(query))") }
                chip("camera.viewfinder", "Lens") {
                    if let crop {
                        let pb = NSPasteboard.general; pb.clearContents()
                        pb.writeObjects([NSImage(cgImage: crop, size: .zero)])
                    }
                    open("https://images.google.com/")
                }
                chip("character.book.closed", "Translate") { open("https://translate.google.com/?sl=auto&tl=en&op=translate&text=\(enc(text))") }
                chip(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
                }
            }
            Divider()
            if answer.isEmpty && !thinking {
                Button { ask() } label: {
                    Label("Explain this with AI", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
            } else {
                ScrollView {
                    Text(answer.isEmpty ? "Thinking…" : answer).font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 150)
            }
            Text("Lens: the image is copied — press ⌘V on the Google Images page.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func ask() {
        thinking = true
        let content = text.isEmpty ? "An image that looks like: \(labels.joined(separator: ", "))" : text
        Task { @MainActor in
            do {
                for try await s in Assistant.quickAnswer(about: content, question: "Explain what this is and anything useful to know about it.") { answer = s }
            } catch { answer = error.localizedDescription }
            thinking = false
        }
    }
}

/// Catches Esc even when SwiftUI's onExitCommand has no focused view.
struct KeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void
    final class V: NSView {
        var onEscape: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) } }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onEscape = onEscape; return v }
    func updateNSView(_ v: V, context: Context) { v.onEscape = onEscape }
}
