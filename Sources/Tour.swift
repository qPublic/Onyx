import AppKit
import SwiftUI

// MARK: - The feature tour: the last step of onboarding (and menu bar icon › Take the Tour). Each slide plays a small
// live demo of one feature, then moves on by itself; hovering pauses it.

enum TourStep: Int, CaseIterable {
    case notch, media, shelf, ai, circle, widgets, notes, snap, wallpapers, create, launcher, optimize, more

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
        case .create: "Describe any place or game world and Onyx paints it and brings it to life as a seamless loop, all on your Mac."
        case .launcher: "Every app in a full-screen grid with folders and instant search. It can even take over ⌘Space."
        case .optimize: "Clean out caches, run maintenance and change hidden settings, all without Terminal."
        case .more: "Pick a style, size, widgets and shortcuts in Settings. Onyx keeps itself up to date."
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
        }
    }
}

struct FeatureTour: View {
    @Binding var step: Int
    @State private var elapsed = 0.0   // how long this slide has been up, not counting while you hover
    @State private var hovering = false
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
            guard !hovering else { return }   // hovering holds the slide; its demo keeps playing
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
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
            TourDemo(step: step, t: ctx.date.timeIntervalSince(born))
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
        .glassEffect(.regular, in: .capsule)
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
            .padding(10).frame(width: 220).glassEffect(.regular, in: .rect(cornerRadius: 12))
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
            .padding(10).frame(width: 240, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 12))
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
        c().padding(12).frame(width: 170, height: 86, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 16))
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
            .padding(14).frame(width: 190, height: 170, alignment: .topLeading).glassEffect(.regular.tint(.yellow.opacity(0.12)), in: .rect(cornerRadius: 16))
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
            .padding(8).glassEffect(.regular, in: .rect(cornerRadius: 12)).offset(y: 30).opacity(picker)
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
                .padding(6).glassEffect(.regular, in: .rect(cornerRadius: 10)).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
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
            .padding(10).frame(width: 330).glassEffect(.regular, in: .rect(cornerRadius: 12))
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
            .padding(.horizontal, 12).padding(.vertical, 7).frame(width: 260).glassEffect(.regular, in: .capsule)
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
        let items: [(String, String)] = [("timer", "Focus timer"), ("doc.on.clipboard", "Clipboard"), ("camera.fill", "Mirror"), ("airpods", "AirPods"),
                                          ("battery.75", "Battery"), ("arrow.down.circle", "Downloads"), ("icloud", "Settings sync"), ("arrow.triangle.2.circlepath", "Auto-updates"),
                                          ("paintpalette.fill", "Styles"), ("keyboard", "Shortcuts"), ("rectangle.split.2x1", "Snap"), ("music.note", "Dancing cow")]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(90), spacing: 10), count: 4), spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let pop = seg(t, 0.15 * Double(i), 0.15 * Double(i) + 0.35)
                VStack(spacing: 5) {
                    Image(systemName: item.0).font(.system(size: 18)).foregroundStyle(.teal)
                    Text(item.1).font(.system(size: 10))
                }
                .frame(width: 90, height: 52).glassEffect(.regular, in: .rect(cornerRadius: 12))
                .scaleEffect(0.8 + 0.2 * pop).opacity(pop)
            }
        }
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
