import Foundation
import FoundationModels

// MARK: - Finding events in an email: invitations are read exactly; everything else goes to the model, then every answer is
// checked against the email's own words (the day, the time, the quote) before it can reach the calendar.

struct FoundEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location = ""
    var from = "", fromName = ""
    var subject = ""
    var messageID = ""
    var careful = false
    var eventID: String?
    var found = Date()
    var sender: String { fromName.isEmpty ? from : fromName }
}

enum MailRules {
    static let neverKey = "mail.never", carefulKey = "mail.careful"
    static var never: [String] { list(neverKey) }
    static var careful: [String] { list(carefulKey) }
    static func list(_ k: String) -> [String] {
        (UserDefaults.standard.string(forKey: k) ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func set(_ k: String, _ items: [String]) { UserDefaults.standard.set(items.joined(separator: "\n"), forKey: k) }

    /// "sam@x.com" (that address), "@x.com" or "x.com" (anyone there, subdomains too), or a name ("Coach Smith").
    static func matches(_ rules: [String], address: String, name: String) -> Bool {
        let a = address.lowercased(), n = name.lowercased()
        return rules.contains { r0 in
            let r = r0.lowercased().trimmingCharacters(in: .whitespaces)
            if r.isEmpty { return false }
            if r.contains("@") && !r.hasPrefix("@") { return a == r }
            let d = r.hasPrefix("@") ? String(r.dropFirst()) : r
            if d.contains(".") { return a.hasSuffix("@" + d) || a.hasSuffix("." + d) }
            return !n.isEmpty && n.contains(d)
        }
    }
}

enum MailEventFinder {
    struct Candidate: Equatable { var title = "", date = "", start = "", end = "", location = "", evidence = "" }

    /// A day or time is mentioned somewhere; emails without one aren't worth the model's time.
    static func mentionsWhen(_ text: String) -> Bool {
        let t = String(text.prefix(6000))
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
        return t.lowercased().range(of: #"\b(tomorrow|tonight|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week|noon|\d{1,2}(:\d\d)? ?(am|pm))\b"#,
                                    options: .regularExpression) != nil
    }

    static let instructions = """
        You read one email for someone and find events they should put on their calendar: appointments, meetings, classes, \
        practices, games, rehearsals, parties, reservations, flights, interviews, and deadlines on a set day. Skip sales and \
        offers, things that already happened, and plans with no day yet. Work out the real date from the day the email was \
        sent: "Friday" means the next Friday after that day. Use only what the email says: never invent a time, place or event.
        """

    @available(macOS 26, *)
    static var schema: GenerationSchema? { try? GenerationSchema(root: DynamicGenerationSchema(name: "EmailEvents", properties: [
        .init(name: "events", description: "Events in this email to put on the calendar. Empty if there are none.",
              schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Event", properties: [
                .init(name: "title", description: "What it is, 2 to 6 words, e.g. Dentist appointment, Soccer practice, Dinner with Sam",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "date", description: "The day it happens, yyyy-MM-dd", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "start", description: "Start time, HH:mm in 24-hour time, or empty if the email gives no time", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "end", description: "End time, HH:mm in 24-hour time, or empty", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "location", description: "Where, if the email says; otherwise empty", schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "evidence", description: "The exact words from the email that give the day and time", schema: DynamicGenerationSchema(type: String.self)),
              ]), minimumElements: 0, maximumElements: 3)),
    ]), dependencies: []) }

    @available(macOS 26, *)
    static var reviewSchema: GenerationSchema? { try? GenerationSchema(root: DynamicGenerationSchema(name: "EventCheck", properties: [
        .init(name: "real", description: "True if the email really describes this event for the reader", schema: DynamicGenerationSchema(type: Bool.self)),
        .init(name: "date", description: "The correct day, yyyy-MM-dd", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "start", description: "The correct start time, HH:mm in 24-hour time, or empty if none is given", schema: DynamicGenerationSchema(type: String.self)),
    ]), dependencies: []) }

    static func prompt(_ m: MailMessage, limit: Int) -> String {
        let sent = m.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
        return "The email was sent on \(sent). Today is \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year())).\n"
            + "From: \(m.fromName) <\(m.from)>\nSubject: \(m.subject)\n\n\(m.text.prefix(limit))"
    }

    @available(macOS 26, *)
    static func candidates(_ c: GeneratedContent) -> [Candidate] {
        guard case .structure(let props, _) = c.kind, let list = props["events"], case .array(let items) = list.kind else { return [] }
        func s(_ e: GeneratedContent, _ k: String) -> String { ((try? e.value(String.self, forProperty: k)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return items.map { Candidate(title: s($0, "title"), date: s($0, "date"), start: s($0, "start"), end: s($0, "end"), location: s($0, "location"), evidence: s($0, "evidence")) }
    }

    /// The model's events for one email. Careful senders: more of the email is read, and each event is checked a second time.
    static func find(in m: MailMessage, careful: Bool, cloud: Bool) async throws -> [FoundEvent] {
        var list: [Candidate]
        if cloud {
            let raw = try await CloudAI.complete(system: instructions + " Reply with JSON only: {\"events\":[{\"title\":\"\",\"date\":\"yyyy-MM-dd\",\"start\":\"HH:mm or empty\",\"end\":\"HH:mm or empty\",\"location\":\"\",\"evidence\":\"\"}]}",
                                                 prompt: prompt(m, limit: 30_000), maxTokens: 900)
            list = json(raw)
        } else {
            guard #available(macOS 26, *), let schema else { return [] }   // macOS 15: only a cloud model reads email
            let s = LanguageModelSession(instructions: instructions)
            let out = try await Assistant.retrying {
                try await s.respond(to: prompt(m, limit: careful ? 7000 : 3000), schema: schema, options: GenerationOptions(sampling: .greedy)).content
            }
            list = candidates(out)
            if careful { for i in list.indices { list[i] = try await review(list[i], m) } }
        }
        return list.compactMap { c in
            guard !c.title.isEmpty, let t = check(c, in: m) else { return nil }
            return FoundEvent(title: String(c.title.prefix(80)), start: t.start, end: t.end, allDay: t.allDay, location: c.location,
                              from: m.from, fromName: m.fromName, subject: m.subject, messageID: m.messageID, careful: careful)
        }
    }

    /// Careful senders: a second, separate look at each event against the email.
    @available(macOS 26, *)
    static func review(_ c: Candidate, _ m: MailMessage) async throws -> Candidate {
        guard let reviewSchema else { return c }
        let s = LanguageModelSession(instructions: "You check an event someone took from an email. Compare it with the email word by word, and work out weekdays from the day the email was sent.")
        let ask = prompt(m, limit: 7000) + "\n\nThe event taken from it: \(c.title), on \(c.date)\(c.start.isEmpty ? "" : " at \(c.start)"). Is it right? Give the correct day and start time."
        let v = try await Assistant.retrying { try await s.respond(to: ask, schema: reviewSchema, options: GenerationOptions(sampling: .greedy)).content }
        if (try? v.value(Bool.self, forProperty: "real")) == false { var x = c; x.title = ""; return x }
        var x = c
        if let d = try? v.value(String.self, forProperty: "date"), day(d) != nil { x.date = d }
        if let t = try? v.value(String.self, forProperty: "start") { x.start = t.trimmingCharacters(in: .whitespaces) }
        return x
    }

    static func json(_ raw: String) -> [Candidate] {
        var t = raw
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        guard let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let events = o["events"] as? [[String: Any]] else { return [] }
        return events.map { e in
            func s(_ k: String) -> String { (e[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            return Candidate(title: s("title"), date: s("date"), start: s("start"), end: s("end"), location: s("location"), evidence: s("evidence"))
        }
    }

    static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    static func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    /// The quote really comes from the email (most of its words are there).
    static func grounded(_ quote: String, in text: String) -> Bool {
        let q = words(quote).filter { $0.count > 1 }, t = Set(words(text))
        guard q.count >= 2 else { return false }
        return Double(q.filter(t.contains).count) / Double(q.count) >= 0.7
    }

    /// The email says this time somewhere: 7pm, 7:30 PM, 19:30, at 7, noon, seven o'clock…
    static func mentionsTime(_ h: Int, _ m: Int, in text: String) -> Bool {
        let h12 = h % 12 == 0 ? 12 : h % 12, mm = String(format: "%02d", m)
        let names = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        var pats = m == 0
            ? [#"\b\#(h12)(:00)?\s*(a\.?m\.?|p\.?m\.?|o'?clock)"#, #"\b\#(h)[:.]00(?!\d)"#, #"\bat\s+\#(h12)\b"#, #"\b\#(h12)\s*[-–]\s*\d{1,2}(:\d\d)?\s*(a\.?m|p\.?m)"#,
               #"\b\#(names[h12])\s*(o'?clock|in the|at night|pm|am|p\.m|a\.m)"#, #"\bat\s+\#(names[h12])\b"#]
            : [#"\b\#(h12)[:.]\#(mm)(?!\d)"#, #"\b\#(h)[:.]\#(mm)(?!\d)"#]
        if h == 12 && m == 0 { pats.append(#"\bnoon\b|\bmidday\b"#) }
        if h == 0 && m == 0 { pats.append(#"\bmidnight\b"#) }
        let t = text.lowercased()
        return pats.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The day the quote means, worked out from when the email was sent (the small model often slips on weekdays).
    static func resolvedDay(_ quote: String, sent: Date, model: Date?) -> Date? {
        let cal = Calendar.current, q = quote.lowercased(), sentDay = cal.startOfDay(for: sent)
        // A written date ("October 3", "10/3") beats everything; the year is the next one that isn't in the past.
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           q.range(of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b|\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil,
           let d = det.firstMatch(in: quote, range: NSRange(quote.startIndex..., in: quote))?.date {
            var c = cal.dateComponents([.month, .day], from: d)
            c.year = cal.component(.year, from: sentDay)
            if let y = cal.date(from: c), y < cal.date(byAdding: .day, value: -1, to: sentDay)! { c.year! += 1 }
            return cal.date(from: c).map(cal.startOfDay)
        }
        if q.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil { return cal.date(byAdding: .day, value: 1, to: sentDay) }
        if q.range(of: #"\b(today|tonight|this (morning|afternoon|evening))\b"#, options: .regularExpression) != nil { return sentDay }
        let named = weekdays.enumerated().filter { q.range(of: #"\b\#($0.element)\b"#, options: .regularExpression) != nil }
        if named.count == 1 {
            let want = named[0].offset + 1   // Calendar weekday: Sunday = 1
            if let m = model, cal.component(.weekday, from: m) == want, m >= sentDay, m < cal.date(byAdding: .day, value: 14, to: sentDay)! { return m }
            let ahead = (want - cal.component(.weekday, from: sentDay) + 7) % 7
            var d = cal.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: sentDay)!
            if q.contains("next \(named[0].element)"), ahead != 0, ahead < 7, cal.dateComponents([.weekOfYear], from: sentDay, to: d).weekOfYear == 0,
               cal.component(.weekOfYear, from: d) == cal.component(.weekOfYear, from: sentDay) { d = cal.date(byAdding: .day, value: 7, to: d)! }
            return d
        }
        return model
    }

    /// A day, date or time is named ("Thursday", "Oct 3", "10/3", "tomorrow", "7:30pm"), not just "next season".
    static let whenPattern = #"\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday|tomorrow|today|tonight|noon|midnight)\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b|\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\b\d{1,2}/\d{1,2}\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}(:\d\d)?\s*(am|pm|a\.m|p\.m)|\b\d{1,2}:\d\d\b|this (morning|afternoon|evening)"#
    /// …and about the past: "last Saturday", "yesterday", "two weeks ago".
    static let pastPattern = #"\b(last|past|previous)\s+(week|weekend|month|year|night|time|sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b|\byesterday\b|\bago\b"#

    /// Keeps only what the email supports, as calendar-ready times; nil drops the event.
    static func check(_ c: Candidate, in m: MailMessage, now: Date = Date()) -> (start: Date, end: Date, allDay: Bool)? {
        let cal = Calendar.current, text = m.subject + "\n" + m.text, q = c.evidence.lowercased()
        guard grounded(c.evidence, in: text) else { return nil }   // it must quote the email, not imagine it
        guard q.range(of: whenPattern, options: .regularExpression) != nil, q.range(of: pastPattern, options: .regularExpression) == nil else { return nil }
        guard let day = resolvedDay(c.evidence, sent: m.date, model: day(c.date)) else { return nil }
        let sentDay = cal.startOfDay(for: m.date)
        guard day >= cal.date(byAdding: .day, value: -1, to: sentDay)!, day <= cal.date(byAdding: .month, value: 18, to: now)! else { return nil }
        func hm(_ s: String) -> (Int, Int)? {
            let p = s.split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let mi = Int(p[1]), (0..<24).contains(h), (0..<60).contains(mi) else { return nil }
            return (h, mi)
        }
        if let (h, mi) = hm(c.start), mentionsTime(h, mi, in: text) {
            let start = cal.date(bySettingHour: h, minute: mi, second: 0, of: day)!
            var end = hm(c.end).flatMap { e in mentionsTime(e.0, e.1, in: text) ? cal.date(bySettingHour: e.0, minute: e.1, second: 0, of: day) : nil } ?? start.addingTimeInterval(3600)
            if end <= start { end = start.addingTimeInterval(3600) }
            return end > now ? (start, end, false) : nil
        }
        // No time the email backs up: an all-day event on that day.
        let end = cal.date(byAdding: .day, value: 1, to: day)!
        return end > now ? (day, end, true) : nil
    }

    /// Something with about this title is already on a calendar around then (added by hand, or from an invitation).
    static func alreadyOnCalendar(_ f: FoundEvent, events: [(title: String, start: Date, allDay: Bool)]) -> Bool {
        let want = Set(words(f.title).filter { $0.count > 2 })
        return events.contains { e in
            guard abs(e.start.timeIntervalSince(f.start)) < (f.allDay || e.allDay ? 86400 : 1800) else { return false }
            let have = Set(words(e.title).filter { $0.count > 2 })
            return !want.isEmpty && !have.isEmpty && Double(want.intersection(have).count) / Double(min(want.count, have.count)) >= 0.5
        }
    }
}
