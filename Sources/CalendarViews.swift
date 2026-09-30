import AppKit
import SwiftUI
import EventKit

// MARK: - The whole calendar: the Home calendar box, opened up over the Home tab.
// Pick any day, add events, see an event's details, open it in Calendar or delete it.

struct FullCalendarView: View {
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var mail = MailWatch.shared
    @State private var shown: String?        // the event showing its details
    @State private var confirming: String?   // the event asking "Delete?"
    @State private var adding = false
    @State private var title = ""
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var minutes = 60
    @State private var problem: String?

    private var isToday: Bool { Calendar.current.isDateInToday(cal.selectedDay) }
    private var spring: Animation { Motion.reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86) }

    var body: some View {
        Card {
            GeometryReader { g in
                // The month fills the height: 6 weeks of rows under the month name and the weekday letters.
                let cell = min(30, max(16, floor((g.size.height - 48) / 6) - 3))
                HStack(alignment: .top, spacing: 14) {
                    MonthGrid(cell: cell).frame(width: cell * 7 + 18)
                    Divider()
                    day
                }
            }
        }
        .onChange(of: cal.selectedDay) { _, _ in shown = nil; confirming = nil; problem = nil }
    }

    private var day: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isToday ? "TODAY" : cal.selectedDay.formatted(.dateTime.year())).font(.system(size: 9, weight: .bold)).foregroundStyle(isToday ? .red : .secondary)
                    Text(cal.selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !isToday { Button("Today") { cal.select(Date()) }.controlSize(.small) }
                Button { withAnimation(spring) { adding.toggle() } } label: {
                    Image(systemName: adding ? "minus.circle.fill" : "plus.circle.fill").font(.system(size: 16))
                }.buttonStyle(.plain).foregroundStyle(.red).help(adding ? "Cancel" : "Add an event").accessibilityLabel(adding ? "Cancel" : "Add an event")
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.primary.opacity(0.5))
                }.buttonStyle(.plain).help("Back to Home").accessibilityLabel("Back to Home")
            }
            if adding { addBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            if !mail.suggestions.isEmpty {
                Button { SettingsView.open(.accounts) } label: {
                    Label("\(mail.suggestions.count) from email to review", systemImage: "envelope.badge").font(.system(size: 10.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.red)
            }
            if cal.dayEvents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No events").font(.system(size: 12, weight: .medium))
                    Text("Press + to add one, or pick another day.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(cal.dayEvents, id: \.self) { e in eventRow(e) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Adding

    private var addBar: some View {
        HStack(spacing: 6) {
            TextField("New event on \(cal.selectedDay.formatted(.dateTime.month(.abbreviated).day()))", text: $title)
                .textFieldStyle(.roundedBorder).onSubmit(add)
            if minutes > 0 {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field).fixedSize()
            }
            Picker("Length", selection: $minutes) {
                Text("30 min").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("All day").tag(0)
            }.labelsHidden().fixedSize()
            Button("Add", action: add).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard let target = cal.store.defaultCalendarForNewEvents else { problem = "There's no calendar to add to. Pick a default one in the Calendar app."; return }
        let c = Calendar.current, e = EKEvent(eventStore: cal.store)
        e.title = t; e.calendar = target
        if minutes == 0 {
            e.isAllDay = true; e.startDate = cal.selectedDay; e.endDate = c.date(byAdding: .day, value: 1, to: cal.selectedDay) ?? cal.selectedDay
        } else {
            let hm = c.dateComponents([.hour, .minute], from: time)
            let start = c.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: cal.selectedDay) ?? cal.selectedDay
            e.startDate = start; e.endDate = start.addingTimeInterval(Double(minutes) * 60)
        }
        do {
            try cal.store.save(e, span: .thisEvent)
            title = ""; problem = nil
            withAnimation(spring) { adding = false }
            cal.reload()
        } catch { problem = "Couldn't add it: \(error.localizedDescription)" }
    }

    // MARK: Events

    private func eventRow(_ e: EKEvent) -> some View {
        let id = e.eventIdentifier ?? "\(e.hash)"
        let open = shown == id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title ?? "").font(.system(size: 11.5, weight: .medium)).lineLimit(open ? 3 : 1)
                    Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let more = cal.copies[e.eventIdentifier ?? ""], !more.isEmpty {   // also on these accounts
                    HStack(spacing: 2) { ForEach(more.indices, id: \.self) { Circle().fill(Color(nsColor: more[$0])).frame(width: 5, height: 5) } }.padding(.top, 4)
                }
                if mail.isFromEmail(e.eventIdentifier) {
                    Image(systemName: "envelope.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(.top, 3).help("Added from an email")
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0)).padding(.top, 4)
            }
            if open { details(e, id: id).transition(.opacity) }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(Color.primary.opacity(open ? 0.07 : 0.001), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(spring) { shown = open ? nil : id; confirming = nil } }
        .contextMenu {
            if e.calendar.source != nil { Button("Open in Calendar") { openInCalendar(e) } }
            if (e.calendar.source != nil && e.calendar.allowsContentModifications) { Button("Delete Event…", role: .destructive) { withAnimation(spring) { shown = id; confirming = id } } }
        }
    }

    private func details(_ e: EKEvent, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let loc = e.location, !loc.isEmpty { Label(loc, systemImage: "mappin.and.ellipse").lineLimit(2) }
            Label("\(e.calendar.title) · \(e.calendar.source?.title ?? "Linked, read-only")", systemImage: "calendar").lineLimit(1)
            if e.hasRecurrenceRules { Label("Repeats", systemImage: "repeat") }
            if let n = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { Text(n).lineLimit(3) }
            if confirming == id {
                HStack(spacing: 6) {
                    Text(e.hasRecurrenceRules ? "Delete just this one?" : "Delete this event?").foregroundStyle(.primary)
                    Button("Delete", role: .destructive) { delete(e) }
                    Button("Cancel") { withAnimation(spring) { confirming = nil } }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    if e.calendar.source != nil { Button("Open in Calendar") { openInCalendar(e) } }
                    if (e.calendar.source != nil && e.calendar.allowsContentModifications) { Button("Delete…") { withAnimation(spring) { confirming = id } } }
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary)
        .padding(.leading, 9)
    }

    private func delete(_ e: EKEvent) {
        do {
            try cal.store.remove(e, span: .thisEvent)   // a repeating event: only this one
            withAnimation(spring) { shown = nil; confirming = nil }
            cal.reload()
        } catch { problem = "Couldn't delete it: \(error.localizedDescription)" }
    }

    private func openInCalendar(_ e: EKEvent) {
        if let id = e.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let u = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(u) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.open(app) }
    }

    private func close() {
        cal.select(Date())
        withAnimation(spring) { HomeLayout.shared.fullCalendar = false }
    }
}
