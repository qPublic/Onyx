import SwiftUI
import UniformTypeIdentifiers

struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

enum Activity: Equatable {
    case none, hud(HUDEvent), timer, game(Game), music, ticker(Quote), recording, download, reminder(String)

    var key: String {
        switch self {
        case .none: "none"
        case .hud(let h):
            switch h {
            case .volume: "vol"
            case .brightness: "bri"
            case .charging: "chg"
            case .lowBattery: "low"
            case .message: "msg"
            case .eyeBreak: "eye"
            }
        case .timer: "timer"
        case .game(let g): "game" + g.id
        case .music: "music"
        case .ticker: "ticker"
        case .recording: "rec"
        case .download: "dl"
        case .reminder: "rem"
        }
    }

    var earWidth: CGFloat {
        switch self {
        case .none: 0
        case .hud(.message), .hud(.eyeBreak), .reminder: 118
        case .game: 84
        case .ticker, .download: 84
        default: 70
        }
    }
}

struct NotchRootView: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var timer = FocusTimer.shared
    @ObservedObject var sports = SportsService.shared
    @ObservedObject var markets = MarketsService.shared
    @ObservedObject var capture = QuickCapture.shared
    @ObservedObject var downloads = DownloadMonitor.shared
    @ObservedObject var reminders = OnyxReminders.shared
    @AppStorage(Prefs.sportsActivity) var sportsActivity = true
    @AppStorage(Prefs.tickerActivity) var tickerActivity = false
    @ObservedObject var appearance = AppearanceStore.shared
    @ObservedObject var backdrop = BackdropSampler.shared

    /// Only while the (see-through) clear glass is actually showing: expanded, or collapsed with the style applied.
    var darkText: Bool {
        BackdropSampler.enabled && backdrop.isLight && (model.expanded || AP.styleWhenCollapsed)
    }

    // Now Playing no longer auto-takes-over the notch; pick it as a collapsed widget to keep it in place.
    var activity: Activity {
        if let h = model.hud { return .hud(h) }
        if let r = reminders.ringing.first { return .reminder(r.title) }   // stays until Done / Snooze
        if capture.recording { return .recording }
        if !downloads.items.isEmpty { return .download }
        if timer.running { return .timer }
        if sportsActivity, let g = sports.favoriteLiveGame { return .game(g) }
        if tickerActivity, let q = markets.quotes.first { return .ticker(q) }
        return .none
    }

    /// Ear width when idle, driven by the collapsed-notch glance widgets the user picked.
    var idleEar: CGFloat { model.geometry.earsTucked ? 0 : max(AP.collapsedLeft?.glanceWidth ?? 0, AP.collapsedRight?.glanceWidth ?? 0) }

    /// Volume/brightness changes drop a small pop-out down from the notch (Settings › Behavior).
    var popup: HUDEvent? {
        guard !model.expanded, Prefs.bool(AP.hudPopup), case .hud(let h) = activity else { return nil }
        switch h {
        case .volume, .brightness: return h
        default: return nil
        }
    }

    var size: CGSize {
        let g = model.geometry
        if model.expanded { return g.expandedSize }
        if popup != nil { return CGSize(width: max(g.notchWidth + 150, 320), height: g.notchHeight + 40) }
        if activity == .none {
            let mid = g.hasNotch ? 0 : AP.collapsedMid?.glanceWidth ?? 0   // the center is behind a built-in camera
            return CGSize(width: max(g.notchWidth, mid + 28) + 2 * idleEar, height: g.notchHeight)
        }
        return CGSize(width: g.notchWidth + 2 * activity.earWidth, height: g.notchHeight)
    }

    var body: some View {
        let s = size
        let top: CGFloat = model.expanded ? 12 : 6
        let bottom: CGFloat = model.expanded ? 26 : (popup != nil ? 18 : 10)
        ZStack(alignment: .top) {
            NotchBackground(shape: NotchShape(top: top, bottom: bottom), expanded: model.expanded)
                .frame(width: s.width, height: s.height)
            ZStack(alignment: .top) {
                if model.expanded {
                    // Laid out once at its final size; the growing notch shape just reveals it. Re-laying out
                    // the whole panel at every in-between size each frame is what made opening stutter.
                    ExpandedView()
                        .frame(width: model.geometry.expandedSize.width, height: model.geometry.expandedSize.height, alignment: .top)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if let p = popup {
                    HUDPopupView(hud: p)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -14)), removal: .opacity))
                } else {
                    CollapsedView(activity: activity)
                        .transition(.opacity)
                }
            }
            .frame(width: s.width, height: s.height, alignment: .top)
            .clipShape(NotchShape(top: top, bottom: bottom))
        }
        .padding(.top, NotchGeometry.menuBarLift(model.geometry, expanded: model.expanded))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: activity.key)
        // Clear glass: flip to dark text over light backgrounds so it stays readable.
        .environment(\.colorScheme, darkText ? .light : .dark)
        .foregroundStyle(darkText ? Color.black : Color.white)
    }
}

// MARK: - Collapsed live activities

struct CollapsedView: View {
    let activity: Activity
    @EnvironmentObject var model: NotchModel
    @ObservedObject var media = MediaController.shared
    @ObservedObject var timer = FocusTimer.shared

    var body: some View {
        let idle = activity == .none
        let tucked = idle && model.geometry.earsTucked
        let ear = tucked ? 0 : idle ? max(AP.collapsedLeft?.glanceWidth ?? 0, AP.collapsedRight?.glanceWidth ?? 0) : activity.earWidth
        ZStack {
            HStack(spacing: 0) {
                leftContent.frame(width: max(ear - 16, 0), alignment: .leading).padding(.leading, ear > 0 ? 16 : 0)
                Spacer(minLength: 0)
                rightContent.frame(width: max(ear - 16, 0), alignment: .trailing).padding(.trailing, ear > 0 ? 16 : 0)
            }
            if idle, !model.geometry.hasNotch, let w = AP.collapsedMid { CollapsedGlance(widget: w) }   // centered on the pill
        }
        .frame(height: model.geometry.notchHeight)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }

    // Idle → user-chosen glance widgets; otherwise the live activity's own left/right content.
    @ViewBuilder private var leftContent: some View {
        if activity == .none { if !model.geometry.earsTucked, let w = AP.collapsedLeft { CollapsedGlance(widget: w) } }
        else { left }
    }
    @ViewBuilder private var rightContent: some View {
        if activity == .none { if !model.geometry.earsTucked, let w = AP.collapsedRight { CollapsedGlance(widget: w) } }
        else { right }
    }

    @ViewBuilder var left: some View {
        switch activity {
        case .none: EmptyView()
        case .music: AlbumArt(size: 20, radius: 5)
        case .timer: if Fun.has(Fun.bomb) { Text("💣") } else { Image(systemName: "timer").foregroundStyle(.orange) }
        case .game(let g): HStack(spacing: 5) { Logo(url: g.away.logo, size: 18); Text(g.away.score).monospacedDigit() }
        case .ticker(let q): Text(q.id).lineLimit(1)
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
        case .reminder: Image(systemName: "bell.fill").foregroundStyle(.orange).symbolEffect(.bounce, options: .repeating)
        case .download:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.cyan)
                if DownloadMonitor.shared.items.count > 1 { Text("\(DownloadMonitor.shared.items.count)").monospacedDigit() }
            }
        case .hud(let h):
            switch h {
            case .volume(_, let muted):
                if media.hasTrack && media.isPlaying { AlbumArt(size: 20, radius: 5) }
                else { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
            case .brightness(let b): Image(systemName: b < 0.5 ? "sun.min.fill" : "sun.max.fill")
            case .charging(_, let plugged):
                Image(systemName: plugged ? "bolt.fill" : "powerplug.fill").foregroundStyle(plugged ? .green : .secondary)
            case .lowBattery: Image(systemName: "battery.25percent").foregroundStyle(.red)
            case .message(let icon, _, let tint): Image(systemName: icon).foregroundStyle(tint)
            case .eyeBreak: HStack(spacing: 5) { Image(systemName: "eye.fill").foregroundStyle(.cyan); Text("Eye break").lineLimit(1) }
            }
        }
    }

    @ViewBuilder var right: some View {
        switch activity {
        case .none: EmptyView()
        case .music: MusicBars(playing: media.isPlaying).frame(width: 20, height: 14)
        case .timer:
            Text(format(timer.remaining)).monospacedDigit()
                .foregroundStyle(timer.pausedRemaining != nil ? .secondary : .primary)
        case .game(let g): HStack(spacing: 5) { Text(g.home.score).monospacedDigit(); Logo(url: g.home.logo, size: 18) }
        case .ticker(let q):
            Text(String(format: "%@%.2f%%", q.up ? "+" : "", q.changePct)).foregroundStyle(q.up ? .green : .red).monospacedDigit()
        case .recording:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(format(ctx.date.timeIntervalSince(QuickCapture.shared.startedAt ?? ctx.date))).monospacedDigit().foregroundStyle(.red)
            }
        case .reminder(let title): Text(title).lineLimit(1).minimumScaleFactor(0.8)
        case .download:
            if let f = DownloadMonitor.shared.overall {
                HStack(spacing: 5) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(width: 30, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(Color.cyan).frame(width: 30 * CGFloat(f), height: 5) }
                    Text("\(Int(f * 100))%").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            } else {
                Text(ByteCountFormatter.string(fromByteCount: DownloadMonitor.shared.items.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
        case .hud(let h):
            switch h {
            case .volume(let v, let muted):
                HStack(spacing: 5) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(width: 34, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(Color.primary).frame(width: muted ? 0 : 34 * CGFloat(v), height: 5) }
                    Text("\(muted ? 0 : Int((v * 100).rounded()))").monospacedDigit().frame(width: 18, alignment: .trailing)
                }
            case .brightness(let b):
                HStack(spacing: 5) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(width: 34, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(Color.primary).frame(width: 34 * CGFloat(b), height: 5) }
                    Text("\(Int((b * 100).rounded()))").monospacedDigit().frame(width: 18, alignment: .trailing)
                }
            case .charging(let p, let plugged):
                HStack(spacing: 3) { Text("\(p)%").monospacedDigit(); BatteryIcon(percent: p, charging: plugged) }
            case .lowBattery(let p): Text("\(p)%").foregroundStyle(.red)
            case .message(_, let text, _): Text(text).lineLimit(1)
            case .eyeBreak(let until):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(until.timeIntervalSince(ctx.date)))
                    Text(s > 0 ? "Look 20 ft away · \(s)s" : "Done 👍").lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }
}

// MARK: - Volume / brightness pop-out (drops down from the notch)

struct HUDPopupView: View {
    let hud: HUDEvent
    @EnvironmentObject var model: NotchModel

    var body: some View {
        let (icon, value) = Self.info(hud)
        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.notchHeight)   // the notch / menu-bar strip stays clean
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.18))
                        Capsule().fill(Color.primary).frame(width: max(0, geo.size.width * CGFloat(value)))
                    }
                }
                .frame(height: 6)
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: value)
        }
    }

    static func info(_ h: HUDEvent) -> (String, Float) {
        switch h {
        case .volume(let v, let muted):
            if muted || v < 0.001 { return ("speaker.slash.fill", 0) }
            return (v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill", v)
        case .brightness(let b): return (b < 0.5 ? "sun.min.fill" : "sun.max.fill", b)
        default: return ("", 0)
        }
    }
}

func format(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Small shared views

struct AlbumArt: View {
    var size: CGFloat
    var radius: CGFloat
    @ObservedObject var media = MediaController.shared
    var body: some View {
        Group {
            if let a = media.artwork { Image(nsImage: a).resizable().scaledToFill() }
            else {
                ZStack { LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct MusicBars: View {
    var playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 0.3 + 0.7 * abs(sin(t * (2.2 + Double(i) * 0.9) + Double(i))) : 0.25
                    Capsule().fill(LinearGradient(colors: [.pink, .orange], startPoint: .bottom, endPoint: .top))
                        .frame(width: 3, height: 14 * h)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}

struct Logo: View {
    let url: URL?
    var size: CGFloat
    var body: some View {
        RemoteImage(url: url, px: Int(size.rounded())).frame(width: size, height: size)
    }
}

struct BatteryIcon: View {
    let percent: Int
    let charging: Bool
    var body: some View {
        let name = percent > 87 ? "battery.100percent" : percent > 62 ? "battery.75percent" : percent > 37 ? "battery.50percent" : percent > 12 ? "battery.25percent" : "battery.0percent"
        Image(systemName: charging ? "battery.100percent.bolt" : name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(charging ? .green : percent <= 20 ? .red : Color.primary, Color.primary.opacity(0.4))
    }
}

struct Sparkline: View {
    let points: [Double]
    let up: Bool
    var body: some View {
        GeometryReader { geo in
            if points.count > 1, let mn = points.min(), let mx = points.max() {
                let range = max(mx - mn, 0.0001)
                Path { p in
                    for (i, v) in points.enumerated() {
                        let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(points.count - 1),
                                         y: geo.size.height * (1 - CGFloat((v - mn) / range)))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(up ? Color.green : Color.red, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var appearance = AppearanceStore.shared
    @ObservedObject var widgets = WidgetLayout.shared
    @State private var dropTarget = false

    var body: some View {
        let g = model.geometry
        let side = (g.expandedSize.width - 68 - g.hardwareNotchWidth) / 2   // header room on each side of a built-in camera
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                TabBar(editing: widgets.editing)
                    .frame(width: g.avoidsCamera ? side : nil, alignment: .leading)

                // Opens around a built-in camera: tabs on its left, widgets and buttons on its right.
                if g.avoidsCamera { Color.clear.frame(width: g.hardwareNotchWidth + 8) } else { Spacer(minLength: 8) }

                if g.avoidsCamera {
                    // Right of a built-in camera: header widgets drop off the end until the row fits.
                    ViewThatFits(in: .horizontal) {
                        ForEach((0...widgets.widgets.count).reversed(), id: \.self) { n in widgetRow(Array(widgets.widgets.prefix(n))) }
                    }
                    .layoutPriority(1)
                } else {
                    widgetRow(widgets.widgets)
                }

                Spacer(minLength: 6)

                HStack(spacing: 9) {
                    if widgets.editing {
                        AddWidgetMenu()
                        Button { withAnimation { widgets.editing = false } } label: {
                            Text("Done").font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                        }.buttonStyle(.plain)
                    } else {
                        if model.tab == .shelf && Prefs.bool(AP.shelfStays) {
                            Button { NotchController.current?.collapse() } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(Color.primary.opacity(0.6))
                            }.buttonStyle(.plain).help("Close the Shelf")
                        }
                        Button { model.pinned.toggle() } label: {
                            Image(systemName: model.pinned ? "pin.fill" : "pin").foregroundStyle(model.pinned ? Color.yellow : Color.primary.opacity(0.6))
                        }.buttonStyle(.plain).help("Keep the notch open")
                        Button { (NSApp.delegate as? AppDelegate)?.openOptimization() } label: {
                            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Color.primary.opacity(0.6))
                        }.buttonStyle(.plain).help("Optimization")
                        Button { (NSApp.delegate as? AppDelegate)?.openSettings() } label: {
                            Image(systemName: "gearshape").foregroundStyle(Color.primary.opacity(0.6))
                        }.buttonStyle(.plain).help("Settings")
                        Menu {
                            Button { withAnimation { widgets.editing = true } } label: { Label("Edit Tabs & Widgets", systemImage: "square.grid.2x2") }
                            if model.tab == .home {
                                Button { withAnimation { HomeLayout.shared.editing = true } } label: { Label("Edit Home Boxes", systemImage: "rectangle.3.group") }
                            }
                            Divider()
                            Button { NSApp.terminate(nil) } label: { Label("Quit Onyx", systemImage: "power") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(Color.primary.opacity(0.6))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
            .frame(height: max(g.notchHeight - 4, 24))
            .padding(.top, 2)

            Group {
                switch model.tab {
                case .home: HomeTab()
                case .shelf: ShelfTab()
                case .ai: AITab()
                case .live: LiveTab()
                case .tools: ToolsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 14)
        .frame(width: g.expandedSize.width, height: g.expandedSize.height, alignment: .top)
        .overlay {
            if dropTarget && model.tab != .shelf {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
                    .overlay(Label("Drop to add to Shelf", systemImage: "tray.and.arrow.down.fill").font(.headline))
                    .background(.black.opacity(0.6))
            }
        }
        .overlay(alignment: .bottom) { ReminderBanner() }   // a reminder that's going off: Done / Snooze
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: OnyxReminders.shared.ringing)
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTarget) { providers in
            model.tab = .shelf
            return ShelfStore.shared.handleDrop(providers)
        }
    }

    private func widgetRow(_ list: [NotchWidget]) -> some View {
        HStack(spacing: 6) {
            ForEach(list) { w in
                ZStack(alignment: .topTrailing) {
                    HeaderWidgetView(widget: w)
                    if widgets.editing {
                        Button { widgets.toggle(w) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
                        }.buttonStyle(.plain).offset(x: 4, y: -4)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: widgets.widgets)
    }
}

/// The tab buttons on the left of the expanded header. In edit mode: drag to reorder, − to hide, + to add back.
struct TabBar: View {
    let editing: Bool
    @EnvironmentObject var model: NotchModel
    @ObservedObject var appearance = AppearanceStore.shared
    @State private var dragging: NotchTab?
    @State private var dragX: CGFloat = 0
    @State private var base: CGFloat = 0
    @State private var hoverWork: DispatchWorkItem?
    @State private var hoverTab: NotchTab?
    private let pitch: CGFloat = 48   // tab width + spacing

    var body: some View {
        let tabs = AP.enabledTabs
        HStack(spacing: 4) {
            ForEach(tabs) { t in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.tab = t }
                    if t == .ai { NotchController.current?.panel.makeKey(); model.focusRequest += 1 }
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 26)
                        .background(model.tab == t ? AP.accentColor.opacity(0.9) : .clear, in: Capsule())
                        .overlay { if editing { Capsule().strokeBorder(.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
                        .foregroundStyle(model.tab == t ? Color.white : Color.primary.opacity(0.55))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(editing ? "Drag to reorder" : t.title)
                // Resting on a tab briefly switches to it, so just passing over the bar doesn't
                // (clicking still switches instantly, and focuses AI's text box).
                .onHover { inside in
                    if inside {
                        hoverWork?.cancel(); hoverWork = nil; hoverTab = t
                        guard !editing, model.tab != t else { return }
                        let w = DispatchWorkItem { withAnimation(.snappy(duration: 0.2)) { model.tab = t } }
                        hoverWork = w
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
                    } else if hoverTab == t {   // enter/exit can arrive in either order between neighbors
                        hoverWork?.cancel(); hoverWork = nil; hoverTab = nil
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if editing && tabs.count > 1 {
                        Button { remove(t, from: tabs) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
                        }.buttonStyle(.plain).offset(x: 4, y: -4).help("Hide \(t.title)")
                    }
                }
                .offset(x: dragging == t ? dragX : 0)
                .zIndex(dragging == t ? 1 : 0)
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { v in drag(t, v.translation.width, tabs) }
                    .onEnded { _ in withAnimation(.snappy(duration: 0.2)) { dragging = nil; dragX = 0 } },
                    including: editing ? .all : .subviews)
            }
            let hidden = NotchTab.allCases.filter { !tabs.contains($0) }
            if editing && !hidden.isEmpty {
                Menu {
                    ForEach(hidden) { t in
                        Button { AP.setTabs(tabs + [t]) } label: { Label(t.title, systemImage: t.icon) }
                    }
                } label: { Image(systemName: "plus.circle.fill").foregroundStyle(.cyan) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add tab")
            }
        }
        .animation(.snappy(duration: 0.2), value: tabs)
    }

    private func remove(_ t: NotchTab, from tabs: [NotchTab]) {
        let rest = tabs.filter { $0 != t }
        AP.setTabs(rest)
        if model.tab == t, let first = rest.first { withAnimation(.snappy(duration: 0.2)) { model.tab = first } }
    }

    /// Live reorder: once the dragged tab passes a neighbor's midpoint, swap them.
    private func drag(_ t: NotchTab, _ w: CGFloat, _ tabs: [NotchTab]) {
        if dragging != t { dragging = t; base = 0 }
        let steps = Int(((w - base) / pitch).rounded())
        if steps != 0, let i = tabs.firstIndex(of: t) {
            let j = min(max(i + steps, 0), tabs.count - 1)
            if j != i {
                var n = tabs; n.remove(at: i); n.insert(t, at: j)
                AP.setTabs(n)
                base += CGFloat(j - i) * pitch
            }
        }
        dragX = w - base
    }
}

struct AddWidgetMenu: View {
    @ObservedObject var widgets = WidgetLayout.shared
    var body: some View {
        Menu {
            ForEach(NotchWidget.allCases) { w in
                Button { widgets.toggle(w) } label: {
                    Label(w.title, systemImage: widgets.contains(w) ? "checkmark" : w.icon)
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill").foregroundStyle(.cyan)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add widget")
    }
}
