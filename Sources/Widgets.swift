import AppKit
import SwiftUI
import AVFoundation
import Intents

// MARK: - Lightweight cached, downsampled remote images (saves RAM vs. AsyncImage)

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var inflight = Set<String>()
    init() { cache.countLimit = 120; cache.totalCostLimit = 16 * 1024 * 1024 }

    /// ESPN serves 500px logos (~280 KB). Rewrite to its combiner thumbnail endpoint.
    private func thumbURL(_ url: URL, px: Int) -> URL {
        guard url.host?.contains("espncdn.com") == true else { return url }
        let enc = url.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.path
        return URL(string: "https://a.espncdn.com/combiner/i?img=\(enc)&w=\(px)&h=\(px)&transparent=true") ?? url
    }

    func image(_ url: URL, px: Int, done: @escaping (NSImage) -> Void) {
        let key = "\(url.absoluteString)@\(px)" as NSString
        if let img = cache.object(forKey: key) { done(img); return }
        if inflight.contains(key as String) { return }
        inflight.insert(key as String)
        let target = thumbURL(url, px: px)
        URLSession.shared.dataTask(with: target) { [weak self] data, _, _ in
            guard let self else { return }
            self.inflight.remove(key as String)
            guard let data, let full = NSImage(data: data) else { return }
            let img = Self.downsample(full, to: px)
            self.cache.setObject(img, forKey: key, cost: px * px * 4)
            DispatchQueue.main.async { done(img) }
        }.resume()
    }

    static func downsample(_ image: NSImage, to px: Int) -> NSImage {
        let side = CGFloat(px) * 2   // @2x for Retina
        guard image.size.width > side else { return image }
        let scale = side / max(image.size.width, image.size.height)
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = NSImage(size: newSize)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize))
        out.unlockFocus()
        return out
    }

    func purge() { cache.removeAllObjects() }
}

/// Drop-in replacement for AsyncImage that caches and downsamples.
struct RemoteImage: View {
    let url: URL?
    var px: Int = 40
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Circle().fill(Color.primary.opacity(0.12)) }
        }
        .onAppear { load() }
        .onChange(of: url) { _, _ in image = nil; load() }
    }
    private func load() {
        guard let url else { return }
        ImageCache.shared.image(url, px: px) { image = $0 }
    }
}

// MARK: - Header widgets you can add / reorder in the expanded notch top bar

enum NotchWidget: String, CaseIterable, Identifiable, Codable {
    case clock, date, weather, battery, music, stock, nextEvent, focus, mirror, cpu, moon, coffee, btBattery, focusStatus, canvas
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: "Clock"
        case .date: "Date"
        case .weather: "Weather"
        case .battery: "Battery"
        case .music: "Now Playing"
        case .stock: "Stock"
        case .nextEvent: "Next Event"
        case .focus: "Focus Timer"
        case .mirror: "Mirror"
        case .cpu: "CPU Load"
        case .moon: "Moon Phase"
        case .coffee: "Caffeinate"
        case .btBattery: "AirPods Battery"
        case .focusStatus: "Focus Status"
        case .canvas: "Canvas To-Do"
        }
    }
    var icon: String {
        switch self {
        case .clock: "clock"
        case .date: "calendar"
        case .weather: "cloud.sun"
        case .battery: "battery.75percent"
        case .music: "music.note"
        case .stock: "chart.line.uptrend.xyaxis"
        case .nextEvent: "calendar.badge.clock"
        case .focus: "timer"
        case .mirror: "camera"
        case .cpu: "cpu"
        case .moon: "moon.stars"
        case .coffee: "cup.and.saucer"
        case .btBattery: "airpods"
        case .focusStatus: "moon.fill"
        case .canvas: "graduationcap.fill"
        }
    }
}

extension NotchWidget {
    /// Approximate width this widget needs in a collapsed notch ear.
    var glanceWidth: CGFloat {
        switch self {
        case .coffee, .moon, .mirror: 34
        case .music: 52
        case .cpu: 56
        case .clock, .weather: 58
        case .nextEvent: 62
        case .date, .battery, .focus: 66
        case .stock: 78
        case .btBattery: 72
        case .focusStatus: 58
        case .canvas: 50
        }
    }
}

/// Ordered set of widgets shown in the expanded header, persisted and live-editable.
final class WidgetLayout: ObservableObject {
    static let shared = WidgetLayout()
    @Published var widgets: [NotchWidget] = []
    @Published var editing = false
    private let key = "ap.headerWidgets"

    init() {
        if let raw = UserDefaults.standard.string(forKey: key) {
            widgets = raw.split(separator: ",").compactMap { NotchWidget(rawValue: String($0)) }
        } else {
            widgets = [.clock, .weather, .battery]   // sensible defaults
        }
    }

    private func save() {
        UserDefaults.standard.set(widgets.map(\.rawValue).joined(separator: ","), forKey: key)
    }
    func toggle(_ w: NotchWidget) {
        if let i = widgets.firstIndex(of: w) { widgets.remove(at: i) } else { widgets.append(w) }
        save()
    }
    func move(from: IndexSet, to: Int) { widgets.move(fromOffsets: from, toOffset: to); save() }
    func contains(_ w: NotchWidget) -> Bool { widgets.contains(w) }
}

// MARK: - Widget views (compact, for the header strip)

struct HeaderWidgetView: View {
    let widget: NotchWidget
    var body: some View {
        switch widget {
        case .clock: ClockWidget()
        case .date: DateWidget()
        case .weather: WeatherWidget()
        case .battery: BatteryWidget()
        case .music: MusicWidget()
        case .stock: StockWidget()
        case .nextEvent: NextEventWidget()
        case .focus: FocusWidget()
        case .mirror: MirrorWidget()
        case .cpu: CPUWidget()
        case .moon: MoonWidget()
        case .coffee: CoffeeWidget()
        case .btBattery: BTBatteryWidget()
        case .focusStatus: FocusStatusWidget()
        case .canvas: CanvasWidget()
        }
    }
}

private struct Pill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
    }
}

struct ClockWidget: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Pill { Text(ctx.date, format: .dateTime.hour().minute()) .monospacedDigit() }
        }
    }
}

struct DateWidget: View {
    var body: some View { Pill { Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()) } }
}

struct WeatherWidget: View {
    @ObservedObject var w = WeatherService.shared
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                if let t = w.temp { Text("\(Int(t.rounded()))°") } else { Text("--°") }
            }
        }.help(w.place)
    }
}

struct BatteryWidget: View {
    @ObservedObject var b = BatteryMonitor.shared
    var body: some View {
        if b.hasBattery {
            Pill { HStack(spacing: 4) { Text("\(b.percent)%"); BatteryIcon(percent: b.percent, charging: b.pluggedIn) } }
        }
    }
}

struct MusicWidget: View {
    @ObservedObject var m = MediaController.shared
    var body: some View {
        if m.hasTrack {
            Pill {
                HStack(spacing: 5) {
                    AlbumArt(size: 15, radius: 3)
                    Text(m.title).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                    MusicBars(playing: m.isPlaying).frame(width: 12, height: 10)
                }
            }
            .onTapGesture { m.playPause() }
        }
    }
}

struct StockWidget: View {
    @ObservedObject var mk = MarketsService.shared
    var body: some View {
        if let q = mk.quotes.first {
            Pill {
                HStack(spacing: 4) {
                    Text(q.id)
                    Text(String(format: "%@%.1f%%", q.up ? "+" : "", q.changePct))
                        .foregroundStyle(q.up ? .green : .red).monospacedDigit()
                }
            }
        }
    }
}

struct NextEventWidget: View {
    @ObservedObject var cal = CalendarService.shared
    var body: some View {
        if let e = cal.upcoming.first {
            Pill {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").foregroundStyle(Color(nsColor: e.calendar.color))
                    Text(e.title ?? "").lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                    if let url = e.meetingURL, e.isJoinable {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Text("Join").font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green, in: Capsule())
                        }.buttonStyle(.plain)
                    } else {
                        Text(e.startDate, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct FocusWidget: View {
    @ObservedObject var t = FocusTimer.shared
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: "timer").foregroundStyle(.orange)
                Text(t.running ? format(t.remaining) : "Focus").monospacedDigit()
            }
        }
        .onTapGesture { t.running ? t.togglePause() : t.begin(minutes: 25) }
    }
}

struct CoffeeWidget: View {
    @ObservedObject var caf = Caffeinate.shared
    var body: some View {
        Pill {
            Image(systemName: caf.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(caf.active ? .orange : Color.primary)
        }
        .onTapGesture { caf.active ? caf.disable() : caf.enable(hours: nil) }
        .help(caf.active ? "Keeping Mac awake" : "Caffeinate")
    }
}

struct CPUWidget: View {
    @StateObject private var m = CPUMonitor()
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text("\(Int(m.usage))%").monospacedDigit().foregroundStyle(m.usage > 80 ? .red : m.usage > 50 ? .yellow : Color.primary)
            }
        }
    }
}

struct MoonWidget: View {
    var body: some View {
        let (icon, name) = Self.phase()
        Pill { HStack(spacing: 4) { Image(systemName: icon); Text(name) } }
    }
    static func phase() -> (String, String) {
        let known = 1739577600.0 // a known new moon (2025-02-15 UTC)
        let synodic = 29.53058867
        let days = (Date().timeIntervalSince1970 - known) / 86400
        let age = days.truncatingRemainder(dividingBy: synodic)
        let a = age < 0 ? age + synodic : age
        switch a {
        case ..<1.85: return ("moonphase.new.moon", "New")
        case ..<5.5: return ("moonphase.waxing.crescent", "Waxing")
        case ..<9.2: return ("moonphase.first.quarter", "First ¼")
        case ..<12.9: return ("moonphase.waxing.gibbous", "Waxing")
        case ..<16.6: return ("moonphase.full.moon", "Full")
        case ..<20.3: return ("moonphase.waning.gibbous", "Waning")
        case ..<23.9: return ("moonphase.last.quarter", "Last ¼")
        default: return ("moonphase.waning.crescent", "Waning")
        }
    }
}

struct MirrorWidget: View {
    @State private var open = false
    var body: some View {
        Pill { Image(systemName: "camera.fill") }
            .onTapGesture { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                MirrorCamera()
                    .frame(width: 240, height: 180)
                    .background(.black)
                    .environment(\.colorScheme, .dark)
            }
            .help("Mirror")
    }
}

// MARK: - CPU load sampler (only ticks while the expanded notch is on screen)

final class CPUMonitor: ObservableObject {
    @Published var usage: Double = 0
    private var timer: Timer?
    private var previous: (idle: Double, total: Double)?
    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }
    deinit { timer?.invalidate() }
    private func sample() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let user = Double(info.cpu_ticks.0), sys = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        let total = user + sys + idle + nice
        if let p = previous {
            let dt = total - p.total, di = idle - p.idle
            if dt > 0 { usage = max(0, min(100, (1 - di / dt) * 100)) }
        }
        previous = (idle, total)
    }
}

// MARK: - Collapsed-notch glances (compact, display-only, live in the pill's ears)

/// A small always-on readout for the idle collapsed notch. Chosen per side in Settings.
struct CollapsedGlance: View {
    let widget: NotchWidget
    var body: some View {
        content.lineLimit(1).fixedSize()
    }
    @ViewBuilder private var content: some View {
        switch widget {
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute()).monospacedDigit()
            }
        case .date:
            Text(Date(), format: .dateTime.weekday(.abbreviated).day())
        case .weather: CGWeather()
        case .battery: CGBattery()
        case .cpu: CGCPU()
        case .music: CGMusic()
        case .stock: CGStock()
        case .nextEvent: CGEvent()
        case .focus: CGFocus()
        case .coffee: CGCoffee()
        case .btBattery: CGBTBattery()
        case .focusStatus: CGFocusStatus()
        case .canvas: CanvasGlance()
        case .moon: Image(systemName: MoonWidget.phase().0)
        case .mirror: Image(systemName: "camera.fill").foregroundStyle(.secondary)
        }
    }
}

private struct CGWeather: View {
    @ObservedObject var w = WeatherService.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
            Text(w.temp.map { "\(Int($0.rounded()))°" } ?? "--°")
        }
    }
}

private struct CGBattery: View {
    @ObservedObject var b = BatteryMonitor.shared
    var body: some View {
        HStack(spacing: 3) {
            Text("\(b.percent)%")
            BatteryIcon(percent: b.percent, charging: b.pluggedIn)
        }
    }
}

private struct CGCPU: View {
    @StateObject private var m = CPUMonitor()
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu")
            Text("\(Int(m.usage))%").monospacedDigit()
        }
        .foregroundStyle(m.usage > 80 ? .red : m.usage > 50 ? .yellow : Color.primary)
    }
}

private struct CGMusic: View {
    @ObservedObject var m = MediaController.shared
    var body: some View {
        if m.hasTrack {
            HStack(spacing: 4) {
                if Fun.has(Fun.vinyl) { VinylView(size: 18) } else { AlbumArt(size: 16, radius: 4) }
                MusicBars(playing: m.isPlaying).frame(width: 14, height: 12)
            }
        } else {
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }
}

private struct CGStock: View {
    @ObservedObject var mk = MarketsService.shared
    var body: some View {
        if let q = mk.quotes.first {
            HStack(spacing: 3) {
                Text(q.id)
                Text(String(format: "%@%.1f%%", q.up ? "+" : "", q.changePct)).foregroundStyle(q.up ? .green : .red)
            }.monospacedDigit()
        } else {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.secondary)
        }
    }
}

private struct CGEvent: View {
    @ObservedObject var cal = CalendarService.shared
    var body: some View {
        if let e = cal.upcoming.first {
            HStack(spacing: 3) {
                Image(systemName: "calendar").foregroundStyle(Color(nsColor: e.calendar.color))
                Text(e.startDate, format: .dateTime.hour().minute())
            }
        } else {
            Image(systemName: "calendar").foregroundStyle(.secondary)
        }
    }
}

private struct CGFocus: View {
    @ObservedObject var t = FocusTimer.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "timer").foregroundStyle(.orange)
            Text(t.running ? format(t.remaining) : "Focus").monospacedDigit()
        }
    }
}

private struct CGCoffee: View {
    @ObservedObject var caf = Caffeinate.shared
    var body: some View {
        Image(systemName: caf.active ? "cup.and.saucer.fill" : "cup.and.saucer")
            .foregroundStyle(caf.active ? .orange : .secondary)
    }
}

// MARK: - AirPods / Bluetooth battery views

/// Detailed readout for the Bluetooth tool (main, or left/right/case for AirPods).
struct BTBatteryReadout: View {
    let b: BluetoothService.BTBattery
    var body: some View {
        HStack(spacing: 5) {
            if let m = b.main { seg(nil, m) }
            if let l = b.left { seg("L", l) }
            if let r = b.right { seg("R", r) }
            if let c = b.caseLevel { seg("◫", c) }
        }
    }
    @ViewBuilder private func seg(_ label: String?, _ pct: Int) -> some View {
        Text(label.map { "\($0) \(pct)%" } ?? "\(pct)%").foregroundStyle(pct <= 20 ? .red : .secondary)
            .lineLimit(1).fixedSize()
    }
}

/// Header-strip pill: the primary device's lowest earbud level.
struct BTBatteryWidget: View {
    @ObservedObject var bt = BluetoothService.shared
    var body: some View {
        if let p = bt.primaryBattery, let low = p.battery.low {
            Pill { HStack(spacing: 4) { Image(systemName: "airpods"); Text("\(low)%").foregroundStyle(low <= 20 ? .red : Color.primary) } }
                .help(p.name)
                .onAppear { bt.refreshBattery() }
        }
    }
}

private struct CGBTBattery: View {
    @ObservedObject var bt = BluetoothService.shared
    var body: some View {
        Group {
            if let p = bt.primaryBattery, let low = p.battery.low {
                HStack(spacing: 3) { Image(systemName: "airpods"); Text("\(low)%") }.foregroundStyle(low <= 20 ? .red : Color.primary)
            } else {
                Image(systemName: "airpods").foregroundStyle(.secondary)
            }
        }
        .onAppear { bt.refreshBattery() }
    }
}

// MARK: - Focus status (Do Not Disturb, Work, Sleep, …)

/// Whether a Focus is on, via Apple's Focus status API. Starts (and asks permission) only once a
/// Focus widget or box is actually shown; then re-checks every few seconds.
final class FocusMonitor: ObservableObject {
    static let shared = FocusMonitor()
    @Published private(set) var isFocused: Bool?
    @Published private(set) var authorized = INFocusStatusCenter.default.authorizationStatus == .authorized
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        INFocusStatusCenter.default.requestAuthorization { st in
            DispatchQueue.main.async { self.authorized = st == .authorized; self.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let f = INFocusStatusCenter.default.focusStatus.isFocused
        if f != isFocused { isFocused = f }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
    }
}

struct FocusStatusWidget: View {
    @ObservedObject var f = FocusMonitor.shared
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: f.isFocused == true ? "moon.fill" : "moon").foregroundStyle(f.isFocused == true ? .purple : .secondary)
                Text(f.isFocused == true ? "Focus" : "No Focus")
            }
        }
        .onTapGesture { FocusMonitor.openSettings() }
        .help("Focus status (click for Focus settings)")
        .onAppear { f.start() }
    }
}

private struct CGFocusStatus: View {
    @ObservedObject var f = FocusMonitor.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: f.isFocused == true ? "moon.fill" : "moon")
            Text(f.isFocused == true ? "On" : "Off")
        }
        .foregroundStyle(f.isFocused == true ? Color.purple : Color.secondary)
        .onAppear { f.start() }
    }
}
