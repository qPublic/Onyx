import AppKit
import SwiftUI

// MARK: - Vinyl record Now Playing

/// Album art as the label of a spinning record (33⅓ RPM = 200°/s), with a tonearm that drops while playing.
struct VinylView: View {
    var size: CGFloat
    @ObservedObject var media = MediaController.shared
    @State private var base = 0.0
    @State private var since: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !media.isPlaying)) { ctx in
            let angle = base + (since.map { ctx.date.timeIntervalSince($0) } ?? 0) * 200
            record.rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
        .overlay {   // static light reflection (doesn't spin)
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear],
                                          center: .center))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) { tonearm }
        .frame(width: size, height: size)
        .onAppear { if media.isPlaying { since = Date() } }
        .onChange(of: media.isPlaying) { _, playing in
            if playing { since = Date() }
            else if let s = since { base += Date().timeIntervalSince(s) * 200; since = nil }
        }
    }

    private var record: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.17), Color(white: 0.04)], center: .center,
                                         startRadius: 0, endRadius: size / 2))
            ForEach(0..<7, id: \.self) { i in
                Circle().stroke(.white.opacity(i.isMultiple(of: 2) ? 0.07 : 0.035), lineWidth: 0.6)
                    .padding(size * 0.05 + CGFloat(i) * size * 0.04)
            }
            AlbumArt(size: size * 0.4, radius: size * 0.2)
            Circle().fill(Color(white: 0.08)).frame(width: size * 0.05)
        }
        .frame(width: size, height: size)
    }

    private var tonearm: some View {
        ZStack(alignment: .top) {
            Capsule().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 0.035, height: size * 0.62)
            Circle().fill(Color(white: 0.7)).frame(width: size * 0.12)
        }
        .rotationEffect(.degrees(media.isPlaying ? 24 : 6), anchor: .top)
        .offset(x: size * 0.02, y: -size * 0.04)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: media.isPlaying)
        .allowsHitTesting(false)
    }
}

// MARK: - Bomb timer

/// The focus timer as a cartoon bomb whose fuse burns down with the remaining time.
struct BombTimerView: View {
    @ObservedObject var t = FocusTimer.shared
    var size: CGFloat = 108

    private var fraction: Double {
        guard t.running, t.total > 0 else { return 1 }
        return max(0, min(1, t.remaining / t.total))
    }

    // Unit-space geometry (0…1 of `size`).
    private let center = CGPoint(x: 0.42, y: 0.62), radius = 0.3
    private func fusePath(_ s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.66 * s, y: 0.37 * s))
        p.addQuadCurve(to: CGPoint(x: 0.95 * s, y: 0.1 * s), control: CGPoint(x: 0.7 * s, y: 0.06 * s))
        return p
    }

    var body: some View {
        let burning = t.running && t.pausedRemaining == nil
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !burning)) { ctx in
            let s = size
            let fuse = fusePath(s)
            let tip = fuse.trimmedPath(from: 0, to: fraction).currentPoint ?? .zero
            ZStack {
                fuse.trimmedPath(from: 0, to: fraction)
                    .stroke(Color(red: 0.72, green: 0.58, blue: 0.38), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                fuse.trimmedPath(from: 0, to: fraction)
                    .stroke(Color(red: 0.93, green: 0.84, blue: 0.62), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 2.5]))
                // Cap where the fuse enters.
                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.3))
                    .frame(width: s * 0.13, height: s * 0.09)
                    .rotationEffect(.degrees(45))
                    .position(x: 0.635 * s, y: 0.405 * s)
                // Body.
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.38), Color(white: 0.08), .black],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: s * 0.32))
                    .frame(width: s * radius * 2, height: s * radius * 2)
                    .overlay(alignment: .topLeading) {
                        Ellipse().fill(.white.opacity(0.35)).frame(width: s * 0.12, height: s * 0.07)
                            .rotationEffect(.degrees(-30)).offset(x: s * 0.1, y: s * 0.1)
                    }
                    .position(x: center.x * s, y: center.y * s)
                Text(t.running ? format(t.remaining) : "0:00")
                    .font(.system(size: s * 0.15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .position(x: center.x * s, y: center.y * s)
                if t.running { spark(at: tip, date: ctx.date, lit: burning) }
            }
            .frame(width: s, height: s)
        }
    }

    @ViewBuilder private func spark(at p: CGPoint, date: Date, lit: Bool) -> some View {
        let tick = date.timeIntervalSinceReferenceDate
        let flicker = lit ? 0.75 + 0.25 * sin(tick * 37) : 0.5
        ZStack {
            Circle().fill(.orange.opacity(0.55)).frame(width: 18 * flicker, height: 18 * flicker).blur(radius: 4)
            Circle().fill(.yellow).frame(width: 7 * flicker, height: 7 * flicker)
            if lit {
                ForEach(0..<5, id: \.self) { i in
                    let a = Double(i) * 1.26 + tick * 9
                    let d = 5 + 5 * abs(sin(tick * 13 + Double(i)))
                    Circle().fill(i.isMultiple(of: 2) ? Color.yellow : .orange)
                        .frame(width: 2.2, height: 2.2)
                        .offset(x: cos(a) * d, y: sin(a) * d)
                }
            }
        }
        .position(p)
    }
}

// MARK: - Big red button (with a flip-up safety cover)

enum RedButtonAction {
    /// Graceful shutdown (apps can still ask to save). ONYX_REDBUTTON_DRYRUN=<file> logs instead, for testing.
    static func shutdown() {
        if let p = ProcessInfo.processInfo.environment["ONYX_REDBUTTON_DRYRUN"] {
            try? "shutdown requested \(Date())\n".write(toFile: p, atomically: true, encoding: .utf8)
            return
        }
        DispatchQueue.global().async {
            if MediaController.run("tell application \"System Events\" to shut down") == nil {
                _ = MediaController.run("tell application \"loginwindow\" to «event aevtrsdn»")   // fallback: system shutdown prompt
            }
        }
    }
}

struct BigRedButton: View {
    @State private var open = false
    @State private var count: Int?
    @State private var pressed = false
    @State private var aborted = false
    @State private var pending: [DispatchWorkItem] = []
    var size: CGFloat = 104

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
                    .overlay { HazardStripes().mask(RoundedRectangle(cornerRadius: 12).strokeBorder(lineWidth: 7)) }
                    .frame(width: size, height: size)
                Button(action: press) {
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 1, green: 0.4, blue: 0.35), Color(red: 0.8, green: 0, blue: 0.05),
                                                      Color(red: 0.42, green: 0, blue: 0)],
                                             center: UnitPoint(x: 0.4, y: 0.35), startRadius: 2, endRadius: size * 0.36))
                        .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 2))
                        .overlay {
                            Text(count.map(String.init) ?? "⏻")
                                .font(.system(size: count == nil ? size * 0.2 : size * 0.3, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .contentTransition(.numericText())
                        }
                        .frame(width: size * 0.6, height: size * 0.6)
                        .shadow(color: .black.opacity(0.6), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
                        .scaleEffect(pressed ? 0.92 : 1)
                }
                .buttonStyle(.plain)
                .disabled(!open)
                // Safety cover, hinged along its top edge.
                Cover()
                    .frame(width: size * 0.78, height: size * 0.78)
                    .rotation3DEffect(.degrees(open ? -118 : 0), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.55)
                    .opacity(open ? 0.55 : 1)
                    .onTapGesture { setCover(!open) }
                    .allowsHitTesting(!open)
            }
            .frame(width: size, height: size)
            HStack(spacing: 6) {
                Text(status).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(count == nil ? Color.secondary : Color.red)
                if open {
                    Button("Close cover") { setCover(false) }.buttonStyle(.link).font(.system(size: 9.5))
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: open)
    }

    private var status: String {
        if let c = count { return "Shutting down in \(c)… close cover to abort" }
        if aborted { return "Aborted." }
        return open ? "Armed. Press to shut down" : "Flip the cover to arm"
    }

    private func setCover(_ o: Bool) {
        if !o && count != nil {             // closing the cover aborts the countdown
            pending.forEach { $0.cancel() }; pending = []
            count = nil; aborted = true
        }
        if o { aborted = false }
        open = o
    }

    private func press() {
        guard open, count == nil else { return }
        withAnimation(.spring(response: 0.12)) { pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation(.spring(response: 0.2)) { pressed = false } }
        withAnimation { count = 3 }
        SoundBoard.play(.beep)
        var items: [DispatchWorkItem] = []
        for (i, n) in [2, 1].enumerated() {
            let w = DispatchWorkItem { withAnimation { count = n }; SoundBoard.play(.beep) }
            items.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1), execute: w)
        }
        let fire = DispatchWorkItem {
            count = nil; open = false
            RedButtonAction.shutdown()
        }
        items.append(fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fire)
        pending = items
    }

    private struct Cover: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.25, blue: 0.2).opacity(0.55), Color(red: 0.7, green: 0.05, blue: 0.05).opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.45), lineWidth: 1.2))
                .overlay(alignment: .top) { Capsule().fill(Color(white: 0.75)).frame(height: 4).padding(.horizontal, 6) }   // hinge
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                        Text("LIFT").font(.system(size: 9, weight: .heavy, design: .rounded))
                    }.foregroundStyle(.white.opacity(0.85))
                }
                .contentShape(Rectangle())
        }
    }
}

/// Yellow/black diagonal hazard stripes.
struct HazardStripes: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for x in stride(from: -g.size.height, to: g.size.width + g.size.height, by: 12) {
                    p.move(to: CGPoint(x: x, y: g.size.height))
                    p.addLine(to: CGPoint(x: x + g.size.height, y: 0))
                }
            }
            .stroke(.black, lineWidth: 5)
            .background(Color(red: 1, green: 0.8, blue: 0))
        }
    }
}

// MARK: - Fun box (Home) / page (Tools)

struct FunPanelContent: View {
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        if !Fun.on {
            VStack(spacing: 8) {
                Text("🎉").font(.system(size: 26))
                Text("Fun mode is off").font(.system(size: 12, weight: .medium))
                Button("Turn it on") { UserDefaults.standard.set(true, forKey: Fun.enabled) }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 14) {
                if Prefs.bool(Fun.sounds) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sound board").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(FunSound.board, id: \.self) { s in pad(s.emoji, s.title) { SoundBoard.play(s) } }
                            pad("🎲", "Random") { SoundBoard.playRandom() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if Prefs.bool(Fun.redButton) { BigRedButton() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pad(_ emoji: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(emoji).font(.system(size: 20))
                Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct FunPanel: View {
    var body: some View { Card { FunPanelContent() } }
}

// MARK: - Settings › Fun Mode

struct FunSettings: View {
    @AppStorage(Fun.enabled) private var on = false
    @AppStorage(Fun.mirrorFilters) private var filters = true
    @AppStorage(Fun.mirrorFilter) private var filter = "none"
    @AppStorage(Fun.goose) private var goose = true
    @AppStorage(Fun.gooseHonks) private var honks = false
    @AppStorage(Fun.vinyl) private var vinyl = true
    @AppStorage(Fun.bomb) private var bomb = true
    @AppStorage(Fun.sounds) private var sounds = true
    @AppStorage(Fun.surprise) private var surprise = false
    @AppStorage(Fun.redButton) private var red = true
    @AppStorage(Fun.notchSounds) private var notchSounds = true
    @AppStorage(Fun.openSound) private var openSound = "random"
    @AppStorage(Fun.closeSound) private var closeSound = "random"
    @AppStorage(Fun.notchVolume) private var notchVolume = 0.7

    @ViewBuilder private var notchSoundOptions: some View {
        Text("🎲 Random").tag("random")
        Text("None").tag("none")
        ForEach(FunSound.board + [.goose, .boom], id: \.self) { Text("\($0.emoji) \($0.title)").tag($0.rawValue) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Fun mode", isOn: $on)
                Text("Turns on everything below that's switched on. Turn this off to put it all away at once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Section("Mirror") {
                    Toggle("Mirror filters", isOn: $filters)
                    Picker("Filter", selection: $filter) {
                        ForEach(MirrorFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }.disabled(!filters)
                    Text("You can also switch filters right on the mirror.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Desktop goose") {
                    Toggle("A goose wanders around your screen", isOn: $goose)
                    Toggle("Goose honks out loud", isOn: $honks).disabled(!goose)
                    Text("It's click-through, so it never gets in the way.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Now Playing & Timer") {
                    Toggle("Vinyl record for Now Playing", isOn: $vinyl)
                    Toggle("Focus timer is a bomb with a burning fuse", isOn: $bomb)
                }
                Section("Sounds") {
                    Toggle("Sound board (clown horn, munch, wasted)", isOn: $sounds)
                    Toggle("Surprise me: a random noise every 5–20 minutes", isOn: $surprise).disabled(!sounds)
                    Toggle("Play sounds when the notch opens and closes", isOn: $notchSounds)
                    Group {
                        Picker("When it opens", selection: $openSound) { notchSoundOptions }
                        Picker("When it closes", selection: $closeSound) { notchSoundOptions }
                        LabeledContent("Volume") {
                            Slider(value: $notchVolume, in: 0.05...1)
                        }
                    }
                    .disabled(!notchSounds)
                    HStack {
                        ForEach(FunSound.board + [.goose, .boom], id: \.self) { s in
                            Button("\(s.emoji) \(s.title)") { SoundBoard.play(s) }.controlSize(.small)
                        }
                    }
                    HStack {
                        Text("These are synthesized sound-alikes. To use your own, drop clown, eat, wasted, goose or boom (.mp3/.m4a/.wav) into the Sounds folder.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Sounds folder") { NSWorkspace.shared.open(SoundBoard.folder) }.controlSize(.small)
                    }
                }
                Section("Big red button") {
                    Toggle("Big red button", isOn: $red)
                    Text("Flip up the safety cover, then press it: a 3-second countdown starts, then your Mac shuts down (apps can still ask to save). Close the cover during the countdown to abort. It's in the Fun box on Home and the Fun page in Tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!on)
        }
        .formStyle(.grouped)
    }
}
