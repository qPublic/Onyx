import AppKit
import SwiftUI

// MARK: - Onyx reminders: set by the AI (or anything else), they ring in the notch when due

struct OnyxReminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var due: Date
}

final class OnyxReminders: ObservableObject {
    static let shared = OnyxReminders()
    @Published private(set) var upcoming: [OnyxReminder] = []
    @Published private(set) var ringing: [OnyxReminder] = []   // due, waiting for Done / Snooze

    private struct Store: Codable { var upcoming: [OnyxReminder]; var ringing: [OnyxReminder] }
    private var file: URL { Prefs.supportDir.appendingPathComponent("reminders.json") }
    private var timer: Timer?
    private var fallback: Timer?

    func start() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Store.self, from: d) {
            upcoming = s.upcoming; ringing = s.ringing
        }
        // Reminders that came due while Onyx was closed or the Mac was asleep ring as soon as we're back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.check() }
        }
        fallback = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }.tolerant()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(); self?.schedule() }
    }

    @discardableResult
    func add(title: String, due: Date) -> OnyxReminder {
        let r = OnyxReminder(title: title, due: due)
        upcoming.append(r)
        upcoming.sort { $0.due < $1.due }
        save(); schedule()
        return r
    }

    /// Cancels upcoming reminders whose title contains `text`; returns what was removed.
    func cancel(matching text: String) -> [OnyxReminder] {
        let q = text.lowercased()
        let gone = upcoming.filter { $0.title.lowercased().contains(q) || q.contains($0.title.lowercased()) }
        upcoming.removeAll { r in gone.contains { $0.id == r.id } }
        save(); schedule()
        return gone
    }
    func remove(_ r: OnyxReminder) { upcoming.removeAll { $0.id == r.id }; save(); schedule() }

    func done(_ r: OnyxReminder) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { ringing.removeAll { $0.id == r.id } }
        save()
    }
    func snooze(_ r: OnyxReminder, minutes: Double) {
        done(r)
        add(title: r.title, due: Date().addingTimeInterval(minutes * 60))
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Store(upcoming: upcoming, ringing: ringing)) { try? d.write(to: file, options: .atomic) }
    }

    /// One timer, set for the next reminder (the 30s fallback covers sleep and clock changes).
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard let next = upcoming.first?.due else { return }
        let t = Timer(fire: max(next, Date().addingTimeInterval(0.2)), interval: 0, repeats: false) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        let now = Date().addingTimeInterval(0.5)
        let due = upcoming.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        upcoming.removeAll { $0.due <= now }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { ringing.append(contentsOf: due) }
        save(); schedule()
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: When is it due? Prefer the user's own words over the model's arithmetic.

    static func dueDate(inMinutes: String?, at: String?, request: String, now: Date = Date()) -> Date? {
        let text = request.lowercased()
        // "in 20 minutes", "in 2 hours", "in 90 secs"
        if let m = text.firstMatch(of: #/in\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|h|m)\b/#),
           let n = Double(m.1) {
            let unit = String(m.2)
            let secs = unit.hasPrefix("s") ? n : unit.hasPrefix("h") ? n * 3600 : n * 60
            return now.addingTimeInterval(secs)
        }
        if let m = inMinutes.flatMap(Double.init), m > 0 { return now.addingTimeInterval(m * 60) }
        // "at 5", "tomorrow at 3pm", "on Friday at noon"
        if let d = detect(request, now: now) { return d }
        if let a = at, let d = parseDate(a), d > now { return d }
        return nil
    }

    private static func detect(_ s: String, now: Date) -> Date? {
        let cal = Calendar.current
        var found: Date?, said = ""
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let md = m.date {
            found = md
            said = (Range(m.range, in: s).map { String(s[$0]) } ?? "").lowercased()
        } else if let m = s.lowercased().firstMatch(of: #/\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/#), var h = Int(m.1), h <= 23 {
            // A bare "at 7" / "at 5:30pm", which the date detector skips.
            let ap = m.3.map(String.init)
            if ap == "pm" && h < 12 { h += 12 }
            if ap == "am" && h == 12 { h = 0 }
            found = cal.date(bySettingHour: h, minute: m.2.flatMap { Int($0) } ?? 0, second: 0, of: now)
            if s.lowercased().contains("tomorrow") { found = found.flatMap { cal.date(byAdding: .day, value: 1, to: $0) } }
            said = ap ?? ""
        }
        guard var d = found else { return nil }
        if d > now { return d }
        // "at 5" said at 11am means 5pm, not 5am yesterday; otherwise the next day at that time.
        if cal.isDate(d, inSameDayAs: now), !said.contains("am"), cal.component(.hour, from: d) < 12,
           let pm = cal.date(byAdding: .hour, value: 12, to: d), pm > now { return pm }
        while d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? now.addingTimeInterval(86400) }
        return d
    }
}

// MARK: - Expanded notch: the ringing reminder with Done / Snooze

struct ReminderBanner: View {
    @ObservedObject var reminders = OnyxReminders.shared
    var body: some View {
        if let r = reminders.ringing.first {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill").foregroundStyle(.orange).symbolEffect(.bounce, options: .repeating)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Reminder · \(r.due.formatted(date: .omitted, time: .shortened))"
                         + (reminders.ringing.count > 1 ? " · \(reminders.ringing.count - 1) more" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu("Snooze") {
                    Button("5 minutes") { reminders.snooze(r, minutes: 5) }
                    Button("10 minutes") { reminders.snooze(r, minutes: 10) }
                    Button("30 minutes") { reminders.snooze(r, minutes: 30) }
                    Button("1 hour") { reminders.snooze(r, minutes: 60) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Done") { reminders.done(r) }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
            .padding(10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
