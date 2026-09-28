import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Live Wallpapers window (menu bar icon › Live Wallpapers…, or the notch's ••• menu)

struct WallpapersView: View {
    @ObservedObject var lib = WallpaperLibrary.shared
    @ObservedObject var engine = WallpaperEngine.shared
    @ObservedObject var enhancer = VideoEnhancer.shared
    @AppStorage(WallpaperEngine.K.enabled) private var enabled = false
    @AppStorage(WallpaperEngine.K.current) private var current = WallpaperScene.aurora.rawValue
    @AppStorage(WallpaperEngine.K.shuffle) private var shuffle = 0
    @AppStorage(WallpaperEngine.K.night) private var night = ""
    @AppStorage(WallpaperEngine.K.pauseBattery) private var pauseBattery = false
    @AppStorage(WallpaperEngine.K.pauseLowPower) private var pauseLowPower = true
    @AppStorage(WallpaperEngine.K.sound) private var sound = false
    @AppStorage(WallpaperEngine.K.still) private var still = false
    @State private var display = "all"
    @State private var enhancing: Wallpaper?
    @State private var creating = false
    @State private var renaming: Wallpaper?
    @State private var newName = ""
    @State private var dropping = false
    @State private var problem: String?
    @State private var backdrop: NSImage?

    private var screens: [NSScreen] { NSScreen.screens }
    private func selectedID() -> String {
        if display != "all", let s = screens.first(where: { WallpaperEngine.key($0) == display }) { return engine.wallpaperID(for: s) }
        return current
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                header
                ScrollView {
                    GlassEffectContainer(spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)], spacing: 16) {
                            ForEach(lib.all) { w in card(w) }
                            addCard
                        }
                        .padding(4)
                    }
                }
                .scrollIndicators(.hidden)
                options
            }
            .padding(.horizontal, 22).padding(.bottom, 18).padding(.top, 34)
        }
        // The current wallpaper, blurred, behind everything: the glass picks up its colors.
        .background {
            Group {
                if let backdrop { Image(nsImage: backdrop).resizable().scaledToFill().blur(radius: 50) } else { Color(hex: "101020") }
            }
            .overlay(Color.black.opacity(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 760, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in importDropped(providers); return true }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 24).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(10) } }
        .sheet(item: $enhancing) { w in EnhanceSheet(wallpaper: w) { enhancing = nil } }
        .sheet(isPresented: $creating) { CreateLoopSheet { creating = false } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { lib.rename(r, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Couldn't add that video", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .task(id: current) { if let w = lib.item(current) { backdrop = await lib.thumbnail(w) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Wallpapers").font(.system(size: 24, weight: .bold))
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if screens.count > 1 {
                Picker("", selection: $display) {
                    Text("All displays").tag("all")
                    ForEach(screens, id: \.self) { s in Text(s.localizedName).tag(WallpaperEngine.key(s)) }
                }
                .labelsHidden().fixedSize()
            }
            Button { creating = true } label: { Label("Create with AI", systemImage: "wand.and.sparkles") }
                .buttonStyle(.glassProminent).tint(.purple).controlSize(.large)
            Button { chooseVideos() } label: { Label("Add Videos", systemImage: "plus") }
                .buttonStyle(.glass).controlSize(.large)
            Toggle("", isOn: Binding(get: { enabled }, set: { engine.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.large)
                .help(enabled ? "Turn live wallpapers off" : "Turn live wallpapers on")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var statusLine: String {
        guard enabled else { return "Off. Pick a wallpaper to turn it on." }
        if let r = engine.pausedReason { return r }
        let name = lib.item(current)?.name ?? ""
        return screens.count > 1 ? "Playing on \(screens.count) displays" : "Now playing: \(name)"
    }

    // MARK: Cards

    private func card(_ w: Wallpaper) -> some View {
        let selected = enabled && selectedID() == w.id
        return Button { apply(w) } label: {
            VStack(alignment: .leading, spacing: 8) {
                WallpaperThumb(wallpaper: w)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if enhancer.busy && enhancer.source == w.id {
                            ProgressView().controlSize(.small).padding(8)
                        } else if w.enhanced {
                            Image(systemName: "wand.and.sparkles").font(.system(size: 11, weight: .semibold))
                                .padding(6).glassEffect(.regular, in: .circle).padding(6)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if night == w.id {
                            Image(systemName: "moon.stars.fill").font(.system(size: 11)).padding(6).glassEffect(.regular, in: .circle).padding(6)
                        }
                    }
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(w.badge).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan).font(.system(size: 16)) }
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.cyan.opacity(0.25)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 22))
        .contextMenu { menu(w) }
    }

    @ViewBuilder private func menu(_ w: Wallpaper) -> some View {
        Button("Set on All Displays") { engine.set(w) }
        if screens.count > 1 {
            ForEach(screens, id: \.self) { s in Button("Set on \(s.localizedName)") { engine.set(w, on: s) } }
        }
        Button(night == w.id ? "Stop Using at Night" : "Use After Sunset") { night = night == w.id ? "" : w.id; engine.rebuild() }
        if !w.isScene {
            Divider()
            Button("Enhance with AI…") { enhancing = w }
                .disabled(enhancer.busy || (VideoEnhancer.scaleFactors(width: w.width, height: w.height).isEmpty && VideoEnhancer.frameRates(from: w.fps).isEmpty))
            Button("Rename…") { newName = w.name; renaming = w }
            if let u = lib.url(w) { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            Divider()
            Button("Delete", role: .destructive) { lib.remove(w) }
        }
    }

    private var addCard: some View {
        Button { chooseVideos() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 28, weight: .light))
                Text("Add your own videos").font(.system(size: 13, weight: .semibold))
                Text("MP4 or MOV. Or drop them here.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 22))
    }

    // MARK: Options

    private var options: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Shuffle", selection: $shuffle) {
                    Text("Off").tag(0); Text("Every 15 minutes").tag(15); Text("Every hour").tag(60); Text("Every day").tag(1440)
                }
                .onChange(of: shuffle) { _, _ in engine.rebuild() }
                Picker("After sunset", selection: $night) {
                    Text("Same wallpaper").tag("")
                    ForEach(lib.all) { w in Text(w.name).tag(w.id) }
                }
                .onChange(of: night) { _, _ in engine.rebuild() }
            }
            .frame(maxWidth: 300)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Pause on battery power", isOn: $pauseBattery).onChange(of: pauseBattery) { _, _ in engine.evaluate() }
                Toggle("Pause in Low Power Mode", isOn: $pauseLowPower).onChange(of: pauseLowPower) { _, _ in engine.evaluate() }
                Toggle("Play the video's sound", isOn: $sound).onChange(of: sound) { _, _ in engine.rebuild() }
                Text("Pauses by itself when it's covered, behind a fullscreen app, or your Mac is locked.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 240)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Match my desktop picture", isOn: $still)
                    .onChange(of: still) { _, on in if on { Task { await engine.applyDesktopPictures() } } else { engine.restoreDesktopPictures() } }
                Text("Sets a still of it as your real desktop picture, so the lock screen and Mission Control match. Your old picture comes back when you turn this off.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 260)
        }
        .font(.system(size: 12))
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: Actions

    private func apply(_ w: Wallpaper) {
        if display == "all" { engine.set(w) } else if let s = screens.first(where: { WallpaperEngine.key($0) == display }) { engine.set(w, on: s) }
    }

    private func chooseVideos() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.movie]
        p.message = "Choose videos to use as live wallpapers"
        guard p.runModal() == .OK else { return }
        add(p.urls)
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        for pr in providers {
            _ = pr.loadObject(ofClass: URL.self) { u, _ in
                guard let u, UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie) == true else { return }
                DispatchQueue.main.async { add([u]) }
            }
        }
    }

    private func add(_ urls: [URL]) {
        Task { @MainActor in
            var last: Wallpaper?
            for u in urls {
                do { last = try await lib.add(u) } catch { problem = "\(u.lastPathComponent): \((error as? VoiceError)?.message ?? error.localizedDescription)" }
            }
            if let last { apply(last) }
        }
    }
}

/// A wallpaper's preview picture, loaded in the background.
struct WallpaperThumb: View {
    let wallpaper: Wallpaper
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { ProgressView().controlSize(.small) }
        }
        .task(id: wallpaper.id) { image = await WallpaperLibrary.shared.thumbnail(wallpaper) }
    }
}
