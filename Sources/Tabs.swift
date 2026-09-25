import SwiftUI
import Combine
import ImageIO
import AVFoundation
import EventKit
import UniformTypeIdentifiers

// MARK: - Home cards (HomeTab lives in HomeLayout.swift)

struct MusicCard: View {
    @ObservedObject var media = MediaController.shared
    @State private var scrub: Double?

    private var sourceIcon: NSImage? {
        guard let p = media.source, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.rawValue) else { return nil }
        return NSWorkspace.shared.icon(forFile: u.path)
    }

    @AppStorage(AP.musicCow) private var cow = false

    var body: some View {
        Card {
            GeometryReader { geo in
                // No cow: centre the player and let the artwork grow to use the box's height (no blank strip).
                let narrow = geo.size.width < 260
                let art: CGFloat = narrow ? 44 : (cow ? 92 : min(max(geo.size.height - 6, 92), 150))
                VStack(spacing: 6) {
                    player(art: art, narrow: narrow)
                    if cow { DancingCow().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: cow ? .top : .center)
            }
        }
        .background(media.artworkColor.opacity(0.30), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func artwork(_ art: CGFloat) -> some View {
        Group {
            if Fun.has(Fun.vinyl) { VinylView(size: art + 4) } else { AlbumArt(size: art, radius: art > 60 ? 12 : 7) }
        }
        .onTapGesture { media.openPlayer() }
        .shadow(color: .black.opacity(0.5), radius: 6)
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            if let icon = sourceIcon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
            Text(media.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
    }

    private var artistLine: some View {
        Text(media.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = scrub ?? media.currentPosition(at: ctx.date)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { pos }, set: { scrub = $0 }), in: 0...max(media.duration, 1)) { editing in
                    if !editing, let s = scrub { media.seek(s); scrub = nil }
                }
                .controlSize(.mini)
                .tint(Color.primary)
                HStack { Text(format(pos)); Spacer(); Text("-" + format(max(0, media.duration - pos))) }
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func controls(size: CGFloat, play: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
            Button { media.playPause() } label: { Image(systemName: media.isPlaying ? "pause.fill" : "play.fill").font(.system(size: play)) }
            Button { media.next() } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.system(size: size))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func player(art: CGFloat, narrow: Bool) -> some View {
            if media.hasTrack && narrow {
                // Compact layout for narrow boxes (e.g. three Home boxes): nothing wraps.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        artwork(art)
                        VStack(alignment: .leading, spacing: 1) { titleLine; artistLine }
                        Spacer(minLength: 0)
                    }
                    scrubber
                    controls(size: 13, play: 17, spacing: 18)
                }
            } else if media.hasTrack {
                HStack(spacing: 12) {
                    artwork(art)
                    VStack(alignment: .leading, spacing: 4) {
                        titleLine
                        artistLine
                        scrubber
                        controls(size: 15, play: 20, spacing: 22)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Nothing playing").font(.system(size: 13, weight: .medium))
                    Text("Play something in Spotify or Apple Music").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Music") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")) }
                        Button("Spotify") {
                            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") { NSWorkspace.shared.open(u) }
                            else { NSWorkspace.shared.open(URL(string: "https://open.spotify.com")!) }
                        }
                    }.controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            }
    }
}

/// Song tempo for the dancing cow. Spotify no longer gives tempo to new apps, so this looks the
/// song up on Deezer's public API by title + artist (no account needed). 0 = unknown.
final class TempoService {
    static let shared = TempoService()
    private var cache: [String: Double] = [:]
    private var inFlight = Set<String>()

    /// Returns the BPM if known; starts a lookup the first time a song is seen. Main thread only.
    func bpm(title: String, artist: String) -> Double? {
        guard !title.isEmpty else { return nil }
        let key = "\(artist)|\(title)".lowercased()
        if let v = cache[key] { return v > 0 ? v : nil }
        if inFlight.insert(key).inserted {
            Task {
                let v = await Self.lookup(title: title, artist: artist)
                await MainActor.run { self.cache[key] = v; self.inFlight.remove(key) }
            }
        }
        return nil
    }

    private static func lookup(title: String, artist: String) async -> Double {
        // "Song (feat. X) - Remastered 2011" → "Song"; "A, B & C" → "A"
        var t = title.components(separatedBy: " - ").first ?? title
        t = t.replacingOccurrences(of: "\\s*[\\(\\[].*?[\\)\\]]", with: "", options: .regularExpression)
        let a = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .components(separatedBy: " feat").first?.trimmingCharacters(in: .whitespaces) ?? artist
        var c = URLComponents(string: "https://api.deezer.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(a) \(t)"), URLQueryItem(name: "limit", value: "3")]
        guard let u = c.url, let j = await json(u), let hits = j["data"] as? [[String: Any]] else { return 0 }
        for h in hits {
            guard let id = h["id"] else { continue }
            if let d = await json(URL(string: "https://api.deezer.com/track/\(id)")!),
               let bpm = (d["bpm"] as? NSNumber)?.doubleValue, bpm > 30 { return bpm }
        }
        return 0
    }

    private static func json(_ u: URL) async -> [String: Any]? {
        guard let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

/// The dancing cow (optional, fills the space under Now Playing). Transparent background, so the
/// notch's own style shows through. Dances while music plays; when it stops, it finishes the current
/// dance cycle and settles on frame 0 (standing) instead of freezing mid-move.
final class CowAnimator: ObservableObject {
    static let frames: [NSImage] = {
        guard let u = Bundle.main.url(forResource: "cow", withExtension: "gif"),
              let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            CGImageSourceCreateImageAtIndex(src, i, nil).map { NSImage(cgImage: $0, size: .zero) }
        }
    }()
    @Published var frame = 0
    private var timer: Timer?
    private var sub: AnyCancellable?
    private var lastStep = Date.distantPast

    init() {
        sub = MediaController.shared.$isPlaying.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
    }
    func sync() {
        if (MediaController.shared.isPlaying || frame != 0), timer == nil, Self.frames.count > 1 {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        }
    }
    private func tick() {
        let m = MediaController.shared
        // On the beat: the frame follows the song's playback position, so the dips land on beats.
        if m.isPlaying, Prefs.bool(AP.cowBeat), Self.frames.count == 20,
           let bpm = TempoService.shared.bpm(title: m.title, artist: m.artist) {
            let f = Self.frame(onBeat: m.currentPosition(at: Date()) * Self.danceTempo(bpm) / 60)
            if f != frame { frame = f }
            return
        }
        // Otherwise the gif's own speed (10 fps).
        guard Date().timeIntervalSince(lastStep) >= 0.095 else { return }
        lastStep = Date()
        frame = (frame + 1) % Self.frames.count
        if frame == 0 && !m.isPlaying { stop() }   // back to standing: rest here
    }

    /// The gif dips 4 times per 20-frame loop, at frames 2, 6, 12 and 16 (120 BPM at its own speed).
    /// Stretch between those so a dip lands on every beat.
    private static let dips: [Double] = [2, 6, 12, 16, 22]
    static func frame(onBeat beats: Double) -> Int {
        let b = max(0, beats).truncatingRemainder(dividingBy: 4), k = Int(b), t = b - Double(k)
        return Int((dips[k] + (dips[k + 1] - dips[k]) * t).rounded(.down)) % 20
    }
    /// Very fast or slow songs dance at half/double time so the cow stays readable.
    static func danceTempo(_ bpm: Double) -> Double {
        var t = bpm
        while t > 150 { t /= 2 }
        while t < 75 { t *= 2 }
        return t
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

struct DancingCow: View {
    @StateObject private var anim = CowAnimator()
    var body: some View {
        Group {
            if !CowAnimator.frames.isEmpty {
                Image(nsImage: CowAnimator.frames[anim.frame]).resizable().interpolation(.medium).scaledToFit()
            }
        }
        .onAppear { anim.sync() }
        .onDisappear { anim.stop() }
    }
}

struct CalendarCard: View {
    @ObservedObject var cal = CalendarService.shared

    var body: some View {
        Card {
            if !cal.authorized {
                VStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("See your schedule here").font(.system(size: 13, weight: .medium))
                    Button("Connect Calendar") { cal.requestAccess() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    MonthGrid().frame(width: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cal.selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(.system(size: 12, weight: .semibold))
                        if cal.dayEvents.isEmpty {
                            Text("No events").font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(cal.dayEvents, id: \.eventIdentifier) { e in
                                    HStack(alignment: .top, spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(e.title ?? "").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                            Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct MonthGrid: View {
    @ObservedObject var cal = CalendarService.shared

    var body: some View {
        let c = Calendar.current
        let month = c.dateInterval(of: .month, for: cal.selectedDay)!
        let firstWeekday = (c.component(.weekday, from: month.start) - c.firstWeekday + 7) % 7
        let days = c.range(of: .day, in: .month, for: cal.selectedDay)!.count
        let today = c.startOfDay(for: Date())
        let symbols = c.veryShortWeekdaySymbols
        let ordered = Array(symbols[(c.firstWeekday - 1)...] + symbols[..<(c.firstWeekday - 1)])
        VStack(spacing: 3) {
            HStack {
                Button { cal.select(c.date(byAdding: .month, value: -1, to: cal.selectedDay)!) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(cal.selectedDay.formatted(.dateTime.month(.wide).year())).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { cal.select(c.date(byAdding: .month, value: 1, to: cal.selectedDay)!) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.plain).font(.system(size: 10))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 3), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { i in Text(ordered[i]).font(.system(size: 9)).foregroundStyle(.secondary) }
                ForEach(0..<firstWeekday, id: \.self) { _ in Color.clear.frame(height: 18) }
                ForEach(1...days, id: \.self) { d in
                    let date = c.date(byAdding: .day, value: d - 1, to: month.start)!
                    let sel = c.isDate(date, inSameDayAs: cal.selectedDay)
                    let isToday = date == today
                    Button { cal.select(date) } label: {
                        Text("\(d)")
                            .font(.system(size: 9.5, weight: isToday ? .bold : .regular))
                            .frame(width: 18, height: 18)
                            .background(sel ? Color.white : isToday ? Color.red.opacity(0.8) : .clear, in: Circle())
                            .foregroundStyle(sel ? .black : Color.primary)
                            .overlay(alignment: .bottom) {
                                if cal.busyDays.contains(d) && !sel { Circle().fill(.cyan).frame(width: 3, height: 3).offset(y: 1) }
                            }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Shelf

struct ShelfTab: View {
    @ObservedObject var shelf = ShelfStore.shared
    @AppStorage(AP.bookshelf) private var bookshelf = true
    @State private var airTarget = false

    var body: some View {
        HStack(spacing: 10) {
            Card {
                if bookshelf {
                    BookshelfView()
                } else if shelf.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Drag files onto the notch to keep them here").font(.system(size: 12, weight: .medium))
                        Text("Drag them back out into any app when you need them").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { u in ShelfItem(url: u) }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            VStack(spacing: 8) {
                VStack(spacing: 4) {
                    Image(systemName: "airplayaudio").font(.system(size: 22))
                    Text("AirDrop").font(.system(size: 11, weight: .semibold))
                    Text("Drop here").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(airTarget ? Color.blue.opacity(0.5) : Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $airTarget) { ShelfStore.shared.handleDrop($0, airDrop: true) }
                .onTapGesture { ShelfStore.airDrop(shelf.items) }
                .help("Drop files to AirDrop them, or click to AirDrop everything on the shelf")
                Button { shelf.clear() } label: { Label("Clear", systemImage: "trash").frame(maxWidth: .infinity) }
                    .controlSize(.small).disabled(shelf.items.isEmpty)
            }
            .frame(width: 110)
        }
    }
}

struct ShelfItem: View {
    let url: URL
    @State private var hover = false
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 48, height: 48)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(width: 76)
        }
        .padding(6)
        .background(hover ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { ShelfStore.shared.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { withAnimation { ShelfStore.shared.remove(url) } }   // removes from the shelf only; the file stays on disk
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { ShelfStore.airDrop([url]) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
            Divider()
            Button("Remove from Shelf") { ShelfStore.shared.remove(url) }
        }
    }
}

// MARK: - AI

struct AITab: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var ai = Assistant.shared
    @State private var input = ""
    @FocusState private var focused: Bool

    @AppStorage(AIEffort.key) private var effortRaw = AIEffort.medium.rawValue
    @State private var dropping = false

    let suggestions = [
        "What's on my screen? Summarize it",
        "Solve the problem on my screen",
        "Remind me to study at 7pm",
        "Draft an email asking for an extension",
    ]

    var body: some View {
        VStack(spacing: 8) {
            if let why = ai.unavailableReason {
                Card { Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12)) }
            } else if ai.messages.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ask anything, or let the Agent do things for you — free & private, running on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { if s.contains("screen") { ai.seeScreen = true }; ai.send(s) } label: {
                                    Text(s).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(ai.messages) { m in bubble(m).id(m.id) }
                            if ai.busy && (ai.messages.last?.role != .assistant || ai.status != nil) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    if let s = ai.status { Text(s).font(.system(size: 11)).foregroundStyle(.secondary) }
                                }.id("spinner")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: ai.messages.last?.text) { _, _ in
                        if let id = ai.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            if let img = ai.attachment {
                HStack(spacing: 8) {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                        .frame(width: 34, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("Image attached. Ask about it.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { ai.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Picker("", selection: $ai.agentMode) {
                    Text("Ask").tag(false)
                    Text("Agent").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                .help("Agent can open apps, make reminders & events, draft emails, find files and more")
                Button { ai.seeScreen.toggle() } label: {
                    Image(systemName: ai.seeScreen ? "eye.fill" : "eye.slash").foregroundStyle(ai.seeScreen ? .cyan : .secondary)
                }
                .buttonStyle(.plain).help("Let the AI read your screen")
                Menu {
                    Button { ai.captureArea() } label: { Label("Capture an area of the screen…", systemImage: "viewfinder") }
                    Button { ai.chooseImage() } label: { Label("Choose an image…", systemImage: "photo") }
                    Button { _ = ai.attachFromClipboard() } label: { Label("Paste image", systemImage: "doc.on.clipboard") }
                        .disabled(NSImage.canInit(with: .general) == false)
                } label: { Image(systemName: "paperclip") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Ask about an image")
                Menu {
                    Picker("Effort", selection: $effortRaw) {
                        ForEach(AIEffort.allCases) { e in
                            Label("\(e.title) — \(e.detail)", systemImage: e.icon).tag(e.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: (AIEffort(rawValue: effortRaw) ?? .medium).icon) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Effort: \((AIEffort(rawValue: effortRaw) ?? .medium).title). Higher is slower but smarter.")
                TextField(ai.agentMode ? "Tell Onyx what to do…" : "Ask Onyx…", text: $input)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                    .focused($focused)
                    .onSubmit(submit)
                if ai.busy {
                    Button { ai.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 18)) }.buttonStyle(.plain)
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.plain).disabled(input.isEmpty)
                }
                Button { CircleToSearch.shared.begin() } label: { Image(systemName: "circle.dashed.inset.filled") }
                    .buttonStyle(.plain).help("Circle to Search (⌃⌥Space)")
                Button { ai.reset() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("New chat")
            }
            .font(.system(size: 13))
        }
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        // Drop an image (or image file) here to ask about it; other drops still go to the Shelf.
        .onDrop(of: [.image, .fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    if let img = img as? NSImage { DispatchQueue.main.async { ai.attach(img) } }
                }
                return true
            }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u, let img = NSImage(contentsOf: u) { DispatchQueue.main.async { ai.attach(img) } }
            }
            return true
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 14).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [6])) } }
    }

    private func submit() {
        let t = input; input = ""
        ai.send(t)
    }

    @ViewBuilder private func bubble(_ m: Assistant.Msg) -> some View {
        switch m.role {
        case .user:
            HStack { Spacer(minLength: 60)
                if let img = m.image {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 70, maxHeight: 50).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(m.text).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).textSelection(.enabled)
            }
        case .assistant:
            Text(m.text).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)).textSelection(.enabled)
        case .tool:
            Label(m.text, systemImage: "wand.and.stars").font(.system(size: 10.5)).foregroundStyle(.cyan)
        case .error:
            Label(m.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.yellow)
        }
    }
}

// MARK: - Live: sports + markets

struct LiveTab: View {
    @State private var section = 0
    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $section) {
                Text("Sports").tag(0)
                Text("Markets").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            if section == 0 { SportsView().onAppear { SportsService.shared.refreshIfStale() } }
            else { MarketsView().onAppear { MarketsService.shared.refreshIfStale() } }
        }
    }
}

struct SportsView: View {
    @ObservedObject var sports = SportsService.shared
    @State private var selected: Game?
    @State private var showStandings = false

    var body: some View {
        VStack(spacing: 6) {
            if let g = selected {
                GameDetailView(game: sports.games[g.league.id]?.first { $0.id == g.id } ?? g) { selected = nil }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(sports.enabledLeagues) { l in
                            let liveCount = sports.games[l.id]?.filter(\.live).count ?? 0
                            Button { sports.selectedLeague = l.id; if showStandings { sports.loadStandings(l) } } label: {
                                HStack(spacing: 3) {
                                    Text(l.name)
                                    if liveCount > 0 { Circle().fill(.red).frame(width: 5, height: 5) }
                                }
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(sports.selectedLeague == l.id ? Color.primary.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        Button {
                            showStandings.toggle()
                            if showStandings, let l = League.byID(sports.selectedLeague) { sports.loadStandings(l) }
                        } label: {
                            Label("Standings", systemImage: "list.number").font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(showStandings ? Color.orange.opacity(0.5) : Color.primary.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                if showStandings {
                    StandingsView()
                } else {
                    let games = sports.games[sports.selectedLeague] ?? []
                    if games.isEmpty {
                        Text("No games today").font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                ForEach(games) { g in
                                    GameCard(game: g).onTapGesture { selected = g; sports.loadDetail(g) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct GameCard: View {
    let game: Game
    @ObservedObject var sports = SportsService.shared
    var body: some View {
        let favs = Set(sports.favorites)
        VStack(spacing: 3) {
            row(game.away, fav: favs.contains(game.away.abbr))
            row(game.home, fav: favs.contains(game.home.abbr))
            HStack {
                if game.live { Circle().fill(.red).frame(width: 5, height: 5) }
                Text(game.state == "pre" ? game.date.formatted(date: .omitted, time: .shortened) : game.detail)
                    .foregroundStyle(game.live ? .red : .secondary)
                Spacer()
                if let b = game.broadcast { Text(b).foregroundStyle(.secondary) }
            }
            .font(.system(size: 9.5, weight: .medium))
        }
        .padding(8)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    func row(_ t: TeamLine, fav: Bool) -> some View {
        HStack(spacing: 6) {
            Logo(url: t.logo, size: 16)
            Text(t.abbr).font(.system(size: 11.5, weight: .semibold))
            if fav { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
            Text(t.record).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Text(t.score).font(.system(size: 13, weight: .bold).monospacedDigit())
        }
    }
}

struct GameDetailView: View {
    let game: Game
    let back: () -> Void
    @ObservedObject var sports = SportsService.shared
    @State private var boxIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 11))
                Spacer()
                Text(game.live ? "● " + game.detail : game.detail).font(.system(size: 11, weight: .semibold)).foregroundStyle(game.live ? .red : .secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        teamBlock(game.away)
                        Text("–").foregroundStyle(.secondary)
                        teamBlock(game.home)
                    }
                    lineScore
                    ForEach(game.leaders.prefix(4), id: \.self) { Text($0).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(width: 250, alignment: .leading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let d = sports.detail {
                            if !d.box.isEmpty {
                                Picker("", selection: $boxIndex) {
                                    ForEach(d.box.indices, id: \.self) { i in Text(d.box[i].team).tag(i) }
                                }.pickerStyle(.segmented).labelsHidden().controlSize(.mini)
                                if d.box.indices.contains(boxIndex) { boxTable(d.box[boxIndex]) }
                            }
                            if !d.plays.isEmpty {
                                Text("Play-by-play").font(.system(size: 10, weight: .semibold)).padding(.top, 4)
                                ForEach(Array(d.plays.enumerated()), id: \.offset) { _, p in
                                    Text(p).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                }
                            }
                            if d.box.isEmpty && d.plays.isEmpty {
                                Text(game.lastPlay ?? "Details appear once the game starts.").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func teamBlock(_ t: TeamLine) -> some View {
        HStack(spacing: 6) {
            Logo(url: t.logo, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(t.abbr).font(.system(size: 11, weight: .semibold))
                Text(t.score.isEmpty ? "-" : t.score).font(.system(size: 20, weight: .bold).monospacedDigit())
            }
        }
    }

    var lineScore: some View {
        let n = max(game.away.linescores.count, game.home.linescores.count)
        return Grid(horizontalSpacing: 6, verticalSpacing: 2) {
            ForEach([game.away, game.home], id: \.abbr) { t in
                GridRow {
                    Text(t.abbr).font(.system(size: 9, weight: .semibold))
                    ForEach(0..<min(n, 12), id: \.self) { i in
                        Text(i < t.linescores.count ? t.linescores[i] : "").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func boxTable(_ b: BoxTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Text("").frame(width: 70, alignment: .leading)
                ForEach(b.labels, id: \.self) { Text($0).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary) }
            }
            ForEach(b.rows, id: \.self) { r in
                GridRow {
                    Text(r.name).font(.system(size: 9.5)).lineLimit(1).frame(width: 70, alignment: .leading)
                    ForEach(Array(r.stats.enumerated()), id: \.offset) { _, s in Text(s).font(.system(size: 9.5).monospacedDigit()) }
                }
            }
        }
    }
}

struct StandingsView: View {
    @ObservedObject var sports = SportsService.shared
    var body: some View {
        if sports.standings.isEmpty {
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 8) {
                    ForEach(sports.standings) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.id).font(.system(size: 10, weight: .bold)).lineLimit(1)
                            ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, r in
                                HStack(spacing: 5) {
                                    Text("\(i + 1)").frame(width: 14, alignment: .trailing).foregroundStyle(.secondary)
                                    Logo(url: r.logo, size: 12)
                                    Text(r.team).fontWeight(.semibold)
                                    Spacer()
                                    Text(r.record).monospacedDigit()
                                    Text(r.gb).frame(width: 26, alignment: .trailing).foregroundStyle(.secondary)
                                }
                                .font(.system(size: 9.5))
                            }
                        }
                        .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}

struct MarketsView: View {
    @ObservedObject var markets = MarketsService.shared
    var body: some View {
        if markets.quotes.isEmpty {
            VStack { ProgressView().controlSize(.small); Text("Loading watchlist…").font(.caption).foregroundStyle(.secondary) }
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                    ForEach(markets.quotes) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(q.id).font(.system(size: 11.5, weight: .bold))
                                Spacer()
                                Text(String(format: "%@%.2f%%", q.up ? "+" : "", q.changePct))
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((q.up ? Color.green : Color.red).opacity(0.25), in: Capsule())
                            }
                            Text(q.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            Sparkline(points: q.points, up: q.up).frame(height: 26)
                            Text(q.price, format: .number.precision(.fractionLength(2)))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .padding(8).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            let s = q.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q.id
                            NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(s)")!)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tools

struct ToolsTab: View {
    enum Tool: String, CaseIterable, Identifiable {
        case clipboard = "Clipboard", notes = "Notes", timer = "Timer", mirror = "Mirror", bluetooth = "Bluetooth", capture = "Capture", system = "System", fun = "Fun"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .clipboard: "doc.on.clipboard"
            case .notes: "note.text"
            case .timer: "timer"
            case .mirror: "camera.fill"
            case .bluetooth: "headphones"
            case .capture: "camera.viewfinder"
            case .fun: "party.popper.fill"
            case .system: "bolt.fill"
            }
        }
    }
    @AppStorage("toolsSelection") private var tool: Tool = .clipboard
    @AppStorage(Fun.enabled) private var funOn = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                ForEach(Tool.allCases.filter { $0 != .fun || funOn }) { t in
                    Button { tool = t } label: {
                        Label(t.rawValue, systemImage: t.icon).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(tool == t ? Color.primary.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 112)
            Card {
                switch tool {
                case .clipboard: ClipboardView()
                case .notes: NotesView()
                case .timer: TimerView()
                case .mirror: MirrorView()
                case .bluetooth: BluetoothView()
                case .capture: CaptureView()
                case .fun: FunPanelContent()
                case .system: SystemView()
                }
            }
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var clip = ClipboardHistory.shared
    @State private var search = ""
    @State private var copiedID: UUID?

    var body: some View {
        let items = clip.clips
            .filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.pinned ? 0 : 1) < ($1.pinned ? 0 : 1) }
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(clip.clips.count) clips", text: $search).textFieldStyle(.plain)
                Button("Clear") { clip.clear() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(items.prefix(300)) { c in
                        HStack(spacing: 6) {
                            if c.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                            Text(c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ "))
                                .font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(copiedID == c.id ? "Copied" : c.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { clip.copy(c); copiedID = c.id }
                        .contextMenu {
                            Button(c.pinned ? "Unpin" : "Pin") { clip.togglePin(c) }
                            Button("Delete") { clip.delete(c) }
                        }
                    }
                }
            }
        }
    }
}


struct TimerView: View {
    @ObservedObject var t = FocusTimer.shared
    @AppStorage(Prefs.eyeBreak) private var eyeBreak = false
    var body: some View {
        HStack(spacing: 18) {
            if Fun.has(Fun.bomb) {
                BombTimerView(size: 108)
            } else {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: t.running && t.total > 0 ? t.remaining / t.total : 0)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text(t.running ? format(t.remaining) : "0:00").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .frame(width: 104, height: 104)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach([5, 10, 25, 45, 60], id: \.self) { m in
                        Button("\(m)m") { t.begin(minutes: Double(m)) }.controlSize(.small)
                    }
                }
                if t.running {
                    HStack {
                        Button(t.pausedRemaining == nil ? "Pause" : "Resume") { t.togglePause() }
                        Button("Cancel", role: .destructive) { t.cancel() }
                    }.controlSize(.small)
                }
                Toggle("20-20-20 eye break reminders", isOn: $eyeBreak).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Text("Every 20 minutes, look at something 20 feet away for 20 seconds.").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MirrorView: View {
    var body: some View {
        MirrorCamera()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Text("Only you can see this").font(.system(size: 9)).padding(4).background(.black.opacity(0.5), in: Capsule()).padding(6)
            }
    }
}

struct CameraPreview: NSViewRepresentable {
    final class PreviewView: NSView {
        let session = AVCaptureSession()
        let preview: AVCaptureVideoPreviewLayer
        override init(frame: NSRect) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); preview.frame = bounds }
        func start() {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { return }
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        if let c = self.preview.connection, c.isVideoMirroringSupported {
                            c.automaticallyAdjustsVideoMirroring = false
                            c.isVideoMirrored = true
                        }
                    }
                }
            }
        }
        func stop() { DispatchQueue.global().async { self.session.stopRunning() } }
    }
    func makeNSView(context: Context) -> PreviewView { let v = PreviewView(frame: .zero); v.start(); return v }
    func updateNSView(_ v: PreviewView, context: Context) {}
    static func dismantleNSView(_ v: PreviewView, coordinator: ()) { v.stop() }
}

struct BluetoothView: View {
    @ObservedObject var bt = BluetoothService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if bt.devices.isEmpty {
                Text("No paired devices yet. Pair in System Settings › Bluetooth first.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(bt.devices) { d in
                        HStack(spacing: 6) {
                            Image(systemName: icon(d.name))
                            Text(d.name).font(.system(size: 11.5)).lineLimit(1)
                            if let b = bt.battery[d.name], b.any {
                                BTBatteryReadout(b: b).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if bt.busy == d.id { ProgressView().controlSize(.mini) }
                            Button(d.connected ? "Disconnect" : "Connect") { bt.toggle(d) }.controlSize(.small)
                        }
                        .padding(6).background(d.connected ? Color.blue.opacity(0.25) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        // Enumerating paired devices blocks briefly; wait until the notch has finished opening.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { bt.refreshIfStale(); bt.refreshBattery() } }
    }
    func icon(_ n: String) -> String {
        let l = n.lowercased()
        if l.contains("airpods") { return "airpods" }
        if l.contains("mouse") { return "computermouse.fill" }
        if l.contains("keyboard") { return "keyboard.fill" }
        if l.contains("controller") { return "gamecontroller.fill" }
        return "headphones"
    }
}

struct SystemView: View {
    @ObservedObject var caf = Caffeinate.shared
    @ObservedObject var battery = BatteryMonitor.shared
    @State private var volume: Double = Double(VolumeMonitor.shared.volume() ?? 0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(caf.active ? "Caffeinated" + (caf.until.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? "") : "Caffeinate",
                      systemImage: caf.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(caf.active ? .orange : Color.primary)
                Spacer()
                if caf.active { Button("Off") { caf.disable() } }
                else {
                    Button("1h") { caf.enable(hours: 1) }
                    Button("3h") { caf.enable(hours: 3) }
                    Button("∞") { caf.enable(hours: nil) }
                }
            }
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Slider(value: $volume, in: 0...1) { _ in }.onChange(of: volume) { _, v in VolumeMonitor.shared.setVolume(Float(v)) }
            }
            if battery.hasBattery {
                HStack {
                    BatteryIcon(percent: battery.percent, charging: battery.pluggedIn)
                    Text("\(battery.percent)% · " + (battery.pluggedIn ? (battery.charging ? "Charging" : "On power") : "On battery")
                         + (battery.minutesLeft.map { " · \($0 / 60)h \($0 % 60)m \(battery.pluggedIn ? "to full" : "left")" } ?? ""))
                }
            }
            HStack {
                Button { Caffeinate.lockScreen() } label: { Label("Lock Screen", systemImage: "lock.fill") }
                Button { CircleToSearch.shared.begin() } label: { Label("Circle to Search", systemImage: "circle.dashed") }
            }
        }
        .font(.system(size: 11.5))
        .controlSize(.small)
    }
}
