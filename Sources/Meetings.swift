import AppKit
import SwiftUI
import EventKit

// MARK: - Meeting countdown: a video call on your calendar shows up in the notch 2 minutes before, with a Join button

final class MeetingWatch: ObservableObject {
    static let shared = MeetingWatch()
    static let key = "meetingActivity"
    @Published private(set) var next: EKEvent?   // a call starting within 2 minutes, or that started under 5 minutes ago
    private var dismissed = Set<String>()

    func start() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }.tolerant(0.3)
    }

    func check() {
        guard Prefs.bool(Self.key), CalendarService.shared.authorized else { if next != nil { next = nil }; return }
        let now = Date()
        let hit = CalendarService.shared.upcoming.first { e in
            e.meetingURL != nil && !dismissed.contains(Self.id(e))
                && e.startDate.timeIntervalSince(now) <= 120 && now.timeIntervalSince(e.startDate) <= 300
        }
        guard hit.map(Self.id) != next.map(Self.id) else { return }
        if hit != nil && next == nil { NSSound(named: "Tink")?.play() }
        next = hit
    }

    func join() {
        guard let e = next, let u = e.meetingURL else { return }
        NSWorkspace.shared.open(u)
        dismiss()
        NotchController.current?.collapse()
    }

    func dismiss() {
        if let e = next { dismissed.insert(Self.id(e)) }
        next = nil
    }

    static func id(_ e: EKEvent) -> String { (e.eventIdentifier ?? e.title ?? "") + "@\(e.startDate.timeIntervalSince1970)" }

    /// "in 1:42", then "now" once it's started.
    static func countdown(_ e: EKEvent, at now: Date) -> String {
        let s = Int(e.startDate.timeIntervalSince(now).rounded(.up))
        return s > 0 ? "in \(s / 60):" + String(format: "%02d", s % 60) : "now"
    }

    static func service(_ u: URL?) -> String {
        let h = u?.host?.lowercased() ?? ""
        return h.contains("zoom") ? "Zoom" : h.contains("meet.google") ? "Google Meet" : h.contains("teams") ? "Teams" : h.contains("webex") ? "Webex" : "the call"
    }
}

/// In the open notch: the call, its countdown, and Join.
struct MeetingBanner: View {
    @ObservedObject var watch = MeetingWatch.shared
    var body: some View {
        if let e = watch.next {
            HStack(spacing: 10) {
                Image(systemName: "video.fill").foregroundStyle(.green).symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.title ?? "Meeting").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Starts \(MeetingWatch.countdown(e, at: ctx.date)) · \(MeetingWatch.service(e.meetingURL))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                Button("Not now") { watch.dismiss() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Join") { watch.join() }.buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.green.opacity(0.5)))
            .padding(.horizontal, 10).padding(.top, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
