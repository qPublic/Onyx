import SwiftUI
import WebKit

// MARK: - Customizable Home board (the big boxes: Music, Calendar, Weather, …)

enum HomePanel: String, CaseIterable, Identifiable, Codable {
    case music, calendar, weather, clock, notes, clipboard, stocks, events, shelf, mirror, bluetooth, timer, capture, system, fun, focusStatus, canvas, aquarium, calculator, colorPicker
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: "Now Playing"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .clock: "Clock"
        case .notes: "Notes"
        case .clipboard: "Clipboard"
        case .stocks: "Watchlist"
        case .events: "Upcoming"
        case .shelf: "File Shelf"
        case .mirror: "Mirror"
        case .bluetooth: "Bluetooth"
        case .timer: "Focus Timer"
        case .capture: "Capture"
        case .system: "System"
        case .fun: "Fun"
        case .focusStatus: "Focus Status"
        case .canvas: "Canvas To-Do"
        case .aquarium: "Aquarium Live"
        case .calculator: "Calculator"
        case .colorPicker: "Color Picker"
        }
    }
    var icon: String {
        switch self {
        case .music: "music.note"
        case .calendar: "calendar"
        case .weather: "cloud.sun.fill"
        case .clock: "clock.fill"
        case .notes: "note.text"
        case .clipboard: "doc.on.clipboard"
        case .stocks: "chart.line.uptrend.xyaxis"
        case .events: "calendar.badge.clock"
        case .shelf: "tray.full.fill"
        case .mirror: "camera.fill"
        case .bluetooth: "headphones"
        case .timer: "timer"
        case .capture: "camera.viewfinder"
        case .system: "bolt.fill"
        case .fun: "party.popper.fill"
        case .focusStatus: "moon.fill"
        case .canvas: "graduationcap.fill"
        case .aquarium: "fish.fill"
        case .calculator: "equal.square.fill"
        case .colorPicker: "eyedropper.halffull"
        }
    }
}

/// Ordered set of Home panels, persisted and live-editable.
final class HomeLayout: ObservableObject {
    static let shared = HomeLayout()
    @Published var panels: [HomePanel] = []
    @Published var editing = false
    private let key = "ap.homePanels"

    init() {
        if let raw = UserDefaults.standard.string(forKey: key) {
            panels = raw.split(separator: ",").compactMap { HomePanel(rawValue: String($0)) }
        } else {
            panels = [.music, .calendar]   // matches the original layout
        }
        if panels.isEmpty { panels = [.music] }
    }

    private func save() {
        UserDefaults.standard.set(panels.map(\.rawValue).joined(separator: ","), forKey: key)
    }
    func toggle(_ p: HomePanel) {
        if let i = panels.firstIndex(of: p) { if panels.count > 1 { panels.remove(at: i) } }
        else { panels.append(p) }
        save()
    }
    func move(_ p: HomePanel, by d: Int) {
        guard let i = panels.firstIndex(of: p) else { return }
        let j = i + d
        guard panels.indices.contains(j) else { return }
        panels.swapAt(i, j); save()
    }
    func contains(_ p: HomePanel) -> Bool { panels.contains(p) }
}

// MARK: - Home tab: renders the chosen panels side by side, with edit mode

struct HomeTab: View {
    @ObservedObject var layout = HomeLayout.shared
    var body: some View {
        HStack(spacing: 10) {
            ForEach(layout.panels) { panel in
                PanelHost(panel: panel, editing: layout.editing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: layout.panels)
        .overlay(alignment: .top) {
            if layout.editing { editBar }
        }
    }

    private var editBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HomePanel.allCases) { p in
                    Button { layout.toggle(p) } label: { Label(p.title, systemImage: layout.contains(p) ? "checkmark" : p.icon) }
                }
            } label: { Label("Add box", systemImage: "plus.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize()
            Button("Done") { withAnimation { layout.editing = false } }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, -2)
    }
}

/// Wraps a panel with move/remove chrome while editing.
struct PanelHost: View {
    let panel: HomePanel
    let editing: Bool
    @ObservedObject var layout = HomeLayout.shared

    var body: some View {
        PanelContent(panel: panel)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                }
            }
            .overlay(alignment: .top) {
                if editing {
                    HStack {
                        Button { layout.move(panel, by: -1) } label: { Image(systemName: "chevron.left.circle.fill") }
                        Spacer()
                        Button { layout.toggle(panel) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        Spacer()
                        Button { layout.move(panel, by: 1) } label: { Image(systemName: "chevron.right.circle.fill") }
                    }
                    .font(.system(size: 15)).buttonStyle(.plain).foregroundStyle(Color.primary)
                    .padding(6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
            }
    }
}

struct PanelContent: View {
    let panel: HomePanel
    var body: some View {
        switch panel {
        case .music: MusicCard()
        case .calendar: CalendarCard()
        case .weather: WeatherPanel()
        case .clock: ClockPanel()
        case .notes: Card { NotesView() }
        case .clipboard: Card { ClipboardView() }
        case .stocks: StocksPanel().onAppear { MarketsService.shared.refreshIfStale() }
        case .events: EventsPanel()
        case .shelf: ShelfPanel()
        case .mirror: Card { MirrorView() }
        case .bluetooth: Card { BluetoothView() }
        case .timer: Card { TimerView() }
        case .capture: Card { CaptureView() }
        case .system: Card { SystemView() }
        case .fun: FunPanel()
        case .focusStatus: FocusStatusPanel()
        case .canvas: CanvasPanel()
        case .aquarium: AquariumPanel()
        case .calculator: CalculatorPanel()
        case .colorPicker: ColorPickerPanel()
        }
    }
}

// MARK: - New panels

struct WeatherPanel: View {
    @ObservedObject var w = WeatherService.shared
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 32))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(w.temp.map { "\(Int($0.rounded()))°" } ?? "--").font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(w.place).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let hi = w.high, let lo = w.low {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("H \(Int(hi.rounded()))°").font(.system(size: 10))
                            Text("L \(Int(lo.rounded()))°").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !w.hourly.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 13) {
                            ForEach(w.hourly) { h in
                                VStack(spacing: 3) {
                                    Text(h.time, format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(.secondary)
                                    Image(systemName: WeatherService.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 13))
                                    Text("\(Int(h.temp.rounded()))°").font(.system(size: 10, weight: .medium))
                                    Text(h.precip >= 20 ? "\(h.precip)%" : " ").font(.system(size: 8)).foregroundStyle(.cyan)
                                }
                            }
                        }
                    }
                }
                if w.daily.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(w.daily.prefix(5)) { d in
                            HStack(spacing: 6) {
                                Text(d.date, format: .dateTime.weekday(.abbreviated)).font(.system(size: 10)).frame(width: 32, alignment: .leading)
                                Image(systemName: WeatherService.symbol(d.code)).symbolRenderingMode(.multicolor).font(.system(size: 11)).frame(width: 16)
                                Spacer()
                                Text("\(Int(d.lo.rounded()))°").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text("\(Int(d.hi.rounded()))°").font(.system(size: 10, weight: .medium)).frame(width: 26, alignment: .trailing)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct ClockPanel: View {
    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 2) {
                    Text(ctx.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(ctx.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct StocksPanel: View {
    @ObservedObject var mk = MarketsService.shared
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                Text("Watchlist").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if mk.quotes.isEmpty { ProgressView().controlSize(.small) }
                ForEach(mk.quotes.prefix(5)) { q in
                    HStack(spacing: 6) {
                        Text(q.id).font(.system(size: 12, weight: .semibold)).frame(width: 70, alignment: .leading).lineLimit(1)
                        Sparkline(points: q.points, up: q.up).frame(height: 16)
                        Text(String(format: "%@%.1f%%", q.up ? "+" : "", q.changePct))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(q.up ? .green : .red).frame(width: 56, alignment: .trailing)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct EventsPanel: View {
    @ObservedObject var cal = CalendarService.shared
    var body: some View {
        Card {
            if !cal.authorized {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 24)).foregroundStyle(.secondary)
                    Button("Connect Calendar") { cal.requestAccess() }.controlSize(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Upcoming").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if cal.upcoming.isEmpty { Text("Nothing this week").font(.caption).foregroundStyle(.secondary) }
                    ForEach(cal.upcoming, id: \.eventIdentifier) { e in
                        HStack(alignment: .top, spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(e.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let url = e.meetingURL {
                                Button { NSWorkspace.shared.open(url) } label: {
                                    Text("Join").font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(e.isJoinable ? Color.green : Color.primary.opacity(0.15), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Compact File Shelf box: your stashed files, and a drop target for adding more.
struct ShelfPanel: View {
    @ObservedObject var shelf = ShelfStore.shared
    @State private var target = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Shelf").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !shelf.items.isEmpty {
                        Button { ShelfStore.airDrop(shelf.items) } label: { Image(systemName: "airplayaudio") }.help("AirDrop all")
                        Button { shelf.clear() } label: { Image(systemName: "trash") }.help("Clear")
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11))
                if Prefs.bool(AP.bookshelf) {
                    BookshelfView(rowHeight: 50)
                } else if shelf.items.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(shelf.items, id: \.self) { ShelfItem(url: $0) } }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .overlay { if target { RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 2) } }
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $target) { shelf.handleDrop($0) }
    }
}

struct FocusStatusPanel: View {
    @ObservedObject var f = FocusMonitor.shared
    var body: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: f.isFocused == true ? "moon.fill" : "moon")
                    .font(.system(size: 34)).foregroundStyle(f.isFocused == true ? Color.purple : Color.secondary)
                    .symbolEffect(.bounce, value: f.isFocused)
                Text(f.isFocused == true ? "A Focus is on" : "No Focus").font(.system(size: 14, weight: .semibold))
                if !f.authorized {
                    Text("Allow Focus status access for this to work.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Focus settings") { FocusMonitor.openSettings() }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { f.start() }
    }
}

// MARK: - Monterey Bay Aquarium live cam

/// Small, muted live stream from the Monterey Bay Aquarium's YouTube channel. The web view only
/// exists while the box is on screen (it's torn down when the notch closes), and YouTube picks a
/// low resolution for a player this small, which keeps memory down.
struct AquariumPanel: View {
    var body: some View {
        Card {
            AquariumStream()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Label("Monterey Bay Aquarium · Live", systemImage: "fish.fill")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct AquariumStream: NSViewRepresentable {
    static let channel = "UCnM5iMGiKsZg-iOlIO2ZkdQ"   // Monterey Bay Aquarium

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            // Muted autoplay: nudge the player if it's waiting on a play button.
            let js = "var v=document.querySelector('video'); if(v){v.muted=true; v.play();} var b=document.querySelector('.ytp-large-play-button'); if(b && (!v || v.paused)){b.click();}"
            for delay in [0.5, 2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { w.evaluateJavaScript(js) }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.mediaTypesRequiringUserActionForPlayback = []
        c.websiteDataStore = .nonPersistent()             // no cookies or history kept
        let w = WKWebView(frame: .zero, configuration: c)
        w.setValue(false, forKey: "drawsBackground")
        w.wantsLayer = true
        w.layer?.cornerRadius = 10
        w.layer?.masksToBounds = true
        w.navigationDelegate = context.coordinator
        // The aquarium runs several cams, so ask YouTube which video the channel has live right now.
        Self.currentLiveVideo { id in
            let src = "https://www.youtube-nocookie.com/embed/\(id)"
                + "?autoplay=1&mute=1&controls=0&playsinline=1&modestbranding=1&rel=0&iv_load_policy=3&disablekb=1"
            var req = URLRequest(url: URL(string: src)!)
            req.setValue("https://www.youtube-nocookie.com/", forHTTPHeaderField: "Referer")   // embeds need a referrer
            w.load(req)
        }
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {}

    static let fallbackVideo = "zL68biE6wAs"   // Live Moon Jelly Cam

    static func currentLiveVideo(_ done: @escaping (String) -> Void) {
        var r = URLRequest(url: URL(string: "https://www.youtube.com/channel/\(channel)/live")!)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                   forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 8
        URLSession.shared.dataTask(with: r) { d, _, _ in
            var id = fallbackVideo
            if let d, let html = String(data: d, encoding: .utf8),
               let m = html.range(of: #"<link rel="canonical" href="https://www\.youtube\.com/watch\?v=([\w-]{11})""#, options: .regularExpression) {
                id = String(html[m].suffix(12).prefix(11))
            }
            DispatchQueue.main.async { done(id) }
        }.resume()
    }

    static func dismantleNSView(_ w: WKWebView, coordinator: Coordinator) {
        w.stopLoading()
        w.loadHTMLString("", baseURL: nil)   // stop the video right away
    }
}
