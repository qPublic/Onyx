import AppKit
import SwiftUI
import EventKit

// MARK: - Every calendar account in one calendar. Google accounts (as many as you like), iCloud, Exchange and others are
// signed into once in System Settings › Internet Accounts; macOS keeps them in sync both ways and Onyx reads them all.

enum CalendarAccounts {
    static let hiddenKey = "cal.hidden"   // calendars left out of Onyx's combined calendar (identifiers)

    struct Account: Identifiable {
        let id: String, name: String, kind: String, icon: String
        let calendars: [EKCalendar]
    }

    static func accounts(_ store: EKEventStore) -> [Account] {
        let groups = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.sourceIdentifier ?? "" }
        return groups.compactMap { id, cals -> Account? in
            guard let s = cals.first?.source else { return nil }
            let k = kind(s)
            return Account(id: id, name: s.title, kind: k.name, icon: k.icon,
                           calendars: cals.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
        .sorted { (order($0.kind), $0.name.lowercased()) < (order($1.kind), $1.name.lowercased()) }
    }

    static func kind(_ s: EKSource) -> (name: String, icon: String) {
        switch s.sourceType {
        case .calDAV where s.title.lowercased() == "icloud": ("iCloud", "icloud")
        case .calDAV: (s.title.lowercased().contains("google") || s.title.contains("@") ? "Google or online account" : "Online account", "person.crop.circle")
        case .exchange: ("Exchange", "building.2")
        case .local: ("On My Mac", "laptopcomputer")
        case .subscribed: ("Subscribed", "dot.radiowaves.up.forward")
        case .birthdays: ("Birthdays", "gift")
        default: ("Calendar", "calendar")
        }
    }
    private static func order(_ kind: String) -> Int {
        ["Google or online account": 0, "Online account": 1, "iCloud": 2, "Exchange": 3, "On My Mac": 4, "Subscribed": 5, "Birthdays": 6][kind] ?? 7
    }

    static var hidden: Set<String> { Set(Prefs.list(hiddenKey)) }

    static func setShown(_ c: EKCalendar, _ on: Bool) {
        var h = hidden
        if on { h.remove(c.calendarIdentifier) } else { h.insert(c.calendarIdentifier) }
        UserDefaults.standard.set(h.sorted().joined(separator: ","), forKey: hiddenKey)
        CalendarService.shared.reload()
    }

    /// The calendars Onyx shows; nil means all of them (nothing hidden).
    static func shown(_ store: EKEventStore) -> [EKCalendar]? {
        let h = hidden
        guard !h.isEmpty else { return nil }
        return store.calendars(for: .event).filter { !h.contains($0.calendarIdentifier) }
    }

    /// Events from every shown calendar. The same event on two accounts (an invite sent to both your school and personal
    /// address) comes back once, with its copies alongside.
    static func merged(_ store: EKEventStore, from start: Date, to end: Date) -> [(first: EKEvent, copies: [EKEvent])] {
        let cals = shown(store)
        // (an empty list would mean "every calendar" to EventKit)
        let own = cals?.isEmpty == true ? [] : store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals))
        return merge(own + LinkedCalendars.shared.events(store, from: start, to: end), key: key)   // plus calendars pasted as links
    }
    static func events(_ store: EKEventStore, from start: Date, to end: Date) -> [EKEvent] { merged(store, from: start, to: end).map(\.first) }

    static func key(_ e: EKEvent) -> String {
        key(title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay)
    }
    static func key(title: String, start: Date, end: Date, allDay: Bool) -> String {
        "\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(Int(start.timeIntervalSince1970 / 60))|\(Int(end.timeIntervalSince1970 / 60))|\(allDay)"
    }

    /// Groups items with the same key, keeping their order; each group's first item stands in for the rest.
    static func merge<T>(_ items: [T], key: (T) -> String) -> [(first: T, copies: [T])] {
        var order: [String] = [], groups: [String: [T]] = [:]
        for i in items {
            let k = key(i)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        return order.map { (groups[$0]![0], Array(groups[$0]!.dropFirst())) }
    }

    /// System Settings › Internet Accounts, where Google (and any other) accounts are added.
    static func addAccount() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }

    /// Calendars new events can go in, for pickers.
    static func writable(_ store: EKEventStore) -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title) }
    }
}

// MARK: - Settings › Calendar & Mail › Calendars

struct CalendarAccountsSection: View {
    @ObservedObject var cal = CalendarService.shared
    @State private var tick = 0
    @AppStorage(CalendarWindow.hideKey) private var hideAfter = 5

    var body: some View {
        let _ = tick   // redraws after a switch; the accounts stay open (rebuilding the list used to close them)
        Section {
            if !cal.authorized {
                HStack {
                    Text("Onyx needs to see your calendars first.")
                    Spacer()
                    Button("Connect Calendar") { cal.requestAccess() }
                }
            } else {
                let accounts = CalendarAccounts.accounts(cal.store)
                if accounts.isEmpty { Text("No calendars yet.").foregroundStyle(.secondary) }
                ForEach(accounts) { a in
                    DisclosureGroup {
                        ForEach(a.calendars, id: \.calendarIdentifier) { c in
                            Toggle(isOn: Binding(get: { !CalendarAccounts.hidden.contains(c.calendarIdentifier) },
                                                 set: { CalendarAccounts.setShown(c, $0); tick += 1 })) {
                                HStack(spacing: 7) {
                                    Circle().fill(Color(nsColor: c.color)).frame(width: 9, height: 9)
                                    Text(c.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: a.icon).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                let n = a.calendars.filter { !CalendarAccounts.hidden.contains($0.calendarIdentifier) }.count
                                Text("\(a.kind) · \(n) of \(a.calendars.count) shown").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            LinkedCalendarRows()
            HStack {
                Button("Add Google Account…") { CalendarAccounts.addAccount() }
                Button("Refresh") { cal.store.refreshSourcesIfNecessary(); cal.reload(); tick += 1; Task { await LinkedCalendars.shared.refreshAll() } }
                Spacer()
            }
            Picker("Close the calendar window after I click away", selection: $hideAfter) {
                Text("Right away").tag(0); Text("After 5 seconds").tag(5); Text("After 15 seconds").tag(15)
                Text("After 30 seconds").tag(30); Text("After 1 minute").tag(60); Text("After 5 minutes").tag(300); Text("Never").tag(-1)
            }
            Text("Clicking the calendar box on Home opens the whole calendar in a window. Go back to it before the time's up and it stays. Pin it (the pin at the top of the window) to keep it open and on top.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sign in to as many Google accounts as you like (and iCloud, Outlook or Exchange) in System Settings › Internet Accounts, with Calendars turned on. Onyx puts every calendar you pick here together in one calendar in the notch, shows an event that's on two accounts only once, and anything you add syncs back to Google. Or paste the link to one calendar above (its share link, or its Secret address in iCal format from its settings): Onyx copies in all its events and updates them every 30 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Calendars") }
    }
}
