import AppKit
import SwiftUI
import PDFKit
import EventKit
import UniformTypeIdentifiers
import FoundationModels
import ApplicationServices

// MARK: - Something to ask Onyx AI about: a file you dropped, or text you had selected

struct AIDocument: Equatable {
    let name: String
    let text: String
    var selection = false   // selected text (from the Ask AI about selection shortcut) rather than a file
    var words: Int { text.split { $0.isWhitespace }.count }
}

enum DocumentReader {
    /// The text of a PDF, Word, RTF, HTML, Markdown or plain-text file; nil for anything it can't read.
    static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        var s: String?
        if type?.conforms(to: .pdf) == true {
            s = PDFDocument(url: url)?.string
        } else if let dt = ["docx": NSAttributedString.DocumentType.officeOpenXML, "doc": .docFormat, "rtf": .rtf, "rtfd": .rtfd,
                            "html": .html, "htm": .html, "odt": .openDocument, "webarchive": .webArchive][ext] {
            s = (try? NSAttributedString(url: url, options: [.documentType: dt], documentAttributes: nil))?.string
        } else if let t = type, [UTType.plainText, .sourceCode, .json, .commaSeparatedText, .xml, .yaml].contains(where: t.conforms(to:)) {
            s = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard let s else { return nil }
        // Squeeze runs of blank lines and spaces (PDFs are full of them) so more of the document fits.
        let tidy = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tidy.isEmpty ? nil : tidy
    }
}

// MARK: - Selected text in any app

enum SelectionGrabber {
    /// The text selected in the app in front: asked for through Accessibility first, else copied with ⌘C (and your
    /// clipboard is put back the way it was, without the copy landing in Clipboard history).
    @MainActor static func grab() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        if let s = fromAccessibility(), !s.isEmpty { return s }
        return await byCopying()
    }

    private static func fromAccessibility() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return (sel as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private static func byCopying() async -> String? {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = pb.pasteboardItems?.map { item in
            item.types.reduce(into: [:]) { d, t in d[t] = item.data(forType: t) }
        } ?? []
        let before = pb.changeCount
        ClipboardHistory.shared.paused = true
        defer { ClipboardHistory.shared.paused = false }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: down)   // C
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        for _ in 0..<12 where pb.changeCount == before { try? await Task.sleep(for: .milliseconds(50)) }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        pb.clearContents()
        if !saved.isEmpty {
            pb.writeObjects(saved.map { d in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            })
        }
        try? await Task.sleep(for: .milliseconds(900))   // let Clipboard history see the restore while it's paused
        return text
    }

    /// Ask AI about selection shortcut: attaches what you had selected and opens the AI tab with quick actions.
    @MainActor static func askAI() async {
        guard AXIsProcessTrusted() else {
            NotchModel.shared.flash(.message(icon: "hand.raised.fill", text: "Needs Accessibility (Settings › Privacy)", tint: .orange), for: 3)
            return
        }
        guard let s = await grab(), !s.isEmpty else {
            NotchModel.shared.flash(.message(icon: "character.cursor.ibeam", text: "Select some text first", tint: .orange), for: 2.5)
            return
        }
        Assistant.shared.document = AIDocument(name: "Selected text", text: s, selection: true)
        NotchController.current?.expand(tab: .ai, focus: true)
    }
}

// MARK: - Quick actions on an attached file or selection

struct AttachedDocumentBar: View {
    @ObservedObject var ai = Assistant.shared
    var body: some View {
        if let doc = ai.document {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: doc.selection ? "text.quote" : "doc.text.fill").foregroundStyle(.cyan)
                    Text(doc.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("· \(doc.words.formatted()) words").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button { ai.document = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(actions(doc), id: \.0) { title, prompt in
                            Button(title) {
                                guard title == "Translate" else { ai.send(prompt); return }
                                // Apple's translation models first (better, and on this Mac); the chat model if they aren't downloaded.
                                Task {
                                    if let t = await OnDeviceTranslate.translate(doc.text) {
                                        ai.messages.append(Assistant.Msg(role: .user, text: "Translate this\n📎 \(doc.name)"))
                                        ai.messages.append(Assistant.Msg(role: .assistant, text: t))
                                        ai.document = nil
                                    } else { ai.send(prompt) }
                                }
                            }
                                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.cyan.opacity(0.18), in: Capsule())
                        }
                    }
                }
                Text(doc.selection ? "Pick one, or type your own question about it." : "Ask anything about it, or pick one.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func actions(_ d: AIDocument) -> [(String, String)] {
        let lang = Locale.current.localizedString(forLanguageCode: Locale.preferredLanguages.first ?? "en") ?? "English"
        let translate = lang == "English" ? "Translate this into English. If it's already English, translate it into Spanish." : "Translate this into \(lang)."
        return d.selection
            ? [("Summarize", "Summarize this in a few sentences."), ("Explain", "Explain this simply."), ("Rewrite", "Rewrite this to be clearer and more polished. Give only the rewritten text."),
               ("Fix grammar", "Fix the spelling and grammar. Give only the corrected text."), ("Translate", translate), ("Key points", "List the key points as short bullets.")]
            : [("Summarize", "Summarize this document."), ("Key points", "List the most important points as short bullets."),
               ("Explain", "Explain what this document is about, simply."), ("Action items", "List any deadlines, tasks or action items in it.")]
    }
}

extension Assistant {
    /// Attaches a dropped or chosen file for the next question (images still go through `attach`).
    func attachFile(_ url: URL) {
        if let img = NSImage(contentsOf: url), UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true { attach(img); return }
        guard let text = DocumentReader.text(of: url) else {
            messages.append(Msg(role: .error, text: "Onyx AI can read PDFs, Word, RTF, HTML and text files, but not \(url.lastPathComponent)."))
            return
        }
        document = AIDocument(name: url.lastPathComponent, text: text)
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .plainText, .rtf, .html, .sourceCode, .json, .commaSeparatedText, .image] + ["docx", "doc", "md", "odt"].compactMap { UTType(filenameExtension: $0) }
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { attachFile(u) }
    }

    /// What the model gets from an attached document. Short ones go in whole. Long ones are read part by part for
    /// what matters to the question, and those notes go in instead (the on-device model only reads a few pages at once).
    @MainActor func read(_ doc: AIDocument, for question: String, effort: AIEffort) async throws -> String {
        let label = doc.selection ? "Selected text" : "The file \"\(doc.name)\""
        let limit = effort.contextChars + 1500
        if doc.text.count <= limit { return "\(label):\n\"\"\"\n\(doc.text)\n\"\"\"" }
        let size = limit, maxParts = 16
        var parts: [Substring] = []
        var rest = Substring(doc.text)
        while !rest.isEmpty && parts.count < maxParts { parts.append(rest.prefix(size)); rest = rest.dropFirst(size) }
        let words = max(30, 700 / parts.count)
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            status = "Reading part \(i + 1) of \(parts.count)…"
            let s = LanguageModelSession(instructions: "You take short, factual notes from part of a document. Plain text, no preamble.")
            let prompt = "Part \(i + 1) of \(parts.count) of \(doc.name):\n\"\"\"\n\(part)\n\"\"\"\n\nWrite at most \(words) words of notes on what in this part helps with: \(question)\nIf nothing does, write only NONE."
            if let n = try? await Self.retrying({ try await s.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 300)).content }),
               !n.uppercased().hasPrefix("NONE") {
                notes.append("Part \(i + 1): " + n.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let cut = rest.isEmpty ? "" : " (Onyx read the first \(parts.count * size / 1000)K characters; it's longer than that.)"
        return "\(label) is long, so here are notes from reading it part by part\(cut):\n" + (notes.isEmpty ? "Nothing in it seemed related." : notes.joined(separator: "\n")).prefix(5000)
    }
}

// MARK: - Daily briefing

enum Briefing {
    static let key = "briefing.morning", lastKey = "briefing.last"

    /// Today's facts: weather, what's on the calendar, reminders and schoolwork due.
    @MainActor static func facts() async -> [String] {
        var out: [String] = []
        let now = Date(), cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        out.append("Today is \(now.formatted(.dateTime.weekday(.wide).month(.wide).day())), it's \(now.formatted(date: .omitted, time: .shortened)).")

        let w = WeatherService.shared
        if let t = w.temp {
            var s = "Weather\(w.place.isEmpty ? "" : " in \(w.place)"): \(Int(t.rounded()))°, \(words(w.code))"
            if let hi = w.high, let lo = w.low { s += ", high \(Int(hi.rounded()))°, low \(Int(lo.rounded()))°" }
            if let wet = w.hourly.first(where: { $0.time > now && $0.time < endOfDay && $0.precip >= 50 }) {
                s += ". \(wet.code >= 71 && wet.code <= 86 ? "Snow" : "Rain") likely around \(wet.time.formatted(date: .omitted, time: .shortened)) (\(wet.precip)%)"
            }
            out.append(s + ".")
        }

        let calendar = CalendarService.shared
        if calendar.authorized {
            let events = CalendarAccounts.events(calendar.store, from: now, to: endOfDay)
                .sorted { $0.startDate < $1.startDate }
            if events.isEmpty { out.append("No more events on the calendar today.") }
            for e in events.prefix(6) {
                let when = e.isAllDay ? "All day" : e.startDate.formatted(date: .omitted, time: .shortened)
                out.append("Event: \(when) \(e.title ?? "Untitled")" + (e.meetingURL != nil ? " (video call)" : "") + ".")
            }
        }

        for r in OnyxReminders.shared.upcoming where r.due <= endOfDay {
            out.append("Reminder: \(r.title) at \(r.due.formatted(date: .omitted, time: .shortened)).")
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let store = calendar.store
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfDay, calendars: nil)
            let due: [String] = await withCheckedContinuation { c in
                store.fetchReminders(matching: pred) { rs in c.resume(returning: (rs ?? []).prefix(6).compactMap(\.title)) }
            }
            for t in due { out.append("To do today: \(t).") }
        }

        let canvas = CanvasService.shared.items.filter { ($0.due ?? .distantFuture) < now.addingTimeInterval(48 * 3600) }
        let overdue = canvas.filter(\.overdue)
        if !overdue.isEmpty { out.append("Overdue on Canvas: " + overdue.prefix(3).map { "\($0.title) (\($0.course))" }.joined(separator: "; ") + ".") }
        for i in canvas.filter({ !$0.overdue }).prefix(4) {
            out.append("Due on Canvas: \(i.title) (\(i.course)) \(i.due.map { $0.formatted(.relative(presentation: .named)) } ?? "").")
        }
        return out
    }

    static func words(_ code: Int) -> String {
        switch code {
        case 0: "clear"
        case 1, 2: "partly cloudy"
        case 3: "cloudy"
        case 45, 48: "foggy"
        case 51...57: "drizzle"
        case 61...67, 80...82: "rain"
        case 71...77, 85, 86: "snow"
        case 95...99: "thunderstorms"
        default: "cloudy"
        }
    }

    /// A few friendly sentences from the facts (just the facts as a list if Apple Intelligence isn't available).
    @MainActor static func make() async -> String {
        let f = await facts()
        let greeting = { let h = Calendar.current.component(.hour, from: Date()); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }()
        guard Assistant.shared.unavailableReason == nil else { return greeting + "! Here's your day:\n" + f.map { "• " + $0 }.joined(separator: "\n") }
        let prompt = "Facts:\n" + f.joined(separator: "\n") + "\n\nWrite the briefing in 3 to 5 short sentences, starting with \"\(greeting)!\". Mention anything due or overdue first."
        if let r = try? await AIText.complete(system: "You write a short, friendly daily briefing. Use only the facts given; never add events, times or details that aren't there. Plain text.",
                                              prompt: prompt, maxTokens: 300) {
            return Assistant.plain(r)
        }
        return greeting + "! Here's your day:\n" + f.map { "• " + $0 }.joined(separator: "\n")
    }

    /// Adds a briefing to the AI chat (from the Brief Me button, or once each morning).
    @MainActor static func post() async {
        let ai = Assistant.shared
        guard !ai.busy else { return }
        ai.busy = true; ai.status = "Putting your briefing together…"
        let text = await make()
        ai.busy = false; ai.status = nil
        ai.messages.append(Assistant.Msg(role: .assistant, text: text))
    }

    /// Once a day, the first time you're at your Mac between 5 AM and noon: a briefing waits in the AI tab.
    @MainActor static func watch() {
        let check = {
            MainActor.assumeIsolated {
                let now = Date(), h = Calendar.current.component(.hour, from: now)
                let today = now.formatted(.iso8601.year().month().day())
                guard Prefs.bool(key), h >= 5, h < 12, UserDefaults.standard.string(forKey: lastKey) != today else { return }
                UserDefaults.standard.set(today, forKey: lastKey)
                Task {
                    await post()
                    NotchModel.shared.tab = .ai
                    NotchModel.shared.flash(.message(icon: "sun.horizon.fill", text: "Your morning briefing is ready", tint: .yellow), for: 4)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in check() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { check() }   // after launch, once the weather and calendar have loaded
    }
}
