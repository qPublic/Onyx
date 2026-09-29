import AppKit
import SwiftUI

// MARK: - The feature tour: the last step of onboarding (and menu bar icon › Take the Tour). Each slide plays a small
// live demo of one feature, then moves on by itself; hovering pauses it.

enum TourStep: Int, CaseIterable {
    case notch, meetings, media, shelf, clipboard, ai, askAbout, briefing, calendarMail, circle, widgets, notes, focus, snap, workspaces, markup,
         wallpapers, create, livingWalls, launcher, launcherPlus, optimize, system, more

    var title: String {
        switch self {
        case .notch: "Your notch, reimagined"
        case .media: "Music, volume and brightness"
        case .shelf: "The Shelf"
        case .ai: "Onyx AI"
        case .circle: "Circle to Search"
        case .widgets: "Widgets that keep you posted"
        case .notes: "Notes and reminders"
        case .snap: "Snap layouts and screenshots"
        case .wallpapers: "Live Wallpapers"
        case .create: "Create a wallpaper with AI"
        case .launcher: "App Launcher"
        case .optimize: "Optimization"
        case .more: "Make it yours"
        case .meetings: "Never late for a call"
        case .clipboard: "Your clipboard, anywhere"
        case .askAbout: "Ask about anything"
        case .briefing: "Your daily briefing"
        case .calendarMail: "One calendar, every inbox"
        case .focus: "Focus sessions"
        case .workspaces: "Workspaces"
        case .markup: "Mark up and copy text"
        case .livingWalls: "Wallpapers that match outside"
        case .launcherPlus: "The launcher does more"
        case .system: "Battery and quick toggles"
        }
    }
    var body: String {
        switch self {
        case .notch: "Move your pointer to the top of the screen and the notch opens into Home, Shelf, AI, Live and Tools."
        case .media: "See what's playing and control it from the notch. Volume and brightness changes show up right there too."
        case .shelf: "Drop files on the notch to keep them handy, then drag them out wherever you need them."
        case .ai: "A private assistant that runs on your Mac. Type or just talk: it sets reminders, adds events and reads your screen."
        case .circle: "Circle anything on screen to search it, translate it or ask AI about it."
        case .widgets: "Weather that warns you before it rains, your next event, live scores, stocks and more."
        case .notes: "Quick notes in the notch that can sync with Apple Notes, and reminders that ring right in the notch."
        case .snap: "Drag a window to the notch to snap it into a layout. Take screenshots and recordings in one click."
        case .wallpapers: "Animated scenes or your own videos behind your desktop icons. They pause when you can't see them."
        case .create: "Describe any place or game world. Onyx paints it in your style, or one AI's Choice makes for it, and brings it to life as a sharp, seamless loop, all on your Mac."
        case .launcher: "Every app in a full-screen grid with folders and instant search. It can even take over ⌘Space."
        case .optimize: "Clean out caches, run maintenance and change hidden settings, all without Terminal."
        case .more: "Pick a style, size, widgets and shortcuts in Settings. Onyx keeps itself up to date."
        case .meetings: "2 minutes before a Zoom, Meet or Teams call on your calendar, the notch counts down. Open it and click Join."
        case .clipboard: "Press ⌃⌥V in any app to search everything you've copied, and paste it right where you are. Pin the ones you use a lot."
        case .askAbout: "Select text and press ⌃⌥S to summarize, explain, rewrite or translate it. Drop a PDF or Word file on the AI tab to ask about that."
        case .briefing: "Your weather, calendar, reminders and what's due on Canvas, in a few sentences. One waits for you each morning."
        case .calendarMail: "Sign in to all your Google accounts and see every calendar together. Onyx reads your email and puts plans, practices and invitations on your calendar by itself."
        case .focus: "Pick a time and the apps and sites that distract you. They're blocked until it's done, and finishing keeps your streak going."
        case .workspaces: "Save the apps and windows you use for school or work, then put them all back where they were in one click."
        case .markup: "Draw arrows and boxes on screenshots and blur private details. Press ⌃⌥T to copy the text out of anything on screen."
        case .livingWalls: "When it rains or snows where you are, so does your wallpaper. AI loops can switch to sunset and night versions with the real sun."
        case .launcherPlus: "Type math, \"timer 10\", \"define\" a word or a question and get it right there. Matching files show up too."
        case .system: "See your battery's health and what's using energy, and flip Dark Mode, Do Not Disturb, Keep awake and more in one click."
        }
    }
    var tint: Color {
        switch self {
        case .notch, .snap: .cyan
        case .media: .pink
        case .shelf, .notes: .yellow
        case .ai, .create: .purple
        case .circle: .blue
        case .widgets: .orange
        case .wallpapers: .indigo
        case .launcher: .mint
        case .optimize: .green
        case .more: .teal
        case .meetings: .green
        case .clipboard: .cyan
        case .askAbout: .purple
        case .briefing: .yellow
        case .calendarMail: .red
        case .focus: .indigo
        case .workspaces: .teal
        case .markup: .red
        case .livingWalls: .blue
        case .launcherPlus: .mint
        case .system: .green
        }
    }
}

struct FeatureTour: View {
    @Binding var step: Int
    @State private var elapsed = 0.0   // how long this slide has been up, not counting while you hover
    @State private var hovering = false
    static var ignoreHover = false   // the self-test: your pointer resting on its window mustn't hold the slides
    static let duration = 6.0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var last: Int { TourStep.allCases.count - 1 }

    var body: some View {
        let s = TourStep(rawValue: step) ?? .notch
            VStack(spacing: 16) {
                bars
                TourSlide(step: s)
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                    .background(RadialGradient(colors: [s.tint.opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 260))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                VStack(spacing: 6) {
                    Text(s.title).font(.system(size: 19, weight: .bold))
                    Text(s.body).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                }
                .id("text\(step)")
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            .padding(.horizontal, 24).padding(.top, 14)
        .onHover { hovering = $0 }
        .onReceive(tick) { _ in
            guard !hovering || Self.ignoreHover else { return }   // hovering holds the slide; its demo keeps playing
            elapsed += 0.1
            if elapsed >= Self.duration && step < last { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step += 1 } }
        }
        .onChange(of: step) { _, _ in elapsed = 0 }
    }

    /// Story-style progress: done segments full, the current one filling.
    private var bars: some View {
        HStack(spacing: 4) {
            ForEach(0...last, id: \.self) { i in
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.15))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.85))
                                .frame(width: g.size.width * (i < step ? 1 : i > step ? 0 : min(elapsed / Self.duration, 1)))
                                .animation(.linear(duration: 0.1), value: elapsed)
                        }
                }
                .frame(height: 3)
                .contentShape(Rectangle().inset(by: -6))
                .onTapGesture { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = i } }
            }
        }
    }
}

/// One slide's demo on its own clock, started when the slide appears, so the one sliding out keeps playing where it was
/// instead of jumping back to its start. 60 frames a second is plenty for these and half the work on a 120 Hz display.
private struct TourSlide: View {
    let step: TourStep
    @State private var born = Date()
    var body: some View {
        if Motion.reduced {
            TourDemo(step: step, t: 5.5)   // Reduce Motion: each demo as a still, finished frame
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                TourDemo(step: step, t: ctx.date.timeIntervalSince(born))
            }
        }
    }
}

// MARK: - The demos (each is a function of t, the seconds since its slide appeared)

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
/// Smooth 0→1 between times a and b.
private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { let x = clamp01((t - a) / (b - a)); return x * x * (3 - 2 * x) }
private func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }

struct TourDemo: View {
    let step: TourStep
    let t: Double
    /// Every demo plays once per loop. A loop is a little longer than a slide, so it only repeats while you hover, and
    /// then it fades out and back in rather than jumping to the start.
    static let loop = 6.5
    private var p: Double { t.truncatingRemainder(dividingBy: Self.loop) }
    private var fade: Double { (t < Self.loop ? 1 : seg(p, 0, 0.3)) * (1 - seg(p, Self.loop - 0.3, Self.loop)) }

    var body: some View {
        demo.opacity(fade)
    }

    @ViewBuilder private var demo: some View {
        switch step {
        case .notch: notch
        case .media: media
        case .shelf: shelf
        case .ai: ai
        case .circle: circle
        case .widgets: widgets
        case .notes: notes
        case .snap: snap
        case .wallpapers: wallpapers
        case .create: create
        case .launcher: launcher
        case .optimize: optimize
        case .more: more
        case .meetings: meeting
        case .clipboard: clipboard
        case .askAbout: askAbout
        case .briefing: briefing
        case .calendarMail: calendarMail
        case .focus: focusDemo
        case .workspaces: workspacesDemo
        case .markup: markupDemo
        case .livingWalls: livingWalls
        case .launcherPlus: launcherPlus
        case .system: systemDemo
        }
    }

    // A dark desktop with a menu bar, for demos that happen at the top of the screen.
    private func desktop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(colors: [Color(hex: "23233A"), Color(hex: "12121C")], startPoint: .top, endPoint: .bottom))
            Rectangle().fill(.white.opacity(0.06)).frame(height: 16)
            content()
        }
        .frame(width: 420, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pill(_ w: CGFloat, _ h: CGFloat, radius: CGFloat) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).fill(.black).frame(width: w, height: h)
    }

    private var notch: some View {
        let open = seg(p, 1.1, 1.6) * (1 - seg(p, 3.9, 4.3))
        return desktop {
            ZStack(alignment: .top) {
                pill(mix(110, 330, open), mix(24, 150, open), radius: mix(12, 26, open))
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach(["house.fill", "tray.full.fill", "sparkles", "sportscourt.fill", "square.grid.2x2.fill"], id: \.self) { i in
                            Image(systemName: i).font(.system(size: 12)).foregroundStyle(i == "house.fill" ? .white : .white.opacity(0.45))
                        }
                    }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Midnight City").font(.system(size: 12, weight: .semibold))
                            Text("M83").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            HStack(spacing: 12) { Image(systemName: "backward.fill"); Image(systemName: "pause.fill"); Image(systemName: "forward.fill") }.font(.system(size: 11))
                        }
                        Spacer()
                        VStack(spacing: 2) { Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor); Text("72°").font(.system(size: 11, weight: .semibold)) }
                    }
                    .frame(width: 290)
                }
                .padding(.top, 14)
                .opacity(seg(p, 1.4, 1.8) * (1 - seg(p, 3.8, 4.0)))
            }
            Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.white).shadow(radius: 2)
                .offset(x: mix(90, 10, seg(p, 0.2, 1.0)), y: mix(170, 20, seg(p, 0.2, 1.0)))
                .opacity(1 - seg(p, 1.6, 1.9) + seg(p, 4.2, 4.5))
        }
    }

    private var media: some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 110, height: 110)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<4, id: \.self) { i in
                                Capsule().fill(.white).frame(width: 4, height: 6 + 16 * abs(sin(t * (3.2 + Double(i) * 0.9) + Double(i))))
                            }
                        }
                        .frame(height: 24, alignment: .bottom).padding(8)
                    }
                Text("Midnight City").font(.system(size: 13, weight: .semibold))
                ProgressView(value: (t / 20).truncatingRemainder(dividingBy: 1) * 0.6 + 0.2).tint(.white).frame(width: 110)
            }
            VStack(spacing: 14) {
                hud("speaker.wave.2.fill", 0.55 + 0.2 * sin(t * 1.6))   // smooth back and forth, no jumps
                hud("sun.max.fill", 0.62 - 0.18 * sin(t * 1.2 + 1))
            }
        }
    }

    private func hud(_ icon: String, _ v: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 20)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.18)).overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * v) }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 14).frame(width: 190, height: 42)
        .tourGlass(Capsule())
    }

    private var shelf: some View {
        let fly = seg(p, 0.4, 1.4)
        return desktop {
            pill(300, 96, radius: 22)
            HStack(spacing: 10) {
                fileTile("doc.richtext.fill", "Essay.pdf", .red)
                fileTile("photo.fill", "IMG_2041", .blue)
                fileTile("doc.zipper", "Project.zip", .gray).opacity(seg(p, 1.3, 1.6))
            }
            .padding(.top, 22)
            fileTile("doc.zipper", "Project.zip", .gray)
                .scaleEffect(mix(1.25, 0.9, fly))
                .offset(x: mix(-150, 72, fly), y: mix(170, 22, fly) - 70 * CGFloat(sin(fly * .pi)))
                .opacity(1 - seg(p, 1.35, 1.5))
        }
    }

    private func fileTile(_ icon: String, _ name: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(c)
            Text(name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }
        .frame(width: 70, height: 56)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var ai: some View {
        let q = "Remind me to call Mom at 6"
        let typed = String(q.prefix(Int(clamp01((p - 0.3) / 1.6) * Double(q.count))))
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Spacer(); bubble(typed.isEmpty ? " " : typed, user: true) }
            bubble("Done. I'll remind you at 6:00 PM.", user: false).opacity(seg(p, 2.3, 2.7)).offset(y: 8 * (1 - seg(p, 2.3, 2.7)))
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                Text("Call Mom").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("6:00 PM").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10).frame(width: 220).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(seg(p, 3.0, 3.4)).scaleEffect(0.95 + 0.05 * seg(p, 3.0, 3.4))
            HStack(spacing: 3) {
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.purple)
                ForEach(0..<14, id: \.self) { i in Capsule().fill(.purple.opacity(0.8)).frame(width: 3, height: 4 + 12 * abs(sin(t * 5 + Double(i) * 0.7))) }
            }
            .frame(height: 18)
        }
        .frame(width: 340)
    }

    private func bubble(_ text: String, user: Bool) -> some View {
        Text(text).font(.system(size: 12.5)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(user ? Color.purple.opacity(0.55) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var circle: some View {
        let draw = seg(p, 0.5, 1.8)
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)).frame(width: 380, height: 220)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<3, id: \.self) { i in Capsule().fill(.white.opacity(0.18)).frame(width: [220, 260, 180][i], height: 7) }
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom)).frame(width: 90, height: 70)
                        Image(systemName: "leaf.fill").font(.system(size: 28)).foregroundStyle(.green)
                    }
                    .overlay {
                        Ellipse().trim(from: 0, to: draw).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 130, height: 104)
                    }
                    VStack(alignment: .leading, spacing: 7) { ForEach(0..<3, id: \.self) { i in Capsule().fill(.white.opacity(0.14)).frame(width: [120, 100, 130][i], height: 7) } }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Monstera deliciosa", systemImage: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("A tropical houseplant with split leaves.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(10).frame(width: 240, alignment: .leading).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .offset(y: 80 + 20 * (1 - seg(p, 2.1, 2.6))).opacity(seg(p, 2.1, 2.6))
        }
    }

    private var widgets: some View {
        let rain = seg(p, 2.0, 2.5)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                widget {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: rain > 0.5 ? "cloud.rain.fill" : "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 22))
                        Text("72°").font(.system(size: 20, weight: .semibold))
                        Text(rain > 0.5 ? "Rain in ~15 min" : "Seattle").font(.system(size: 10.5)).foregroundStyle(rain > 0.5 ? .cyan : .secondary)
                    }
                }
                widget {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXT").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        Text("Design review").font(.system(size: 12.5, weight: .semibold))
                        Text("2:30 – 3:00 PM").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                widget {
                    HStack {
                        VStack(alignment: .leading) { Text("SEA").font(.system(size: 11, weight: .bold)); Text("LAL").font(.system(size: 11, weight: .bold)) }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(88 + Int(t / 1.5) % 9)").font(.system(size: 13, weight: .semibold)).contentTransition(.numericText())
                            Text("\(84 + Int(t / 2.1) % 7)").font(.system(size: 13, weight: .semibold)).contentTransition(.numericText())
                        }
                    }
                }
                widget {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AAPL  +1.8%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                        TourSparkline(k: clamp01(t / 2.5)).stroke(.green, lineWidth: 2).frame(height: 30)
                    }
                }
            }
        }
    }

    private func widget<Content: View>(@ViewBuilder _ c: () -> Content) -> some View {
        c().padding(12).frame(width: 170, height: 86, alignment: .leading).tourGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var notes: some View {
        let text = "Grocery list\n• Oat milk\n• Basil\n• Coffee beans"
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(text.prefix(Int(clamp01((p - 0.2) / 2.2) * Double(text.count))))).font(.system(size: 12.5)).frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath").rotationEffect(.degrees(t * 120))
                    Text("Synced with Apple Notes").font(.system(size: 10))
                }
                .foregroundStyle(.yellow).opacity(seg(p, 2.6, 3.0))
            }
            .padding(14).frame(width: 190, height: 170, alignment: .topLeading).tourGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .yellow)
            ZStack(alignment: .top) {
                pill(170, 64, radius: 20)
                HStack(spacing: 8) {
                    Image(systemName: "bell.and.waves.left.and.right.fill").foregroundStyle(.orange).rotationEffect(.degrees(sin(t * 18) * 12 * (1 - seg(p, 4.2, 4.5))))
                    Text("Study for exam").font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.top, 22)
            }
            .opacity(seg(p, 3.3, 3.7))
        }
    }

    private var snap: some View {
        let drag = seg(p, 0.3, 1.3), picker = seg(p, 1.2, 1.5) * (1 - seg(p, 2.4, 2.6)), snapped = seg(p, 2.4, 2.9)
        return desktop {
            pill(110, 22, radius: 11)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6), lineWidth: 1).frame(width: 34, height: 22)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Color.cyan : .white.opacity(0.4)).frame(width: i == 2 ? 22 : 16).padding(2) }
                }
            }
            .padding(8).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous)).offset(y: 30).opacity(picker)
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.14)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25)))
                .overlay(alignment: .top) { HStack(spacing: 4) { ForEach(0..<3, id: \.self) { i in Circle().fill([Color.red, .yellow, .green][i]).frame(width: 7) } }.padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: mix(200, 205, snapped), height: mix(130, 208, snapped))
                .offset(x: mix(mix(40, 10, drag), -105, snapped), y: mix(mix(80, 34, drag), 18, snapped))
        }
    }

    private var wallpapers: some View {
        desktop {
            // All three stay made (a new Metal view each time was a hitch); only the one showing runs, and they cross-fade.
            let i = Int(t / 2.4) % 3
            ZStack {
                ForEach(0..<3, id: \.self) { k in
                    TourScene(scene: [WallpaperScene.synthwave, .rainCity, .pixelDusk][k], running: k == i)
                        .opacity(k == i ? 1 : 0).animation(.easeInOut(duration: 0.6), value: i)
                }
            }
            .frame(width: 420, height: 230)
            Rectangle().fill(.black.opacity(0.35)).frame(height: 16)
            HStack(spacing: 6) { ForEach(0..<7, id: \.self) { _ in RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.5)).frame(width: 18, height: 18) } }
                .padding(6).tourGlass(RoundedRectangle(cornerRadius: 10, style: .continuous)).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
        }
    }

    private var create: some View {
        // Four versions of what's typed: retro sunsets, from two of the built-in scenes at different moments.
        let idea = "a retro sunset on the horizon"
        let typed = String(idea.prefix(Int(clamp01((p - 0.2) / 1.4) * Double(idea.count))))
        let versions: [(WallpaperScene, Float)] = [(.pixelDusk, 14), (.synthwave, 14), (.pixelDusk, 31), (.synthwave, 27)]
        return VStack(spacing: 10) {
            HStack {
                Image(systemName: "wand.and.sparkles").foregroundStyle(.purple)
                Text(typed.isEmpty ? " " : typed).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).frame(width: 330).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                ForEach(Array(["camera.fill", "sparkles", "paintbrush.pointed.fill", "cube.fill"].enumerated()), id: \.offset) { i, icon in
                    Image(systemName: icon).font(.system(size: 11)).frame(width: 30, height: 22)
                        .background(i == 0 ? Color.cyan.opacity(0.35) : .white.opacity(0.08), in: Capsule())
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    TourStill(scene: versions[i].0, time: versions[i].1).frame(width: 76, height: 50).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay { if i == 0 && p > 3.4 { RoundedRectangle(cornerRadius: 8).stroke(.cyan, lineWidth: 2) } }
                        .opacity(seg(p, 1.8 + Double(i) * 0.3, 2.1 + Double(i) * 0.3)).scaleEffect(0.9 + 0.1 * seg(p, 1.8 + Double(i) * 0.3, 2.1 + Double(i) * 0.3))
                }
            }
            HStack(spacing: 8) {
                Text("Animating the loop…").font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressView(value: seg(p, 3.8, 5.6)).tint(.cyan).frame(width: 160)
            }
            .opacity(seg(p, 3.6, 3.8))
        }
    }

    private var launcher: some View {
        let apps = ["Safari", "Music", "Photos", "Maps", "Notes", "Calendar", "Messages", "Mail", "FaceTime", "App Store", "Weather", "Freeform"]
        let q = "saf"
        let typed = String(q.prefix(Int(clamp01((p - 2.6) / 0.6) * 3)))
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text(typed.isEmpty ? "Search" : typed).font(.system(size: 12)).foregroundStyle(typed.isEmpty ? .secondary : .primary)
                Spacer()
                Text("⌘Space").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 12).padding(.vertical, 7).frame(width: 260).tourGlass(Capsule())
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 12), count: 6), spacing: 10) {
                ForEach(Array(apps.enumerated()), id: \.offset) { i, name in
                    let pop = seg(p, 0.2 + Double(i) * 0.06, 0.5 + Double(i) * 0.06)
                    let dim = !typed.isEmpty && !name.lowercased().hasPrefix(typed)
                    VStack(spacing: 3) {
                        AppIcon(name: name).frame(width: 40, height: 40)
                        Text(name).font(.system(size: 8.5)).lineLimit(1)
                    }
                    .scaleEffect(0.6 + 0.4 * pop).opacity(pop * (dim ? 0.2 : 1))
                }
            }
        }
    }

    private var optimize: some View {
        let k = seg(p, 0.4, 2.4)
        return HStack(spacing: 26) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 12)
                Circle().trim(from: 0, to: 0.72 - 0.22 * k).stroke(AngularGradient(colors: [.green, .mint], center: .center), style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int((72 - 22 * k).rounded()))%").font(.system(size: 22, weight: .bold)).contentTransition(.numericText())
                    Text("disk used").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array([("App caches", "1.2 GB"), ("Logs", "340 MB"), ("Old downloads", "2.6 GB")].enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 8) {
                        Image(systemName: p > 0.8 + Double(i) * 0.5 ? "checkmark.circle.fill" : "circle").foregroundStyle(.green)
                        Text(row.0).font(.system(size: 12))
                        Spacer()
                        Text(row.1).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("Freed 4.1 GB").font(.system(size: 13, weight: .semibold)).foregroundStyle(.green).opacity(seg(p, 2.4, 2.8))
            }
            .frame(width: 190)
        }
    }

    private var more: some View {
        let items: [(String, String)] = [("cloud.rain", "Rain alerts"), ("battery.25", "Low Battery Mode"), ("camera.fill", "Mirror"), ("airpods", "AirPods"),
                                          ("clock.arrow.circlepath", "Auto-close"), ("arrow.down.circle", "Downloads"), ("icloud", "Settings sync"), ("arrow.triangle.2.circlepath", "Auto-updates"),
                                          ("paintpalette.fill", "Styles"), ("keyboard", "Shortcuts"), ("pin.fill", "Pinned apps"), ("music.note", "Dancing cow")]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(90), spacing: 10), count: 4), spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let pop = seg(t, 0.15 * Double(i), 0.15 * Double(i) + 0.35)
                VStack(spacing: 5) {
                    Image(systemName: item.0).font(.system(size: 18)).foregroundStyle(.teal)
                    Text(item.1).font(.system(size: 10))
                }
                .frame(width: 90, height: 52).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(0.8 + 0.2 * pop).opacity(pop)
            }
        }
    }
}

/// A light stand-in for Liquid Glass in the demos: real glass redrawn 60 times a second took about 40% of a CPU core.
private extension View {
    func tourGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        background((tint ?? .white).opacity(tint == nil ? 0.1 : 0.16), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
    }
}

private struct TourSparkline: Shape {
    var k: Double
    func path(in r: CGRect) -> Path {
        let ys: [CGFloat] = [0.7, 0.55, 0.62, 0.4, 0.48, 0.3, 0.36, 0.18, 0.25, 0.1]
        var p = Path()
        let n = max(2, Int(Double(ys.count - 1) * k) + 1)
        for i in 0..<n {
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(ys.count - 1), y: r.minY + r.height * ys[i])
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// The real icon of an app in /System/Applications or /Applications, by name.
private struct AppIcon: View {
    let name: String
    @MainActor private static var cache: [String: NSImage] = [:]
    var body: some View {
        if let img = Self.icon(name) { Image(nsImage: img).resizable() } else { RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.2)) }
    }
    @MainActor static func icon(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        let path = ["/System/Applications/\(name).app", "/Applications/\(name).app", "/System/Applications/Utilities/\(name).app"]
            .first { FileManager.default.fileExists(atPath: $0) }
        let img = path.map { NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }   // Safari is a link on macOS 26
        cache[name] = img
        return img
    }
}

/// A live GPU scene inside the tour.
private struct TourScene: NSViewRepresentable {
    let scene: WallpaperScene
    var running = true
    func makeNSView(context: Context) -> ShaderView { let v = ShaderView(scene: scene, frame: .zero); v.setRunning(running); return v }
    func updateNSView(_ v: ShaderView, context: Context) { v.setRunning(running) }
}

/// A still of a GPU scene, standing in for a painting in the Create demo.
private struct TourStill: View {
    let scene: WallpaperScene
    var time: Float = 14
    @MainActor private static var cache: [String: CGImage] = [:]
    var body: some View {
        if let cg = Self.still(scene, time) { Image(decorative: cg, scale: 1).resizable() } else { Color.white.opacity(0.1) }
    }
    @MainActor static func still(_ s: WallpaperScene, _ time: Float) -> CGImage? {
        let key = "\(s.rawValue)@\(time)"
        if let c = cache[key] { return c }
        let img = GPU.snapshot(s, size: CGSize(width: 152, height: 100), time: time)
        cache[key] = img
        return img
    }
}

// MARK: - Demos for the features added in 1.7

/// A steady pseudo-random number in 0…1 for particle i (so rain and stars don't jump around between frames).
private func rnd(_ i: Int, _ k: Double) -> Double { let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453; return v - floor(v) }

private struct TourArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + 6, y: r.maxY - 6))
        p.move(to: CGPoint(x: r.minX + 6, y: r.maxY - 6)); p.addLine(to: CGPoint(x: r.minX + 20, y: r.maxY - 8))
        p.move(to: CGPoint(x: r.minX + 6, y: r.maxY - 6)); p.addLine(to: CGPoint(x: r.minX + 9, y: r.maxY - 20))
        return p
    }
}

extension TourDemo {
    fileprivate var meeting: some View {
        let open = seg(p, 2.4, 2.9) * (1 - seg(p, 4.6, 5.0))
        let secs = max(0, 119 - Int(p)), clock = "\(secs / 60):" + String(format: "%02d", secs % 60)
        let click = seg(p, 4.2, 4.35) * (1 - seg(p, 4.35, 4.5))
        return desktop {
            ZStack(alignment: .top) {
                pill(mix(210, 340, open), mix(24, 92, open), radius: mix(12, 24, open))
                HStack {
                    Image(systemName: "video.fill").foregroundStyle(.green)
                    Spacer()
                    Text("in \(clock)").monospacedDigit().foregroundStyle(.green)
                }
                .font(.system(size: 11, weight: .semibold)).frame(width: 180).padding(.top, 5)
                .opacity(1 - seg(p, 2.4, 2.6))
                HStack(spacing: 10) {
                    Image(systemName: "video.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Design review").font(.system(size: 12, weight: .semibold))
                        Text("Starts in \(clock) · Zoom").font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text("Join").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.green, in: Capsule()).scaleEffect(1 - 0.12 * click)
                }
                .frame(width: 290).padding(.top, 36)
                .opacity(seg(p, 2.8, 3.1) * (1 - seg(p, 4.6, 4.8)))
            }
            Label("Joining Zoom…", systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 9).tourGlass(Capsule())
                .offset(y: 110).opacity(seg(p, 4.8, 5.1))
            Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.white).shadow(radius: 2)
                .offset(x: mix(mix(150, 0, seg(p, 1.4, 2.3)), 128, seg(p, 3.1, 3.9)), y: mix(mix(185, 14, seg(p, 1.4, 2.3)), 50, seg(p, 3.1, 3.9)))
                .opacity(1 - seg(p, 4.6, 4.8))
        }
    }

    fileprivate var clipboard: some View {
        let show = seg(p, 0.9, 1.2) * (1 - seg(p, 3.2, 3.4))
        let sel = p < 1.8 ? 0 : p < 2.4 ? 1 : 2
        let rows = [("link", "onyx.app/notes/3"), ("mappin.and.ellipse", "123 Main St"), ("envelope", "hello@onyx.app"), ("text.quote", "Thanks so much!")]
        return ZStack {
            VStack(alignment: .leading, spacing: 7) {
                Text("To: Sam").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Text("You can reach me at").font(.system(size: 12.5))
                Text(verbatim: "hello@onyx.app").font(.system(size: 12.5)).foregroundStyle(.cyan).opacity(seg(p, 3.3, 3.5))
                Spacer()
            }
            .padding(14).frame(width: 330, height: 200, alignment: .topLeading).tourGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("⌃⌥V").font(.system(size: 16, weight: .bold, design: .rounded)).padding(.horizontal, 12).padding(.vertical, 6)
                .tourGlass(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(seg(p, 0.4, 0.6) * (1 - seg(p, 1.0, 1.2))).offset(y: 40)
            VStack(spacing: 3) {
                HStack(spacing: 6) { Image(systemName: "magnifyingglass"); Text("Search your clipboard").foregroundStyle(.secondary); Spacer() }
                    .font(.system(size: 11)).padding(7).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 7) { Image(systemName: r.0).frame(width: 14).foregroundStyle(.secondary); Text(r.1); Spacer() }
                        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(i == sel ? Color.accentColor.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8).frame(width: 250)
            .background(Color(hex: "1C1C28").opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .scaleEffect(0.94 + 0.06 * show).opacity(show).offset(y: 34)
        }
    }

    fileprivate var launcherPlus: some View {
        let first = p < 3.3
        let q = first ? "15% of 80" : "timer 10", start = first ? 0.3 : 3.4
        let typed = String(q.prefix(Int(clamp01((p - start) / 0.8) * Double(q.count))))
        let card = first ? seg(p, 1.2, 1.5) * (1 - seg(p, 3.0, 3.3)) : seg(p, 4.3, 4.6)
        return VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text(typed.isEmpty ? "Search" : typed).font(.system(size: 12)).foregroundStyle(typed.isEmpty ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7).frame(width: 260).tourGlass(Capsule())
            HStack(spacing: 12) {
                Image(systemName: first ? "equal.circle.fill" : "timer").font(.system(size: 20)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(first ? "12" : "Start a 10-minute timer").font(.system(size: first ? 20 : 14, weight: .semibold))
                    Text(first ? "15% of 80 = 12 · ↩ copies it" : "Counts down in the notch").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9).frame(width: 330).tourGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(card).offset(y: 6 * (1 - card))
            Label("Copied 12", systemImage: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(.orange).opacity(seg(p, 2.0, 2.2) * (1 - seg(p, 3.0, 3.2)))
        }
    }

    fileprivate var askAbout: some View {
        let sel = seg(p, 0.3, 1.2), panel = seg(p, 1.7, 2.0), answer = seg(p, 3.0, 3.4)
        let widths: [CGFloat] = [140, 150, 128, 146, 90, 134]
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(.white.opacity(0.2)).frame(width: widths[i], height: 7)
                        .overlay(alignment: .leading) {
                            if (1...3).contains(i) { Capsule().fill(.cyan.opacity(0.5)).frame(width: widths[i] * CGFloat(clamp01(sel * 3 - Double(i - 1)))) }
                        }
                }
            }
            .padding(14).frame(width: 175, height: 160, alignment: .topLeading).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) {
                Text("⌃⌥S").font(.system(size: 14, weight: .bold, design: .rounded)).padding(.horizontal, 10).padding(.vertical, 5)
                    .tourGlass(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(10)
                    .opacity(seg(p, 1.2, 1.4) * (1 - seg(p, 1.9, 2.1)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Selected text · 64 words", systemImage: "text.quote").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.cyan)
                HStack(spacing: 4) {
                    ForEach(["Summarize", "Explain", "Rewrite", "Translate"], id: \.self) { c in
                        Text(c).font(.system(size: 9.5, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.cyan.opacity(c == "Summarize" && p > 2.5 ? 0.55 : 0.18), in: Capsule())
                    }
                }
                bubble("The launch moved to March 14 because a supplier was late.", user: false).opacity(answer).offset(y: 6 * (1 - answer))
                Label("Or drop a PDF or Word file on the AI tab", systemImage: "doc.fill").font(.system(size: 9.5)).foregroundStyle(.secondary).opacity(seg(p, 3.9, 4.3))
            }
            .frame(width: 250, alignment: .leading).opacity(panel)
        }
    }

    fileprivate var briefing: some View {
        let text = "Good morning! It's 66° and clear. Design review at 10, and your Bio lab is due tomorrow."
        let typed = String(text.prefix(Int(clamp01((p - 1.1) / 2.0) * Double(text.count))))
        let facts: [(String, Color, String)] = [("sun.max.fill", .yellow, "66°"), ("calendar", .red, "10:00"), ("graduationcap.fill", .blue, "Due"), ("bell.fill", .orange, "2")]
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                    let pop = seg(p, 0.2 + Double(i) * 0.15, 0.5 + Double(i) * 0.15)
                    VStack(spacing: 3) {
                        Image(systemName: f.0).font(.system(size: 17)).foregroundStyle(f.1).symbolRenderingMode(.multicolor)
                        Text(f.2).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(width: 58, height: 50).tourGlass(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .scaleEffect(0.8 + 0.2 * pop).opacity(pop)
                }
            }
            Text(typed.isEmpty ? " " : typed).font(.system(size: 12.5)).padding(.horizontal, 12).padding(.vertical, 9)
                .frame(width: 340, alignment: .leading).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            Label("Waiting in the AI tab each morning", systemImage: "sun.horizon.fill").font(.system(size: 10.5)).foregroundStyle(.yellow)
                .opacity(seg(p, 3.4, 3.8))
        }
    }

    // Three accounts' calendars become one, then an email from a careful sender turns into an event.
    fileprivate var calendarMail: some View {
        let accounts: [(String, Color)] = [("you@gmail.com", .blue), ("you@school.org", .green), ("iCloud", .gray)]
        let rows: [(String, String, Color, Double)] = [("9:00 AM", "Bio class", .green, 1.0), ("12:30 PM", "Lunch with Maya", .blue, 1.25),
                                                        ("4:00 PM", "Soccer practice", .red, -1), ("6:00 PM", "Family dinner", .gray, 1.5)]
        let mail = seg(p, 2.4, 2.9), fly = seg(p, 3.5, 4.3)
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(accounts.enumerated()), id: \.offset) { i, a in
                    let pop = seg(p, 0.2 + Double(i) * 0.2, 0.5 + Double(i) * 0.2)
                    Label(a.0, systemImage: "person.crop.circle.fill").font(.system(size: 10.5, weight: .medium)).foregroundStyle(a.1)
                        .padding(.horizontal, 9).padding(.vertical, 6).tourGlass(Capsule())
                        .opacity(pop).offset(x: -16 * (1 - pop))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        Text("Coach Rivera").font(.system(size: 10.5, weight: .semibold))
                    }
                    Text("Practice moved to Thursday at 4:00 PM").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(9).frame(width: 175, alignment: .leading).tourGlass(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .opacity(mail * (1 - 0.5 * fly)).offset(y: 10 * (1 - mail)).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Thursday").font(.system(size: 12, weight: .semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    let show = r.3 < 0 ? fly : seg(p, r.3, r.3 + 0.35)
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(r.2).frame(width: 3, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.1).font(.system(size: 10.5, weight: .medium))
                            Text(r.0).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if r.3 < 0 { Image(systemName: "envelope.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
                    }
                    .opacity(show).offset(x: r.3 < 0 ? -50 * (1 - fly) : 0)
                    .frame(height: r.3 < 0 ? 28 * fly : 28, alignment: .top).clipped()
                }
            }
            .padding(12).frame(width: 190, alignment: .leading).tourGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    fileprivate var livingWalls: some View {
        let night = seg(p, 3.2, 4.2), rain = 1 - seg(p, 2.6, 3.2), time = t
        return ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                let full = Path(CGRect(origin: .zero, size: size))
                ctx.fill(full, with: .linearGradient(Gradient(colors: [Color(hex: "5E7894"), Color(hex: "A7B2BF")]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                var n = ctx; n.opacity = night
                n.fill(full, with: .linearGradient(Gradient(colors: [Color(hex: "0A0E2A"), Color(hex: "3A2A55")]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                for i in 0..<45 where night > 0 {
                    let tw = 0.6 + 0.4 * sin(time * 2 + Double(i))
                    n.opacity = night * tw
                    n.fill(Path(ellipseIn: CGRect(x: rnd(i, 1) * size.width, y: rnd(i, 2) * size.height * 0.55, width: 2, height: 2)), with: .color(.white))
                }
                var hills = Path()
                hills.move(to: CGPoint(x: 0, y: size.height * 0.72))
                hills.addQuadCurve(to: CGPoint(x: size.width * 0.5, y: size.height * 0.7), control: CGPoint(x: size.width * 0.25, y: size.height * 0.55))
                hills.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.66), control: CGPoint(x: size.width * 0.78, y: size.height * 0.82))
                hills.addLine(to: CGPoint(x: size.width, y: size.height)); hills.addLine(to: CGPoint(x: 0, y: size.height)); hills.closeSubpath()
                ctx.fill(hills, with: .color(Color(hex: night > 0.5 ? "0D1320" : "2F3B34")))
                for i in 0..<70 where rain > 0 {
                    let x = rnd(i, 3) * (size.width + 40), y = (rnd(i, 4) * size.height + time * 380 * (0.8 + 0.4 * rnd(i, 5))).truncatingRemainder(dividingBy: size.height + 30) - 15
                    var l = Path(); l.move(to: CGPoint(x: x, y: y)); l.addLine(to: CGPoint(x: x - 3, y: y + 13))
                    ctx.stroke(l, with: .color(.white.opacity(0.4 * rain)), lineWidth: 1)
                }
            }
            .frame(width: 420, height: 230).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Label(p < 3.0 ? "Raining where you are" : "After sunset", systemImage: p < 3.0 ? "cloud.rain.fill" : "moon.stars.fill")
                .font(.system(size: 10.5, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5).tourGlass(Capsule()).padding(10)
        }
    }

    fileprivate var focusDemo: some View {
        let blocked = seg(p, 1.8, 2.2), streak = seg(p, 3.8, 4.2)
        return HStack(spacing: 24) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 8)
                Circle().trim(from: 0, to: 1 - p / 90).stroke(.indigo, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("24:" + String(format: "%02d", 59 - Int(p))).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Focus").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in Circle().fill([Color.red, .yellow, .green][i]).frame(width: 6) }
                        Text("youtube.com").font(.system(size: 9.5)).padding(.horizontal, 8).padding(.vertical, 2).background(Color.white.opacity(0.1), in: Capsule()).padding(.leading, 6)
                        Spacer()
                    }
                    .padding(7)
                    ZStack {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 30)).foregroundStyle(.red).opacity(1 - blocked)
                        VStack(spacing: 4) {
                            Image(systemName: "hand.raised.fill").font(.system(size: 20)).foregroundStyle(.indigo)
                            Text("Blocked · 23 min left").font(.system(size: 10.5, weight: .semibold))
                        }
                        .opacity(blocked)
                    }
                    .frame(height: 78)
                }
                .frame(width: 220).tourGlass(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("🔥 5-day streak").font(.system(size: 13, weight: .semibold)).scaleEffect(0.8 + 0.2 * streak).opacity(streak)
            }
        }
    }

    fileprivate var workspacesDemo: some View {
        let k = seg(p, 1.8, 2.8), click = seg(p, 1.4, 1.55) * (1 - seg(p, 1.55, 1.7))
        let from: [CGRect] = [CGRect(x: 40, y: 50, width: 150, height: 100), CGRect(x: 230, y: 80, width: 140, height: 90), CGRect(x: 120, y: 115, width: 170, height: 90)]
        let to: [CGRect] = [CGRect(x: 8, y: 22, width: 200, height: 200), CGRect(x: 212, y: 22, width: 200, height: 98), CGRect(x: 212, y: 124, width: 200, height: 98)]
        let looks: [(String, Color)] = [("doc.text.fill", .blue), ("safari.fill", .cyan), ("music.note", .pink)]
        return desktop {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8).fill(looks[i].1.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25)))
                        .overlay { Image(systemName: looks[i].0).font(.system(size: 22)).foregroundStyle(looks[i].1) }
                        .overlay(alignment: .topLeading) { HStack(spacing: 3) { ForEach(0..<3, id: \.self) { j in Circle().fill([Color.red, .yellow, .green][j]).frame(width: 6) } }.padding(6) }
                        .frame(width: mix(from[i].width, to[i].width, k), height: mix(from[i].height, to[i].height, k))
                        .position(x: mix(from[i].midX, to[i].midX, k), y: mix(from[i].midY, to[i].midY, k))
                }
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group.fill").foregroundStyle(.teal)
                    Text("School").font(.system(size: 11.5, weight: .semibold))
                    Text("Open").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.teal, in: Capsule()).scaleEffect(1 - 0.12 * click)
                }
                .padding(.horizontal, 10).padding(.vertical, 6).tourGlass(Capsule())
                .position(x: 210, y: 200).opacity(1 - seg(p, 3.0, 3.4))
            }
            .frame(width: 420, height: 230)
        }
    }

    fileprivate var systemDemo: some View {
        let h = seg(p, 0.2, 1.2)
        let toggles: [(String, String, Color)] = [("moon.fill", "Dark Mode", .indigo), ("moon.zzz.fill", "Do Not Disturb", .purple), ("cup.and.saucer.fill", "Keep awake", .orange),
                                                  ("eye.slash.fill", "Hide icons", .teal), ("mic.slash.fill", "Mute mic", .red)]
        return HStack(spacing: 26) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 9)
                    Circle().trim(from: 0, to: 0.98 * h).stroke(.green, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int((98 * h).rounded()))%").font(.system(size: 20, weight: .bold)).monospacedDigit()
                        Text("health").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                Text("12 cycles · 30 °C").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(Array(toggles.enumerated()), id: \.offset) { i, tg in
                    let on = seg(p, 1.5 + Double(i) * 0.45, 1.75 + Double(i) * 0.45)
                    HStack(spacing: 8) {
                        Image(systemName: tg.0).frame(width: 16)
                        Text(tg.1).font(.system(size: 11))
                        Spacer()
                        Capsule().fill(Color.white.opacity(0.2)).frame(width: 26, height: 15)
                            .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 11).offset(x: 2 + 11 * on) }
                    }
                    .padding(.horizontal, 10).frame(width: 200, height: 28)
                    .background(tg.2.opacity(0.75 * on), in: RoundedRectangle(cornerRadius: 8))
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    fileprivate var markupDemo: some View {
        let arrow = seg(p, 0.4, 1.2), box = seg(p, 1.4, 2.1), blur = seg(p, 2.3, 2.8), toast = seg(p, 3.6, 3.9)
        let tool = p < 1.3 ? 2 : p < 2.2 ? 3 : 4
        return ZStack {
            VStack(alignment: .leading, spacing: 9) {
                Text("Order #4417").font(.system(size: 14, weight: .bold))
                Capsule().fill(.black.opacity(0.15)).frame(width: 200, height: 7)
                Capsule().fill(.black.opacity(0.15)).frame(width: 160, height: 7)
                HStack(spacing: 6) {
                    Text("Email:").font(.system(size: 11.5))
                    Text(verbatim: "sam.lee@mail.com").font(.system(size: 11.5))
                        .overlay {
                            HStack(spacing: 0) { ForEach(0..<12, id: \.self) { i in Rectangle().fill(Color(white: 0.35 + 0.35 * rnd(i, 7))) } }
                                .opacity(blur)
                        }
                }
                Text("Total: $86.20").font(.system(size: 12, weight: .semibold))
                    .overlay { RoundedRectangle(cornerRadius: 4).trim(from: 0, to: box).stroke(.red, lineWidth: 2.5).padding(-5) }
            }
            .foregroundStyle(.black)
            .padding(16).frame(width: 300, height: 160, alignment: .topLeading)
            .background(Color.white.opacity(0.93), in: RoundedRectangle(cornerRadius: 10))
            TourArrow().trim(from: 0, to: arrow).stroke(.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 80, height: 46).offset(x: 110, y: -46)
            HStack(spacing: 8) {
                ForEach(Array(["pencil.tip", "highlighter", "arrow.up.right", "rectangle", "mosaic"].enumerated()), id: \.offset) { i, icon in
                    Image(systemName: icon).font(.system(size: 11)).frame(width: 22, height: 20)
                        .background(i == tool && p < 3.0 ? Color.red.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(5).tourGlass(Capsule()).offset(y: -104)
            Label("Copied 4 lines of text", systemImage: "text.viewfinder").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7).tourGlass(Capsule()).offset(y: 102).opacity(toast)
        }
    }
}
