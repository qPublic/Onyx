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
    var logs = true            // show the call in the chat (off for behind-the-scenes thinking)
    let run: @Sendable (GeneratedContent) async throws -> String

    var parameters: GenerationSchema {
        let props = params.map {
            DynamicGenerationSchema.Property(name: $0.name, description: $0.info,
                                             schema: DynamicGenerationSchema(type: String.self), isOptional: $0.optional)
        }
        return try! GenerationSchema(root: DynamicGenerationSchema(name: name + "_args", properties: props), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        // The small model can get stuck calling a tool over and over: answer repeats from memory and cap the total.
        let key = name + "|" + arguments.jsonString
        if let prev = ToolBudget.previous(key) { return prev + " (already done; now answer without calling tools again)" }
        guard ToolBudget.spend() else { throw ToolBudget.Exhausted() }
        let request = Assistant.currentRequest.lowercased()
        if !requires.isEmpty && !requires.contains(where: request.contains) {
            return "Not done: the user didn't ask for this. Don't use tools for this message; answer it directly in words."
        }
        let out = try await run(arguments)
        ToolBudget.record(key, out)
        if logs { await MainActor.run { Assistant.shared.log(tool: name, result: out) } }
        return out
    }
}

/// Tool calls allowed per model request (reset before each one). Locked: the model can call tools in parallel.
enum ToolBudget {
    struct Exhausted: Error {}
    static let limit = 8
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0
    nonisolated(unsafe) private static var done: [String: String] = [:]
    static func reset() { lock.withLock { calls = 0; done = [:] } }
    static func previous(_ key: String) -> String? { lock.withLock { done[key] } }
    /// Counts a call; false once the budget is used up.
    static func spend() -> Bool { lock.withLock { calls += 1; return calls <= limit } }
    static func record(_ key: String, _ result: String) { lock.withLock { done[key] = result } }
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
    /// Exact math, so the small model doesn't have to do arithmetic in its head (available in Ask and Agent).
    static let calculator = makeCalculator(logs: true)
    static let quietCalculator = makeCalculator(logs: false)   // for the hidden thinking passes

    private static func makeCalculator(logs: Bool) -> AgentTool {
        AgentTool(name: "calculate", description: "Exact arithmetic, unit conversion, or solving a linear equation with one unknown. Use it instead of doing math in your head, e.g. 180-(45+60), 15% of 80, sqrt(144), 5 ft in cm, 3x + 10 + 2x + 20 = 180",
                  params: [("expression", "The calculation or equation", false)], logs: logs) { a in
            guard let raw = arg(a, "expression") else { return "Missing expression" }
            // The model often writes "180° - 35°" or "= ?"; keep just the math.
            var e = raw.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "degrees", with: "")
            if let solved = solveLinear(e) { return solved }
            e = e.components(separatedBy: "=").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? e
            // "3x + 10" has a variable (the calculator would read x as ×); unit conversions like "5 ft in cm" are fine.
            let converting = e.range(of: #"\s(in|to|as|into)\s"#, options: [.regularExpression, .caseInsensitive]) != nil
            if !converting, e.lowercased().range(of: #"\d\s*[a-df-z]\b|\b[a-df-z]\b"#, options: .regularExpression) != nil {
                return "TOOL ERROR: the calculator needs plain numbers, or an equation with one unknown like 5x + 30 = 180."
            }
            if let r = Calc.evaluate(e) { return "\(e.trimmingCharacters(in: .whitespaces)) = \(r.display)" }
            return "TOOL ERROR: couldn't calculate that. Work it out step by step without the tool."
        }
    }

    /// "3x + 10 + 2x + 20 = 180" → "x = 30". One unknown, linear only.
    static func solveLinear(_ eq: String) -> String? {
        let sides = eq.components(separatedBy: "=")
        guard sides.count == 2, !sides[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let pattern = #"(?<![a-z])[a-df-z](?![a-z])"#   // a single-letter unknown (not e, which is Euler's number)
        let lower = eq.lowercased()
        let vars = Set((try? NSRegularExpression(pattern: pattern)).map { re in
            re.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).compactMap { Range($0.range, in: lower).map { String(lower[$0]) } }
        } ?? [])
        guard vars.count == 1, let v = vars.first else { return nil }
        func f(_ x: Double) -> Double? {
            func side(_ s: String) -> Double? {
                let sub = s.lowercased().replacingOccurrences(of: #"(?<![a-z])\#(v)(?![a-z])"#, with: "(\(x))", options: .regularExpression)
                return Calc.evaluate(sub).flatMap { Double($0.copy) }
            }
            guard let l = side(sides[0]), let r = side(sides[1]) else { return nil }
            return l - r
        }
        guard let f0 = f(0), let f1 = f(1), let f2 = f(2), abs(f2 - 2 * f1 + f0) < 1e-9 * max(1, abs(f1)), f1 != f0 else { return nil }
        let x = -f0 / (f1 - f0)
        return "\(v) = \(Calc.format(x, grouped: false))"
    }

    static var all: [AgentTool] {
        [
            calculator,
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
                await ImageReader.analyze(try await ScreenReader.capture(), effort: AIEffort.current).prompt(limit: 2000)
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
    struct Msg: Identifiable { let id = UUID(); let role: Role; var text: String; var image: NSImage? = nil }

    @Published var messages: [Msg] = []
    @Published var busy = false
    @Published var agentMode = true
    @Published var seeScreen = false
    @Published var status: String?            // "Reading your screen…", "Thinking…"
    @Published var attachment: CGImage?       // an image to ask about
    private var session: LanguageModelSession?
    private var sessionIsAgent = true
    private var sessionEffort = AIEffort.medium
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

    private func instructions(agent: Bool, effort: AIEffort) -> String {
        let now = Date().formatted(date: .complete, time: .shortened)
        var s = "You are Onyx, a friendly assistant built into the user's Mac notch. Now: \(now). Use plain text, never LaTeX: write math like 5x + 30 = 180."
        switch effort {
        case .low: s += " Give just the answer, with at most one short line of working."
        case .medium: s += " Keep answers short (under 120 words)."
        case .high, .max: s += " Be accurate. For math and problems, show the key steps briefly, then the answer (under 200 words)."
        }
        if agent || effort == .high || effort == .max { s += " Use the calculate tool for arithmetic with plain numbers." }
        else { s += " For math, work step by step and double-check the arithmetic." }
        s += " When the user shares an image or their screen, you get a description made by image recognition and OCR; answer about it directly."
        if agent {
            s += " You can act on the Mac with tools, but only when the user explicitly asks for that action. For questions (math, facts, explanations, advice) answer directly in words and do not call any tool. Never invent names, people, titles, places or times; only use details the user gave you. Only say an action happened if a tool confirmed it. Emails are only drafted, never sent. Dates for tools use yyyy-MM-dd HH:mm."
        }
        return s
    }

    func reset() { task?.cancel(); session = nil; messages = []; busy = false; status = nil; attachment = nil }
    /// Free the on-device model session while idle to reclaim memory; the chat log stays.
    func releaseIfIdle() { if !busy { session = nil } }
    func stop() { task?.cancel(); busy = false; status = nil }

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
        let image = attachment
        attachment = nil
        messages.append(Msg(role: .user, text: text, image: image.map { NSImage(cgImage: $0, size: .zero) }))
        busy = true
        Self.currentRequest = text
        let agent = agentMode, look = seeScreen, effort = AIEffort.current
        task = Task { @MainActor in
            defer { self.busy = false; self.status = nil }
            do {
                // 1. Turn what the user shared into text the model can read.
                var shared: [String] = []
                if let context { shared.append("Selected content:\n\"\"\"\n\(context.prefix(effort.contextChars))\n\"\"\"") }
                if let image {
                    status = "Looking at the image…"
                    let r = await ImageReader.analyze(image, effort: effort)
                    shared.append(r.isEmpty ? "The user attached an image, but nothing in it could be recognized." : "The user attached an image. " + r.prompt(limit: effort.contextChars))
                } else if look {
                    status = "Reading your screen…"
                    let r = await ImageReader.analyze(try await ScreenReader.capture(), effort: effort)
                    shared.append("This is what's on the user's screen right now. " + r.prompt(limit: effort.contextChars))
                }
                let request = shared.isEmpty ? text : shared.joined(separator: "\n\n") + "\n\nMy request: " + text

                // 2. High / Max: work it out first in a scratch session, then answer with those notes.
                var notes: String?
                if effort == .high || effort == .max {
                    status = effort == .max ? "Thinking it through three ways…" : "Thinking…"
                    do { notes = try await Self.think(request, effort: effort) }
                    catch is CancellationError { throw CancellationError() }
                    catch { notes = nil }   // answer anyway, just without the extra thinking
                }
                status = "Writing…"
                try await answer(request, notes: notes, agent: agent, effort: effort)
            } catch is CancellationError {
            } catch {
                messages.append(Msg(role: .error, text: error.localizedDescription))
            }
        }
    }

    private func makeSession(agent: Bool, effort: AIEffort) -> LanguageModelSession {
        // In Ask mode the calculator only helps with a thinking pass behind it (High / Max); at Low and Medium the
        // small model tends to feed it things like "m∠A + m∠B" and then guess, so it reasons in plain text instead.
        LanguageModelSession(tools: agent ? AgentTools.all : (effort == .high || effort == .max) ? [AgentTools.calculator] : [],
                             instructions: instructions(agent: agent, effort: effort))
    }

    private static func options(_ effort: AIEffort) -> GenerationOptions {
        switch effort {
        case .low: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)   // fastest, most predictable
        case .medium: GenerationOptions(temperature: 0.3)   // steady answers, far fewer made-up tool calls
        case .high, .max: GenerationOptions(temperature: 0.2)
        }
    }

    /// Streams the final answer. If the chat has grown too big for the model, starts fresh once with a trimmed prompt.
    @MainActor private func answer(_ request: String, notes: String?, agent: Bool, effort: AIEffort) async throws {
        func prompt(_ limit: Int) -> String {
            let r = request.count > limit ? String(request.prefix(limit)) + "…" : request
            guard let notes else { return r }
            return r + "\n\nYour own working notes (check them for mistakes, then give your answer; don't mention the notes):\n" + notes.prefix(limit / 2)
        }
        for attempt in 0..<3 {
            if session == nil || sessionIsAgent != agent || sessionEffort != effort {
                session = makeSession(agent: agent, effort: effort)
                sessionIsAgent = agent; sessionEffort = effort
            }
            do {
                var idx: Int?
                ToolBudget.reset()
                for try await snap in session!.streamResponse(to: prompt(attempt == 0 ? 6000 : 2500), options: Self.options(effort)) {
                    if idx == nil { status = nil; messages.append(Msg(role: .assistant, text: "")); idx = messages.count - 1 }
                    messages[idx!].text = Self.plain(snap.content)
                }
                // It parroted a tool error instead of answering: drop that and answer once more without tools.
                if let i = idx, messages[i].text.contains("TOOL ERROR") {
                    messages.remove(at: i)
                    throw ToolBudget.Exhausted()
                }
                return
            } catch is ToolBudget.Exhausted {
                session = nil
                try await answerWithoutTools(prompt(3000), effort: effort)
                return
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                session = nil   // forget the earlier conversation and try again, shorter
                if attempt == 2 { messages.append(Msg(role: .error, text: "That was too much for the on-device model at once. Try a shorter question or a smaller part of the screen.")) }
            } catch let e as LanguageModelSession.GenerationError where Self.isBusy(e) && attempt < 2 {
                try await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))   // macOS limits background apps' model use; wait and retry
            } catch let e as LanguageModelSession.ToolCallError where e.underlyingError is ToolBudget.Exhausted {
                session = nil   // stuck calling tools: answer once more with no tools at all
                try await answerWithoutTools(prompt(3000), effort: effort)
                return
            }
        }
    }

    @MainActor private func answerWithoutTools(_ prompt: String, effort: AIEffort) async throws {
        let s = LanguageModelSession(instructions: instructions(agent: false, effort: effort) + " Answer directly; you have no tools.")
        var idx: Int?
        for try await snap in s.streamResponse(to: prompt, options: Self.options(effort)) {
            if idx == nil { status = nil; messages.append(Msg(role: .assistant, text: "")); idx = messages.count - 1 }
            messages[idx!].text = Self.plain(snap.content)
        }
    }

    /// High: one careful step-by-step pass. Max: three independent attempts, then a pass that compares them.
    private static func think(_ request: String, effort: AIEffort) async throws -> String {
        let instructions = "You work problems out carefully. Restate what is asked, list the facts given, then reason step by step. Use the calculate tool for arithmetic. Be concise, plain text, no LaTeX. End with a line starting 'Answer:'."
        func attempt(_ temperature: Double) async throws -> String {
            try await retrying {
                ToolBudget.reset()
                let s = LanguageModelSession(tools: [AgentTools.quietCalculator], instructions: instructions)
                return try await s.respond(to: String(request.prefix(5000)), options: GenerationOptions(temperature: temperature, maximumResponseTokens: 600)).content
            }
        }
        if effort != .max { return String(try await attempt(0.2).prefix(1600)) }
        // Max: three independent attempts (one at a time: the on-device model runs one request best).
        var drafts: [String] = []
        for t in [0.2, 0.4, 0.6] { drafts.append(try await attempt(t)) }
        // Majority vote: if two attempts reach the same answer, trust it. The small model is a worse judge than a vote.
        let answers = drafts.map(finalAnswer)
        for (i, a) in answers.enumerated() {
            guard let a, answers.filter({ $0 == a }).count >= 2 else { continue }
            return String(drafts[i].prefix(1500)) + "\n(Two of three independent attempts reached this same answer.)"
        }
        let judge = LanguageModelSession(tools: [AgentTools.quietCalculator], instructions: "You compare several attempts at the same problem, spot mistakes, and settle on the correct answer. Be concise.")
        let compare = "Problem:\n\(request.prefix(1800))\n\n" + drafts.enumerated().map { "Attempt \($0.offset + 1):\n\($0.element.prefix(800))" }.joined(separator: "\n\n")
            + "\n\nWhich attempt is right? Point out mistakes, then give the correct reasoning and a final line starting 'Answer:'."
        return String(try await retrying { ToolBudget.reset(); return try await judge.respond(to: compare, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 600)).content }.prefix(1600))
    }

    /// The model is rate-limited (macOS throttles background apps) or already busy: worth waiting and retrying.
    static func isBusy(_ e: LanguageModelSession.GenerationError) -> Bool {
        switch e {
        case .rateLimited, .concurrentRequests: true
        default: false
        }
    }

    static func retrying<T>(_ op: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do { return try await op() }
            catch let e as LanguageModelSession.GenerationError where isBusy(e) && attempt < 2 {
                try await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
            }
        }
        return try await op()
    }

    /// The chat shows plain text, so turn any LaTeX the model slips in into readable math.
    static func plain(_ s: String) -> String {
        var t = s
        for (a, b) in [("\\[", ""), ("\\]", ""), ("\\(", ""), ("\\)", ""), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"),
                       ("\\angle", "∠"), ("^\\circ", "°"), ("\\circ", "°"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"),
                       ("\\pi", "π"), ("\\theta", "θ"), ("\\sqrt", "√"), ("\\left", ""), ("\\right", ""), ("\\quad", " "), ("\\,", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: #"\\(begin|end)\{[^}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&=", with: "=").replacingOccurrences(of: "\\\\", with: "\n")
        t = t.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\text\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        return t
    }

    /// The "Answer: …" line of a worked attempt, normalized so two attempts can be compared.
    static func finalAnswer(_ s: String) -> String? {
        guard let line = s.components(separatedBy: "\n").last(where: { $0.range(of: "answer:", options: .caseInsensitive) != nil }),
              let r = line.range(of: "answer:", options: [.caseInsensitive, .backwards]) else { return nil }
        let a = line[r.upperBound...].lowercased().filter { $0.isNumber || $0.isLetter || "=.-/".contains($0) }
        return a.isEmpty ? nil : a
    }

    // MARK: Attaching images

    func attach(_ image: NSImage) {
        var r = CGRect(origin: .zero, size: image.size)
        attachment = image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    func attachFromClipboard() -> Bool {
        guard let img = NSImage(pasteboard: .general) else { return false }
        attach(img); return true
    }

    func chooseImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) { attach(img) }
    }

    /// macOS's own area picker (crosshair), then back to the AI tab with the picture attached.
    func captureArea() {
        NotchController.current?.collapse()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-ai-capture-\(UUID().uuidString).png")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path]
            try? p.run(); p.waitUntilExit()
            await MainActor.run {
                if let img = NSImage(contentsOf: file) { self.attach(img) }
                try? FileManager.default.removeItem(at: file)
                (NSApp.delegate as? AppDelegate)?.askAI()
            }
        }
    }

    /// One-shot question used by Circle to Search: reads the circled picture, thinks first on High / Max.
    static func quickAnswer(image: CGImage, question: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            Task {
                do {
                    if let r = Assistant.shared.unavailableReason { throw NSError(domain: "Onyx", code: 4, userInfo: [NSLocalizedDescriptionKey: r]) }
                    let effort = AIEffort.current
                    let report = await ImageReader.analyze(image, effort: effort)
                    let request = "\(question)\n\nThe user circled part of their screen. " + report.prompt(limit: effort.contextChars)
                    var prompt = request
                    if effort == .high || effort == .max {
                        cont.yield("Thinking…")
                        prompt += "\n\nYour own working notes (check them, then answer):\n" + (try await think(request, effort: effort))
                    }
                    let s = LanguageModelSession(tools: [AgentTools.calculator], instructions: "You explain or solve what a user circled on their screen. Use the calculate tool for arithmetic. Be concise: at most \(effort == .low ? 50 : 120) words, plain text.")
                    for try await snap in s.streamResponse(to: prompt, options: options(effort)) { cont.yield(snap.content) }
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
        Task { @MainActor in
            let r = await ImageReader.analyze(crop, effort: .medium)   // math symbols repaired, labels, codes
            text = r.text.isEmpty ? (r.codes.first ?? "") : r.text
            labels = r.labels
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
                chip("sparkles", "Ask AI") {
                    if let crop { Assistant.shared.attachment = crop }
                    close()
                    (NSApp.delegate as? AppDelegate)?.askAI()
                }
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
        guard let crop else { thinking = false; return }
        Task { @MainActor in
            do {
                for try await s in Assistant.quickAnswer(image: crop, question: "Explain what this is and anything useful to know about it. If it's a problem or question, solve it.") { answer = s }
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

// MARK: - Self-test: ONYX_AI_TEST=1 asks about rendered geometry problems at every effort, logs answers + timings, quits.

enum AISelfTest {
    static func render(_ lines: [String]) -> CGImage? {
        let w = 1100, h = 60 + 56 * lines.count
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Times New Roman" as CFString, 30, nil)
        for (i, l) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [.font: font, .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 30, y: CGFloat(h - 60 - i * 56))
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    @MainActor static func run() async {
        let file = Prefs.supportDir.appendingPathComponent("ai-test.log")
        try? FileManager.default.removeItem(at: file)
        func log(_ s: String) { Shell.log(s); if let d = (s + "\n").data(using: .utf8), let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? (s + "\n").write(to: file, atomically: true, encoding: .utf8) } }
        let problems = [
            ["In triangle ABC, m∠A = 35° and m∠B = 65°.", "Find m∠C."],
            ["∠1 and ∠2 are supplementary angles.", "m∠1 = 3x + 10 and m∠2 = 2x + 20.", "Find x and m∠1."],
        ]
        let saved = UserDefaults.standard.string(forKey: AIEffort.key)
        let ai = Assistant.shared
        log("AI available: \(ai.unavailableReason ?? "yes")")
        for p in problems {
            guard let img = render(p) else { continue }
            log("\n=== Problem: \(p.joined(separator: " "))")
            log("What the AI is given:\n" + (await ImageReader.analyze(img, effort: .medium)).prompt(limit: 2500))
            for e in AIEffort.allCases {
                UserDefaults.standard.set(e.rawValue, forKey: AIEffort.key)
                ai.reset(); ai.agentMode = false; ai.seeScreen = false
                ai.attachment = img
                let t0 = Date()
                ai.send("Solve this")
                while ai.busy { try? await Task.sleep(for: .milliseconds(200)) }
                let out = ai.messages.dropFirst().map { "[\($0.role)] \($0.text)" }.joined(separator: "\n")
                log("--- \(e.title) (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s):\n\(out)")
            }
        }
        if let saved { UserDefaults.standard.set(saved, forKey: AIEffort.key) } else { UserDefaults.standard.removeObject(forKey: AIEffort.key) }
        ai.reset()
        log("== done")
        NSApp.terminate(nil)
    }
}
