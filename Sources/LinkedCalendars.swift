import AppKit
import SwiftUI
import EventKit

// MARK: - Calendars pasted as a link: a Google Calendar (public, or its secret iCal address) or any .ics address.
// Onyx reads the calendar's iCal feed every 30 minutes and shows its events with everything else, read-only.

struct LinkedCalendar: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, link = "", feed = "", name = "", color = "", shown = true
    var synced: Date?, error: String?, count = 0
}

final class LinkedCalendars: ObservableObject, @unchecked Sendable {
    static let shared = LinkedCalendars()
    @Published private(set) var calendars: [LinkedCalendar] = []
    @Published private(set) var busy = false
    /// Self-test: nothing is saved.
    var dryRun = false

    private let lock = NSLock()
    private var parsed: [String: [ICS.Event]] = [:]            // by calendar id
    private var visible: [(id: String, name: String, color: String)] = []   // what the calendar views read, from any thread
    private var timer: Timer?
    private var dir: URL { Prefs.supportDir.appendingPathComponent("Linked Calendars", isDirectory: true) }
    private var listFile: URL { dir.appendingPathComponent("calendars.json") }
    static let palette = ["4285F4", "0B8043", "D50000", "F4511E", "8E24AA", "039BE5", "F6BF26", "33B679"]

    struct Failure: Error { let message: String }

    init() {
        guard let d = try? Data(contentsOf: listFile), let list = try? JSONDecoder().decode([LinkedCalendar].self, from: d) else { return }
        calendars = list
        for c in list { if let t = try? String(contentsOf: dir.appendingPathComponent("\(c.id).ics"), encoding: .utf8) { parsed[c.id] = ICS.events(t) } }
        publish()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in Task { @MainActor in await LinkedCalendars.shared.refreshAll() } }.tolerant(0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Task { @MainActor in await LinkedCalendars.shared.refreshAll() } }
    }

    private func publish() {
        let v = calendars.filter(\.shown).map { ($0.id, $0.name, $0.color) }
        lock.withLock { visible = v }
    }

    private func save() {
        publish()
        guard !dryRun else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(calendars) { try? d.write(to: listFile, options: .atomic) }
    }

    /// Adds a calendar from a pasted link. Returns what went wrong, if anything.
    @MainActor func add(_ link: String) async -> String? {
        if Self.isGooglePage(link) { return Self.googlePageHint }
        guard let feed = Self.feed(for: link) else { return "That doesn't look like a calendar link. Copy it from Google Calendar's settings for that calendar." }
        guard !calendars.contains(where: { $0.feed == feed }) else { return "That calendar is already here." }
        busy = true; defer { busy = false }
        do {
            let text = try await Self.fetch(feed)
            var c = LinkedCalendar(link: link, feed: feed, name: Self.name(text) ?? "Linked calendar", color: Self.palette[calendars.count % Self.palette.count])
            keep(text, for: &c)
            calendars.append(c); save()
            CalendarService.shared.reload()
            return nil
        } catch { return (error as? Failure)?.message ?? error.localizedDescription }
    }

    private func keep(_ text: String, for c: inout LinkedCalendar) {
        let events = ICS.events(text)
        lock.withLock { parsed[c.id] = events }
        if !dryRun {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: dir.appendingPathComponent("\(c.id).ics"), atomically: true, encoding: .utf8)
        }
        c.synced = Date(); c.error = nil; c.count = events.filter { $0.recurrenceID == nil && !$0.cancelled }.count
    }

    @MainActor func refreshAll() async {
        guard !calendars.isEmpty else { return }
        for c in calendars {
            var x = c
            do { keep(try await Self.fetch(c.feed), for: &x) } catch { x.error = (error as? Failure)?.message ?? "Couldn't update it: \(error.localizedDescription)" }
            if let i = calendars.firstIndex(where: { $0.id == c.id }) { calendars[i] = x }
        }
        save()
        CalendarService.shared.reload()
    }

    @MainActor func setShown(_ c: LinkedCalendar, _ on: Bool) {
        guard let i = calendars.firstIndex(where: { $0.id == c.id }) else { return }
        calendars[i].shown = on; save(); CalendarService.shared.reload()
    }

    @MainActor func remove(_ c: LinkedCalendar) {
        calendars.removeAll { $0.id == c.id }
        lock.withLock { parsed[c.id] = nil }
        if !dryRun { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(c.id).ics")) }
        save(); CalendarService.shared.reload()
    }

    /// The shown linked calendars' events between two dates, as unsaved EKEvents for the calendar views. Their calendar
    /// has no source, which marks them read-only.
    func events(_ store: EKEventStore, from: Date, to: Date) -> [EKEvent] {
        let cals: [(id: String, name: String, color: String, events: [ICS.Event])] = lock.withLock {
            visible.compactMap { v in parsed[v.id].map { (v.id, v.name, v.color, $0) } }
        }
        var out: [EKEvent] = []
        for c in cals {
            let cal = EKCalendar(for: .event, eventStore: store)
            cal.title = c.name; cal.cgColor = NSColor(Color(hex: c.color)).cgColor
            for o in Self.occurrences(c.events, from: from, to: to) {
                guard let s = o.start, let e = o.end else { continue }
                let ev = EKEvent(eventStore: store)
                ev.calendar = cal; ev.title = o.title; ev.startDate = s; ev.endDate = e; ev.isAllDay = o.allDay
                if !o.location.isEmpty { ev.location = o.location }
                if !o.notes.isEmpty { ev.notes = o.notes }
                out.append(ev)
            }
        }
        return out
    }

    // MARK: Links and feeds

    /// Any Google Calendar link (its public or secret iCal address, an embed link, a "cid" share link) or any other
    /// .ics / webcal address → the iCal address to read.
    static func feed(for link: String) -> String? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst(9) }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased(), !host.isEmpty, let scheme = c.scheme?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && (host == "127.0.0.1" || host == "localhost")) else { return nil }
        guard host == "calendar.google.com" || host == "www.google.com" else { return host.contains(".") || host == "localhost" || host == "127.0.0.1" ? s : nil }
        if c.path.contains("/ical/") { return s }   // already the iCal address
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let id = q["src"] ?? q["cid"].flatMap(decodeCID), !id.isEmpty,
              let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) else { return nil }
        return "https://calendar.google.com/calendar/ical/\(enc)/public/basic.ics"
    }

    /// Google Calendar's own page (like calendar.google.com/calendar/u/0/r): it only opens for you, signed in, so a link
    /// to it can't bring anything in. Your Google account on your Mac can, with every calendar and its switch.
    static func isGooglePage(_ link: String) -> Bool {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased() else { return false }
        let google = host == "calendar.google.com" || (host == "www.google.com" && c.path.hasPrefix("/calendar"))
        return google && feed(for: link) == nil
    }
    static let googlePageHint = "That's Google Calendar's own page, which only opens for you when you're signed in, so Onyx can't read it from a link. To bring in all your Google calendars, each with its own switch, press Add Google Account…, sign in and keep Calendars turned on. They show up here in a few seconds."

    /// Google's share links carry the calendar's address in base64 ("cid=…").
    static func decodeCID(_ cid: String) -> String? {
        if cid.contains("@") { return cid }
        var b = cid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func fetch(_ feed: String) async throws -> String {
        guard let u = URL(string: feed) else { throw Failure(message: "That link doesn't work.") }
        var r = URLRequest(url: u); r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: d, as: UTF8.self)
        guard code == 200, text.contains("BEGIN:VCALENDAR") else {
            if feed.contains("calendar.google.com") || [401, 403, 404].contains(code) || text.lowercased().contains("<html") {
                throw Failure(message: "That calendar isn't public, so Google won't share it by link. In Google Calendar, open the calendar's Settings › Integrate calendar, copy the Secret address in iCal format and paste that here.")
            }
            throw Failure(message: "Couldn't read that calendar (it answered \(code)).")
        }
        return text
    }

    /// The calendar's name, from X-WR-CALNAME.
    static func name(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.uppercased().hasPrefix("X-WR-CALNAME") {
            if let (_, _, v) = ICS.parse(String(line)), !v.isEmpty { return ICS.unescape(v) }
        }
        return nil
    }

    // MARK: Repeating events

    /// Every occurrence between `from` and `to`: repeats expanded, skipped dates left out, moved and cancelled ones applied.
    static func occurrences(_ events: [ICS.Event], from: Date, to: Date) -> [ICS.Event] {
        var moved: [String: [Date]] = [:]
        for o in events { if let r = o.recurrenceID { moved[o.uid, default: []].append(r) } }
        var out: [ICS.Event] = []
        for e in events where e.recurrenceID == nil && !e.cancelled {
            guard let s = e.start else { continue }
            let length = (e.end ?? s).timeIntervalSince(s)
            for d in starts(e, from: from, to: to) where !(moved[e.uid]?.contains { abs($0.timeIntervalSince(d)) < 1 } ?? false) {
                var x = e; x.start = d; x.end = d.addingTimeInterval(length); out.append(x)
            }
        }
        for o in events where o.recurrenceID != nil && !o.cancelled {
            if let s = o.start, let e = o.end, e > from, s < to { out.append(o) }
        }
        return out
    }

    /// When a (possibly repeating) event starts between `from` and `to`. Repeats are worked out in the event's own
    /// time zone, so a 9:00 class stays at 9:00 across daylight saving.
    static func starts(_ e: ICS.Event, from: Date, to: Date) -> [Date] {
        guard let start = e.start else { return [] }
        let length = (e.end ?? start).timeIntervalSince(start)
        guard !e.rrule.isEmpty else { return start.addingTimeInterval(length) > from && start < to ? [start] : [] }
        var p: [String: String] = [:]
        for part in e.rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { p[kv[0].uppercased()] = String(kv[1]).uppercased() }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = e.allDay ? .current : (e.zone ?? .current); cal.firstWeekday = 2
        let every = max(1, Int(p["INTERVAL"] ?? "") ?? 1)
        let count = Int(p["COUNT"] ?? "")
        let until = p["UNTIL"].flatMap { ICS.date($0, [:]).date }
        let codes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let byDay: [(n: Int?, wd: Int)] = (p["BYDAY"] ?? "").split(separator: ",").compactMap { t in
            guard let wd = codes[String(t.suffix(2))] else { return nil }
            return (Int(t.dropLast(2)), wd)
        }
        let byMonthDay = (p["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        let time = cal.dateComponents([.hour, .minute, .second], from: start)
        func at(_ day: Date) -> Date? { cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) }

        var out: [Date] = [], made = 0
        func take(_ d: Date) -> Bool {   // false once the series ends or passes the window
            if d < start { return true }
            if let until, d > until { return false }
            made += 1
            if let count, made > count { return false }
            if d >= to { return false }
            if d.addingTimeInterval(length) > from, !e.exdates.contains(where: { abs($0.timeIntervalSince(d)) < 1 }) { out.append(d) }
            return true
        }
        switch p["FREQ"] {
        case "DAILY":
            var d = start, n = 0
            while n < 20000, take(d), let next = cal.date(byAdding: .day, value: every, to: d) { d = next; n += 1 }
        case "WEEKLY":
            let days = (byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.map(\.wd)).sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }   // Monday first
            guard var week = cal.dateInterval(of: .weekOfYear, for: start)?.start else { break }
            weeks: for _ in 0..<5000 {
                for wd in days {
                    if let day = cal.date(byAdding: .day, value: (wd + 5) % 7, to: week), let d = at(day), !take(d) { break weeks }
                }
                guard let next = cal.date(byAdding: .weekOfYear, value: every, to: week) else { break }
                week = next
            }
        case "MONTHLY":
            guard var month = cal.dateInterval(of: .month, for: start)?.start else { break }
            months: for _ in 0..<2000 {
                let len = cal.range(of: .day, in: .month, for: month)?.count ?? 30
                var days: [Date] = []
                if !byMonthDay.isEmpty {
                    days = byMonthDay.compactMap { md in
                        let d = md > 0 ? md : len + md + 1
                        return (1...len).contains(d) ? cal.date(byAdding: .day, value: d - 1, to: month) : nil
                    }
                } else if !byDay.isEmpty {
                    let all = (0..<len).compactMap { cal.date(byAdding: .day, value: $0, to: month) }
                    for b in byDay {
                        let same = all.filter { cal.component(.weekday, from: $0) == b.wd }
                        if let n = b.n { if n > 0, n <= same.count { days.append(same[n - 1]) } else if n < 0, -n <= same.count { days.append(same[same.count + n]) } }
                        else { days += same }
                    }
                } else if cal.component(.day, from: start) <= len, let day = cal.date(byAdding: .day, value: cal.component(.day, from: start) - 1, to: month) {
                    days = [day]
                }
                for day in days.sorted() { if let d = at(day), !take(d) { break months } }
                guard let next = cal.date(byAdding: .month, value: every, to: month) else { break }
                month = next
            }
        case "YEARLY":
            var y = 0
            for _ in 0..<500 {
                guard let d = cal.date(byAdding: .year, value: y, to: start) else { break }
                // Feb 29 in a year without one would land on Feb 28: skip that year.
                if cal.component(.day, from: d) == cal.component(.day, from: start), !take(d) { break }
                y += every
            }
        default:
            return start.addingTimeInterval(length) > from && start < to ? [start] : []
        }
        return out
    }

    // MARK: Self-test (log only; ExtrasTest runs it)

    static func selfTest() -> [(String, Bool)] {
        var r: [(String, Bool)] = []
        let secret = "https://calendar.google.com/calendar/ical/abc%40group.calendar.google.com/private-1234/basic.ics"
        let pub = "https://calendar.google.com/calendar/ical/abc%40group.calendar.google.com/public/basic.ics"
        let cid = Data("abc@group.calendar.google.com".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        r.append(("reads every kind of Google Calendar link",
                  feed(for: secret) == secret && feed(for: "https://calendar.google.com/calendar/embed?src=abc%40group.calendar.google.com&ctz=America/Los_Angeles") == pub
                  && feed(for: "https://calendar.google.com/calendar/u/0?cid=\(cid)") == pub && feed(for: "webcal://example.com/school.ics") == "https://example.com/school.ics"
                  && feed(for: "http://evil.example/x.ics") == nil && feed(for: "not a link") == nil))
        r.append(("knows Google Calendar's own page from a calendar's link",
                  isGooglePage("https://calendar.google.com/calendar/u/0/r") && isGooglePage("calendar.google.com/calendar/u/1/r/week/2026/9/30")
                  && !isGooglePage(secret) && !isGooglePage("https://calendar.google.com/calendar/u/0?cid=\(cid)") && !isGooglePage("webcal://example.com/school.ics")))
        let ics = """
        BEGIN:VCALENDAR\r
        X-WR-CALNAME:Lincoln High Bell Schedule\r
        BEGIN:VEVENT\r
        UID:class@x\r
        DTSTART;TZID=America/Los_Angeles:20261005T090000\r
        DTEND;TZID=America/Los_Angeles:20261005T095000\r
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6\r
        EXDATE;TZID=America/Los_Angeles:20261007T090000\r
        SUMMARY:Chemistry\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:class@x\r
        RECURRENCE-ID;TZID=America/Los_Angeles:20261009T090000\r
        DTSTART;TZID=America/Los_Angeles:20261009T100000\r
        DTEND;TZID=America/Los_Angeles:20261009T105000\r
        SUMMARY:Chemistry (moved)\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:club@x\r
        DTSTART;TZID=America/Los_Angeles:20261013T150000\r
        DTEND;TZID=America/Los_Angeles:20261013T160000\r
        RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T235959Z\r
        SUMMARY:Robotics\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:run@x\r
        DTSTART;TZID=America/Los_Angeles:20261029T070000\r
        DTEND;TZID=America/Los_Angeles:20261029T073000\r
        RRULE:FREQ=DAILY;COUNT=6\r
        SUMMARY:Run\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        r.append(("reads the calendar's name", name(ics) == "Lincoln High Bell Schedule"))
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var c = Calendar(identifier: .gregorian); c.timeZone = la
        let f = DateFormatter(); f.timeZone = la; f.dateFormat = "EEE d HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        let all = occurrences(ICS.events(ics), from: c.date(from: DateComponents(year: 2026, month: 10, day: 1))!, to: c.date(from: DateComponents(year: 2027, month: 1, day: 1))!)
        func list(_ t: String) -> [String] { all.filter { $0.title == t }.compactMap { $0.start.map(f.string) }.sorted() }
        let chem = list("Chemistry"), moved = list("Chemistry (moved)"), club = list("Robotics"), run = list("Run")
        r.append(("repeats weekly on Mon, Wed, Fri, skipping a day off and a moved class (\(chem), \(moved))",
                  chem == ["Fri 16 09:00", "Mon 12 09:00", "Mon 5 09:00", "Wed 14 09:00"] && moved == ["Fri 9 10:00"]))
        r.append(("the second Tuesday of each month, until the end date (\(club))", club == ["Tue 10 15:00", "Tue 13 15:00", "Tue 8 15:00"]))
        r.append(("a 7:00 AM run stays at 7:00 AM when the clocks change (\(run))",
                  run.count == 6 && run.allSatisfy { $0.hasSuffix("07:00") }))
        return r
    }
}

// MARK: - Settings › Calendar & Mail: pasted calendars

struct LinkedCalendarRows: View {
    @ObservedObject var linked = LinkedCalendars.shared
    @State private var link = ""
    @State private var error: String?
    @State private var googlePage = false
    @State private var guide = false

    var body: some View {
        ForEach(linked.calendars) { c in
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).frame(width: 18)
                Circle().fill(Color(hex: c.color)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name)
                    if let e = c.error { Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    else { Text("Linked · \(c.count) events\(c.synced.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? "")").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Toggle("Show", isOn: Binding(get: { c.shown }, set: { linked.setShown(c, $0) })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                Button { linked.remove(c) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("Remove this calendar").accessibilityLabel("Remove \(c.name)")
            }
        }
        HStack {
            TextField("Paste a Google Calendar link", text: $link).textFieldStyle(.roundedBorder).onSubmit(add)
            Button("Add", action: add).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || linked.busy)
            if linked.busy { ProgressView().controlSize(.small) }
        }
        Button("How to get a calendar's private link…") { guide = true }
            .buttonStyle(.link).popover(isPresented: $guide, arrowEdge: .trailing) { SecretLinkGuide() }
        if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        if googlePage { Button("Add Google Account…") { CalendarAccounts.addAccount() } }
    }

    private func add() {
        let l = link
        googlePage = LinkedCalendars.isGooglePage(l)
        Task { @MainActor in
            if let e = await linked.add(l) { error = e } else { error = nil; link = "" }
        }
    }
}

// MARK: - How to get a calendar's private link: a picture for each step

struct SecretLinkGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Get a calendar's private link").font(.headline)
                Text("Google calls it the calendar's Secret address in iCal format. Do this on a computer, at calendar.google.com.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                step(1, "In the list on the left, point at the calendar, click ⋮ and choose Settings and sharing.") { menuPicture }
                step(2, "In that calendar's settings, click Integrate calendar.") { navPicture }
                step(3, "Under Secret address in iCal format, click the copy button.") { secretPicture }
                step(4, "Paste it into Onyx, under Calendars, and press Add.") { pastePicture }
                Text("Keep the link to yourself: anyone who has it can see that calendar's events. If a school account doesn't show a secret address, the school has turned it off. Use Add Google Account… instead.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 440, height: 560)
    }

    private func step<P: View>(_ n: Int, _ text: String, @ViewBuilder picture: () -> P) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Circle().fill(Color.accentColor.opacity(0.35)))
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            picture()   // drawn like the web page, with the thing to click outlined
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.12)))
                .environment(\.colorScheme, .light)
                .accessibilityHidden(true)
        }
    }

    private var target: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
    }

    private var menuPicture: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("My calendars").font(.system(size: 10, weight: .semibold))
                calRow("Sam", .blue, false); calRow("School", .green, true); calRow("Family", .orange, false)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Display this only").font(.system(size: 10))
                Text("Hide from list").font(.system(size: 10))
                Text("Settings and sharing").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(target)
                HStack(spacing: 3) { ForEach([Color.red, .orange, .yellow, .green, .blue, .purple], id: \.self) { Circle().fill($0).frame(width: 8, height: 8) } }
            }
            .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
    }

    private func calRow(_ name: String, _ color: Color, _ pointed: Bool) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                .overlay(Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white))
            Text(name).font(.system(size: 10))
            Spacer()
            if pointed { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).background(target) }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(pointed ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private var navPicture: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(["Calendar settings", "Access permissions for events", "Share with specific people", "Event notifications"], id: \.self) { Text($0).font(.system(size: 10)) }
                Text("Integrate calendar").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(target)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach([120, 90, 140, 70], id: \.self) { w in RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.08)).frame(width: CGFloat(w), height: 7) }
            }
            .padding(.top, 4)
        }
    }

    private var secretPicture: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Secret address in iCal format").font(.system(size: 10, weight: .semibold))
            HStack(spacing: 6) {
                Text("••••••••••••••••••••••••••••").font(.system(size: 10, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: "eye").font(.system(size: 10))
                Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).background(target)
            }
            Text("Only share this address with people you trust.").font(.system(size: 9)).foregroundStyle(Color.black.opacity(0.5))
        }
    }

    private var pastePicture: some View {
        HStack(spacing: 6) {
            Text(verbatim: "https://calendar.google.com/calendar/ical/…/basic.ics").font(.system(size: 10)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            Text("Add").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(target)
        }
    }
}
