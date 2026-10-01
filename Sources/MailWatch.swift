import AppKit
import SwiftUI
import EventKit
import FoundationModels

// MARK: - Checks email every 15 minutes and puts the events it finds on the calendar (or asks first)

@MainActor final class MailWatch: ObservableObject {
    static let shared = MailWatch()
    nonisolated static let scanKey = "mail.scan", autoKey = "mail.auto", calendarKey = "mail.calendar", skipBulkKey = "mail.skipBulk", cloudKey = "mail.cloud"
    nonisolated static let appleSeenKey = "mail.appleSeen"   // Apple Mail accounts seen so far (for the per-account switches)
    static let maxReads = 12                     // emails the model reads per check; the rest wait for the next one

    @Published private(set) var added: [FoundEvent] = []
    @Published private(set) var suggestions: [FoundEvent] = []
    @Published private(set) var checking = false
    @Published private(set) var status: String?
    @Published private(set) var lastRun: Date?

    /// Self-test: record events instead of saving them, and list which emails the model read.
    static var dryRun = false
    private(set) var dryAdded: [FoundEvent] = []
    private(set) var readLog: [String] = []

    private var seen: [String] = []
    private var seenSet = Set<String>()
    private var timer: Timer?
    private var dir: URL { Prefs.supportDir }

    private struct Saved: Codable { var added: [FoundEvent]; var suggestions: [FoundEvent] }

    init() {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("mail-events.json")), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            added = s.added; suggestions = s.suggestions
        }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("mail-seen.json")), let s = try? JSONDecoder().decode([String].self, from: d) {
            seen = s; seenSet = Set(s)
        }
    }

    private func save() {
        guard !Self.dryRun else { return }
        if let d = try? JSONEncoder().encode(Saved(added: added, suggestions: suggestions)) { try? d.write(to: dir.appendingPathComponent("mail-events.json"), options: .atomic) }
        if let d = try? JSONEncoder().encode(seen) { try? d.write(to: dir.appendingPathComponent("mail-seen.json"), options: .atomic) }
    }

    private func markSeen(_ key: String) {
        guard !key.isEmpty, seenSet.insert(key).inserted else { return }
        seen.append(key)
        if seen.count > 3000 { seenSet.subtract(seen.prefix(seen.count - 3000)); seen.removeFirst(seen.count - 3000) }
    }

    var enabled: Bool { Prefs.bool(Self.scanKey) && (MailAccounts.shared.accounts.contains(where: \.read) || Prefs.bool(AppleMailReader.key)) }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in Task { @MainActor in await MailWatch.shared.scan() } }.tolerant(0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { Task { @MainActor in await MailWatch.shared.scan() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { @MainActor in await MailWatch.shared.scan() } }
        }
    }

    /// Reads new email from every account that's switched on, then finds its events.
    func scan(force: Bool = false) async {
        guard !checking, force || enabled else { return }
        guard CalendarService.shared.authorized else { status = "Connect your calendar so Onyx can add events."; return }
        checking = true; status = "Checking your email…"
        defer { checking = false; lastRun = Date() }
        var messages: [MailMessage] = [], problems: [String] = []
        for a0 in MailAccounts.shared.accounts where a0.read {
            var a = a0
            if let pw = MailAccounts.password(a) {
                do { messages += try await MailAccounts.fetchNew(&a, password: pw); a.lastError = nil }
                catch { a.lastError = error.localizedDescription; problems.append(a.address) }
            } else { a.lastError = "Sign in again: the password is missing."; problems.append(a.address) }
            a.lastChecked = Date()
            MailAccounts.shared.update(a)
        }
        if Prefs.bool(AppleMailReader.key) {
            let r = await AppleMailReader.recent()
            if !r.accounts.isEmpty { UserDefaults.standard.set(Array(Set(Prefs.list(Self.appleSeenKey) + r.accounts)).sorted().joined(separator: ","), forKey: Self.appleSeenKey) }
            let skip = Set(Prefs.list(AppleMailReader.skipKey))
            messages += r.messages.filter { !skip.contains($0.account) }
            if let e = r.error { problems.append(e) }
        }
        let found = await process(messages, never: MailRules.never, careful: MailRules.careful, auto: Prefs.bool(Self.autoKey))
        let what = found.isEmpty ? "no new events" : "\(found.count) new event\(found.count == 1 ? "" : "s")"
        status = problems.isEmpty ? "Checked just now: \(what)." : "Checked: \(what). Couldn't read \(problems.joined(separator: ", "))."
    }

    /// Reads each new email (never one from a sender on the never list) and adds or suggests the events it finds.
    @discardableResult
    func process(_ messages: [MailMessage], never: [String], careful: [String], auto: Bool) async -> [FoundEvent] {
        var out: [FoundEvent] = [], reads = 0
        let skipBulk = Prefs.bool(Self.skipBulkKey), cloud = CloudAI.active && Prefs.bool(Self.cloudKey)
        let modelReady: Bool = {
            if cloud { return true }
            if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
            return false   // macOS 15: only a cloud model reads email
        }()
        emails: for m in messages.sorted(by: { $0.date < $1.date }) where !seenSet.contains(m.key) {
            if MailRules.matches(never, address: m.from, name: m.fromName) { markSeen(m.key); continue }   // not even opened
            let isCareful = MailRules.matches(careful, address: m.from, name: m.fromName)
            var found: [FoundEvent] = []
            // An invitation says exactly when: no model needed.
            for inv in m.invites {
                for e in ICS.events(inv) where !e.cancelled {
                    guard let s = e.start, let end = e.end, end > Date() else { continue }
                    found.append(FoundEvent(title: e.title.isEmpty ? m.subject : e.title, start: s, end: end, allDay: e.allDay, location: e.location,
                                            from: m.from, fromName: m.fromName, subject: m.subject, messageID: m.messageID, careful: isCareful))
                }
            }
            let worthReading = isCareful || ((!skipBulk || !m.bulk) && MailEventFinder.mentionsWhen(m.subject + "\n" + m.text))
            if m.invites.isEmpty, worthReading, modelReady {
                if reads >= Self.maxReads { break emails }   // the rest stay unread until the next check
                reads += 1
                readLog.append(m.subject)
                do { found += try await MailEventFinder.find(in: m, careful: isCareful, cloud: cloud) }
                catch let e where Assistant.busy(e) { break emails }   // busy: try again next time
                catch {}
            }
            markSeen(m.key)
            for var f in found where !duplicate(f) {
                if auto || Self.dryRun { add(&f) } else { suggestions.append(f) }
                out.append(f)
            }
        }
        save()
        announce(out, auto: auto)
        return out
    }

    private func duplicate(_ f: FoundEvent) -> Bool {
        let key = CalendarAccounts.key(title: f.title, start: f.start, end: f.end, allDay: f.allDay)
        if (added + suggestions + dryAdded).contains(where: { CalendarAccounts.key(title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay) == key }) { return true }
        guard !Self.dryRun else { return false }
        let store = CalendarService.shared.store
        let near = store.events(matching: store.predicateForEvents(withStart: f.start.addingTimeInterval(-86400), end: f.start.addingTimeInterval(86400), calendars: nil))
        return MailEventFinder.alreadyOnCalendar(f, events: near.map { ($0.title ?? "", $0.startDate, $0.isAllDay) })
    }

    static func target(_ store: EKEventStore) -> EKCalendar? {
        store.calendar(withIdentifier: Prefs.string(calendarKey)).flatMap { $0.allowsContentModifications ? $0 : nil } ?? store.defaultCalendarForNewEvents
    }

    private func add(_ f: inout FoundEvent) {
        if Self.dryRun { f.eventID = "dry-run"; dryAdded.append(f); return }
        let store = CalendarService.shared.store
        let e = EKEvent(eventStore: store)
        e.title = f.title; e.startDate = f.start; e.endDate = f.end; e.isAllDay = f.allDay
        if !f.location.isEmpty { e.location = f.location }
        e.notes = "Added by Onyx from an email from \(f.sender): “\(f.subject)”"
        if !f.messageID.isEmpty, let id = f.messageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) {
            e.url = URL(string: "message:%3C\(id)%3E")   // opens the email in Mail, if it's there
        }
        e.calendar = Self.target(store)
        do {
            try store.save(e, span: .thisEvent)
            f.eventID = e.eventIdentifier
            added.insert(f, at: 0)
            if added.count > 40 { added.removeLast(added.count - 40) }
        } catch { status = "Couldn't add “\(f.title)”: \(error.localizedDescription)" }
    }

    private func announce(_ found: [FoundEvent], auto: Bool) {
        guard !found.isEmpty, !Self.dryRun else { return }
        let text: String
        if let c = found.first(where: \.careful) { text = (auto ? "Added “\(c.title)”" : "Found “\(c.title)”") + " from \(c.sender)" }
        else if found.count == 1 { text = (auto ? "Added “\(found[0].title)”" : "Found “\(found[0].title)”") + " from your email" }
        else { text = auto ? "Added \(found.count) events from your email" : "Found \(found.count) events in your email" }
        NotchModel.shared.flash(.message(icon: "calendar.badge.plus", text: text, tint: .red), for: 4)
    }

    func accept(_ f: FoundEvent) {
        suggestions.removeAll { $0.id == f.id }
        var x = f; add(&x); save()
    }
    func ignore(_ f: FoundEvent) { suggestions.removeAll { $0.id == f.id }; save() }

    /// Takes an added event back off the calendar.
    func undo(_ f: FoundEvent) {
        let store = CalendarService.shared.store
        if let id = f.eventID, let e = store.event(withIdentifier: id) { try? store.remove(e, span: .thisEvent) }
        added.removeAll { $0.id == f.id }; save()
    }

    func isFromEmail(_ eventID: String?) -> Bool { eventID.map { id in added.contains { $0.eventID == id } } ?? false }
}

// MARK: - Settings › Calendar & Mail

struct CalendarMailSettings: View {
    @State private var addingMail = false

    var body: some View {
        Form {
            CalendarAccountsSection()
            MailAccountsSection(adding: $addingMail)
            MailEventsSection()
            MailRuleList(title: "Never read email from", key: MailRules.neverKey, placeholder: "name@example.com, @company.com or a name",
                         footer: "Onyx doesn't open these emails at all. Use an address, a whole domain (@company.com) or a name.")
            MailRuleList(title: "Read carefully", key: MailRules.carefulKey, placeholder: "Your teacher, coach or boss",
                         footer: "Emails from these people are always read, even newsletters or ones without an obvious date. Onyx reads more of each one, checks every event a second time, and tells you in the notch when it adds one.")
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingMail) { MailSignInSheet() }
    }
}

struct MailAccountsSection: View {
    @Binding var adding: Bool
    @ObservedObject var accounts = MailAccounts.shared
    @AppStorage(AppleMailReader.key) private var appleMail = false
    @AppStorage(AppleMailReader.skipKey) private var appleSkip = ""
    @AppStorage(MailWatch.appleSeenKey) private var appleSeen = ""

    var body: some View {
        Section {
            ForEach(accounts.accounts) { a in
                HStack(spacing: 8) {
                    Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.address)
                        if let e = a.lastError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                        else if let d = a.lastChecked { Text("Checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                        else { Text("Not checked yet").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Toggle("Read", isOn: Binding(get: { a.read }, set: { var b = a; b.read = $0; accounts.update(b) }))
                        .toggleStyle(.switch).controlSize(.small).help("Let Onyx read this account")
                    Button { accounts.remove(a) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain).help("Sign out and forget this account")
                }
            }
            Button("Add Email Account…") { adding = true }
            Toggle("Also read the accounts in Apple Mail", isOn: $appleMail)
            if appleMail {
                let seen = appleSeen.split(separator: ",").map(String.init)
                ForEach(seen, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { !appleSkip.split(separator: ",").map(String.init).contains(name) }, set: { on in
                        var s = appleSkip.split(separator: ",").map(String.init).filter { $0 != name }
                        if !on { s.append(name) }
                        appleSkip = s.joined(separator: ",")
                    })).padding(.leading, 12)
                }
                Text("Reads the inboxes of the accounts in the Mail app while it's open, including Outlook and school accounts that don't allow app passwords. macOS asks once to let Onyx read Mail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Email") } footer: {
            Text("Sign in to as many accounts as you like. Gmail, iCloud and Yahoo need an app password, which you can make in a minute. Your passwords stay in the macOS Keychain.")
        }
    }
}

struct MailSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var username = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an email account").font(.title3.weight(.semibold))
            Text("Onyx reads your inbox to find events. It never sends, deletes, moves or marks anything as read.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Email address", text: $address).textFieldStyle(.roundedBorder).textContentType(.emailAddress)
            SecureField("App password", text: $password).textFieldStyle(.roundedBorder)
            if MailAccounts.isMicrosoft(address) {
                Text("Outlook and Hotmail don't allow app passwords for reading mail. Add the account to the Mail app instead, then turn on “Also read the accounts in Apple Mail”.")
                    .font(.caption).foregroundStyle(.orange)
            } else if address.contains("@"), let help = MailAccounts.passwordHelp(for: address) {
                HStack(spacing: 4) {
                    Text("Use an app password, not your normal one.").font(.caption).foregroundStyle(.secondary)
                    Link(help.label, destination: help.url).font(.caption)
                }
            }
            DisclosureGroup("Server settings (optional)") {
                VStack(spacing: 6) {
                    TextField("IMAP server", text: $host, prompt: Text("Found automatically"))
                    TextField("Port", text: $port)
                    TextField("User name", text: $username, prompt: Text("Your email address"))
                }.textFieldStyle(.roundedBorder).padding(.top, 4)
            }.font(.callout)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await signIn() } } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Sign In") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || address.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        // Google shows app passwords in groups of four ("abcd efgh ijkl mnop"); the spaces aren't part of it.
        let pw = password.range(of: #"^([a-z]{4} ){3}[a-z]{4}$"#, options: .regularExpression) != nil ? password.replacingOccurrences(of: " ", with: "") : password
        switch await MailAccounts.signIn(address: address, password: pw, host: host, port: Int(port) ?? 993, username: username) {
        case .success(let a):
            MailAccounts.shared.add(a, password: pw)
            if !Prefs.bool(MailWatch.scanKey) { UserDefaults.standard.set(true, forKey: MailWatch.scanKey) }
            dismiss()
            Task { await MailWatch.shared.scan(force: true) }
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

struct MailEventsSection: View {
    @ObservedObject var watch = MailWatch.shared
    @ObservedObject var cal = CalendarService.shared
    @AppStorage(MailWatch.scanKey) private var scan = true
    @AppStorage(MailWatch.autoKey) private var auto = true
    @AppStorage(MailWatch.calendarKey) private var target = ""
    @AppStorage(MailWatch.skipBulkKey) private var skipBulk = true
    @AppStorage(MailWatch.cloudKey) private var cloud = false

    var body: some View {
        Section {
            Toggle("Find events in my email", isOn: $scan)
            if scan && !OS.mayHaveAppleAI && !CloudAI.active {
                Text("Reading emails for events needs Apple's on-device AI (\(OS.noAppleAIReason)) or a cloud model. Pick one in Settings › Privacy › AI. Calendar invitations still come through.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if scan {
                Picker("When Onyx finds one", selection: $auto) {
                    Text("Add it to my calendar").tag(true)
                    Text("Ask me first").tag(false)
                }
                if cal.authorized {
                    Picker("Add events to", selection: $target) {
                        Text("Default calendar").tag("")
                        ForEach(CalendarAccounts.writable(cal.store), id: \.calendarIdentifier) { c in
                            Text("\(c.title) · \(c.source?.title ?? "")").tag(c.calendarIdentifier)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Skip newsletters and promotions", isOn: $skipBulk)
                    Text("Emails with an unsubscribe link. Add a sender to Read carefully to always read theirs.").font(.caption).foregroundStyle(.secondary)
                }
                if CloudAI.active {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Let \(CloudAI.provider.short) read emails too", isOn: $cloud)
                        Text("More accurate, but your emails are sent to \(CloudAI.provider.short). Off: Apple's on-device model reads them on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Check Now") { Task { await watch.scan(force: true) } }.disabled(watch.checking)
                    if watch.checking { ProgressView().controlSize(.small) }
                    if let s = watch.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                ForEach(watch.suggestions) { f in
                    FoundEventRow(f: f) {
                        Button("Add") { watch.accept(f) }.controlSize(.small)
                        Button("Ignore") { watch.ignore(f) }.controlSize(.small)
                    }
                }
                if !watch.added.isEmpty {
                    DisclosureGroup("Added from email (\(watch.added.count))") {
                        ForEach(watch.added.prefix(20)) { f in
                            FoundEventRow(f: f) { Button("Undo") { watch.undo(f) }.controlSize(.small) }
                        }
                    }
                }
            }
        } header: { Text("Turn emails into events") } footer: {
            Text("Calendar invitations are added exactly as sent. For everything else Onyx asks Apple's on-device model, then checks the day and time against the email's own words before anything reaches your calendar. Emails are never changed or marked as read.")
        }
    }
}

struct FoundEventRow<Buttons: View>: View {
    let f: FoundEvent
    @ViewBuilder let buttons: () -> Buttons
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: f.careful ? "star.circle.fill" : "envelope.circle.fill").foregroundStyle(f.careful ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title).lineLimit(1)
                Text(f.allDay ? f.start.formatted(.dateTime.weekday().month().day()) : f.start.formatted(.dateTime.weekday().month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
                Text("From \(f.sender) · “\(f.subject)”").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            buttons()
        }
    }
}

struct MailRuleList: View {
    let title: String, key: String, placeholder: String, footer: String
    @State private var items: [String] = []
    @State private var adding = ""

    var body: some View {
        Section {
            ForEach(items, id: \.self) { r in
                HStack {
                    Text(r)
                    Spacer()
                    Button { items.removeAll { $0 == r }; MailRules.set(key, items) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: $adding).onSubmit(add)
                Button("Add", action: add).disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text(title) } footer: { Text(footer) }
        .onAppear { items = MailRules.list(key) }
    }

    private func add() {
        let new = adding.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !items.contains($0) }
        guard !new.isEmpty else { return }
        items += new; MailRules.set(key, items); adding = ""
    }
}
