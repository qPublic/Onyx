import AppKit
import SwiftUI
import AVFoundation
import Combine

// MARK: - Live wallpapers: your videos (or animated scenes) playing behind your desktop icons

struct Wallpaper: Codable, Identifiable, Hashable {
    var id: String            // "scene.aurora" for built-in scenes, a UUID for your videos
    var name: String
    var file: String?         // the video's file name in Application Support/Onyx/Wallpapers
    var width = 0, height = 0
    var fps = 0.0
    var duration = 0.0
    var enhanced = false
    var prompt: String?       // what an AI loop was made from

    var isScene: Bool { file == nil }
    var scene: WallpaperScene? { WallpaperScene(rawValue: id) }
    /// "4K · 60 fps" style summary for the library cards.
    var badge: String {
        guard !isScene else { return "Animated scene" }
        let res = height >= 2000 ? "4K" : height >= 1400 ? "1440p" : height >= 1000 ? "1080p" : height >= 700 ? "720p" : "\(height)p"
        return (prompt != nil ? "AI loop · " : "") + "\(res) · \(Int(fps.rounded())) fps"
    }
}

enum WallpaperScene: String, CaseIterable {
    case aurora = "scene.aurora", glass = "scene.glass", stars = "scene.stars"
    case synthwave = "scene.synthwave", rainCity = "scene.raincity", pixelDusk = "scene.pixeldusk", hyperspace = "scene.hyperspace", codeRain = "scene.coderain"
    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .glass: "Liquid Glass"
        case .stars: "Night Sky"
        case .synthwave: "Neon Horizon"
        case .rainCity: "Rain City"
        case .pixelDusk: "Pixel Dusk"
        case .hyperspace: "Hyperspace"
        case .codeRain: "Code Rain"
        }
    }
    /// The Metal shader that draws it (the game-style pack, see Scenes.swift); the rest are Core Animation.
    var shader: String? {
        switch self {
        case .synthwave: "synthwave"
        case .rainCity: "raincity"
        case .pixelDusk: "pixeldusk"
        case .hyperspace: "hyperspace"
        case .codeRain: "coderain"
        default: nil
        }
    }
    /// How many of the screen's pixels it draws (then scales up).
    var renderScale: CGFloat { self == .pixelDusk ? 0.5 : self == .codeRain || self == .synthwave ? 0.75 : 0.6 }
    var wallpaper: Wallpaper { Wallpaper(id: rawValue, name: title) }
    /// Colors for the scene and its preview.
    var palette: [NSColor] {
        switch self {
        case .aurora: [NSColor(red: 0.05, green: 0.9, blue: 0.7, alpha: 1), NSColor(red: 0.45, green: 0.3, blue: 1, alpha: 1),
                       NSColor(red: 1, green: 0.3, blue: 0.65, alpha: 1), NSColor(red: 0.1, green: 0.5, blue: 1, alpha: 1)]
        case .glass: [NSColor(red: 1, green: 0.45, blue: 0.3, alpha: 1), NSColor(red: 0.55, green: 0.35, blue: 1, alpha: 1),
                      NSColor(red: 0.1, green: 0.75, blue: 1, alpha: 1), NSColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)]
        case .stars: [NSColor(red: 0.25, green: 0.2, blue: 0.7, alpha: 1), NSColor(red: 0.05, green: 0.35, blue: 0.6, alpha: 1)]
        default: [NSColor(red: 0.9, green: 0.25, blue: 0.7, alpha: 1), NSColor(red: 0.2, green: 0.8, blue: 1, alpha: 1)]
        }
    }
    var background: [NSColor] {
        switch self {
        case .aurora: [NSColor(red: 0.02, green: 0.03, blue: 0.1, alpha: 1), NSColor(red: 0.01, green: 0.01, blue: 0.04, alpha: 1)]
        case .glass: [NSColor(red: 0.12, green: 0.08, blue: 0.25, alpha: 1), NSColor(red: 0.03, green: 0.05, blue: 0.14, alpha: 1)]
        case .stars: [NSColor(red: 0.03, green: 0.04, blue: 0.14, alpha: 1), NSColor(red: 0, green: 0, blue: 0.02, alpha: 1)]
        default: [NSColor(red: 0.05, green: 0.02, blue: 0.12, alpha: 1), NSColor(red: 0, green: 0, blue: 0.03, alpha: 1)]
        }
    }
}

// MARK: - Library

final class WallpaperLibrary: ObservableObject {
    static let shared = WallpaperLibrary()
    @Published private(set) var videos: [Wallpaper] = []

    var all: [Wallpaper] { WallpaperScene.allCases.map(\.wallpaper) + videos }
    var folder: URL {
        let u = Prefs.supportDir.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: u.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        return u
    }
    private var index: URL { folder.appendingPathComponent("library.json") }

    init() {
        if let d = try? Data(contentsOf: index), let v = try? JSONDecoder().decode([Wallpaper].self, from: d) {
            videos = v.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file ?? "").path) }
        }
    }

    func item(_ id: String) -> Wallpaper? { all.first { $0.id == id } }
    func url(_ w: Wallpaper) -> URL? { w.file.map { folder.appendingPathComponent($0) } }
    private func save() { if let d = try? JSONEncoder().encode(videos) { try? d.write(to: index, options: .atomic) } }

    /// Copies a video into the library (the original stays where it is).
    @MainActor @discardableResult
    func add(_ src: URL, name: String? = nil, enhanced: Bool = false, move: Bool = false, prompt: String? = nil) async throws -> Wallpaper {
        let info = try await Self.info(src)
        let id = UUID().uuidString, file = id + "." + (src.pathExtension.isEmpty ? "mov" : src.pathExtension.lowercased())
        let dest = folder.appendingPathComponent(file)
        if move { try FileManager.default.moveItem(at: src, to: dest) } else { try FileManager.default.copyItem(at: src, to: dest) }
        let w = Wallpaper(id: id, name: name ?? src.deletingPathExtension().lastPathComponent, file: file,
                          width: info.width, height: info.height, fps: info.fps, duration: info.duration, enhanced: enhanced, prompt: prompt)
        videos.append(w); save()
        return w
    }

    func rename(_ w: Wallpaper, to name: String) {
        guard let i = videos.firstIndex(where: { $0.id == w.id }), !name.isEmpty else { return }
        videos[i].name = name; save()
    }

    func remove(_ w: Wallpaper) {
        guard !w.isScene else { return }
        if let u = url(w) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }   // recoverable from the Trash
        try? FileManager.default.removeItem(at: thumbURL(w))
        videos.removeAll { $0.id == w.id }; save()
        WallpaperEngine.shared.removed(w)
    }

    struct Info { var width: Int, height: Int, fps: Double, duration: Double }

    static func info(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VoiceError("That file has no video in it.") }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let duration = try await asset.load(.duration).seconds
        return Info(width: Int(abs(r.width)), height: Int(abs(r.height)), fps: Double(fps), duration: duration)
    }

    // MARK: Thumbnails

    private func thumbURL(_ w: Wallpaper) -> URL { folder.appendingPathComponent("Thumbnails/\(w.id).jpg") }
    private var cache: [String: NSImage] = [:]

    @MainActor func thumbnail(_ w: Wallpaper) async -> NSImage? {
        if let c = cache[w.id] { return c }
        var img: NSImage?
        if let scene = w.scene {
            img = Self.preview(scene, size: CGSize(width: 480, height: 300))
        } else if let d = try? Data(contentsOf: thumbURL(w)) {
            img = NSImage(data: d)
        } else if let u = url(w) {
            img = await Self.frame(u, at: 1, maxSize: CGSize(width: 640, height: 400))
            if let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) { try? jpg.write(to: thumbURL(w)) }
        }
        cache[w.id] = img
        return img
    }

    static func frame(_ url: URL, at seconds: Double, maxSize: CGSize) async -> NSImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = maxSize
        guard let (cg, _) = try? await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// A still of a scene: its background with soft blobs of its colors.
    static func preview(_ s: WallpaperScene, size: CGSize) -> NSImage {
        if s.shader != nil, let cg = GPU.snapshot(s, size: size) { return NSImage(cgImage: cg, size: size) }
        return NSImage(size: size, flipped: false) { r in
            NSGradient(colors: s.background)?.draw(in: r, angle: -90)
            for (i, c) in s.palette.enumerated() {
                let p = CGPoint(x: r.width * [0.25, 0.7, 0.45, 0.85][i % 4], y: r.height * [0.6, 0.35, 0.2, 0.75][i % 4])
                let rad = r.width * 0.42
                NSGradient(colors: [c.withAlphaComponent(0.7), c.withAlphaComponent(0)])?
                    .draw(fromCenter: p, radius: 0, toCenter: p, radius: rad, options: [])
            }
            return true
        }
    }
}

// MARK: - Engine: one desktop-level window per display

final class WallpaperEngine: ObservableObject {
    static let shared = WallpaperEngine()
    enum K {
        static let enabled = "wall.enabled", current = "wall.current", screens = "wall.screens", shuffle = "wall.shuffle"
        static let night = "wall.night", pauseBattery = "wall.pauseBattery", pauseLowPower = "wall.pauseLowPower"
        static let sound = "wall.sound", still = "wall.still"
    }
    static let defaults: [String: Any] = [K.enabled: false, K.current: WallpaperScene.aurora.rawValue, K.shuffle: 0, K.night: "",
                                          K.pauseBattery: false, K.pauseLowPower: true, K.sound: false, K.still: false]

    @Published private(set) var pausedReason: String?
    private var windows: [String: WallpaperWindow] = [:]   // by display name
    private var shuffleTimer: Timer?, clock: Timer?
    private var asleep = false, locked = false
    private var wasNight: Bool?

    var enabled: Bool { Prefs.bool(K.enabled) }
    static func key(_ s: NSScreen) -> String { s.localizedName }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true; self?.evaluate() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = false; self?.evaluate() }
        for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.evaluate() }   // after fullscreen animations
            }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.evaluate() }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.evaluate() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        BatteryMonitor.shared.$pluggedIn.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.evaluate() }.store(in: &bag)
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.minuteTick() }.tolerant()
        rebuild()
    }
    private var bag = Set<AnyCancellable>()

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.enabled)
        rebuild()
        if !on { restoreDesktopPictures() }
    }

    /// Sets a wallpaper on every display (screen nil) or just one.
    func set(_ w: Wallpaper, on screen: NSScreen? = nil) {
        let d = UserDefaults.standard
        var map = d.dictionary(forKey: K.screens) as? [String: String] ?? [:]
        if let screen { map[Self.key(screen)] = w.id } else { map = [:]; d.set(w.id, forKey: K.current) }
        d.set(map, forKey: K.screens)
        if !enabled { d.set(true, forKey: K.enabled) }
        rebuild()
    }

    func removed(_ w: Wallpaper) {
        let d = UserDefaults.standard
        if d.string(forKey: K.current) == w.id { d.set(WallpaperScene.aurora.rawValue, forKey: K.current) }
        if d.string(forKey: K.night) == w.id { d.set("", forKey: K.night) }
        var map = d.dictionary(forKey: K.screens) as? [String: String] ?? [:]
        map = map.filter { $0.value != w.id }; d.set(map, forKey: K.screens)
        rebuild()
    }

    /// What should be on a display right now: the night wallpaper after sunset, else its own, else the shared one.
    func wallpaperID(for screen: NSScreen) -> String {
        let d = UserDefaults.standard
        if let night = d.string(forKey: K.night), !night.isEmpty, Self.isNight() { return night }
        let map = d.dictionary(forKey: K.screens) as? [String: String] ?? [:]
        return map[Self.key(screen)] ?? d.string(forKey: K.current) ?? WallpaperScene.aurora.rawValue
    }

    func rebuild() {
        guard enabled else {
            windows.values.forEach { $0.orderOut(nil); $0.stop() }
            windows = [:]; pausedReason = nil
            return
        }
        let screens = NSScreen.screens
        for (k, w) in windows where !screens.contains(where: { Self.key($0) == k }) { w.orderOut(nil); w.stop(); windows[k] = nil }
        for s in screens {
            let win = windows[Self.key(s)] ?? WallpaperWindow(screen: s)
            windows[Self.key(s)] = win
            win.setFrame(s.frame, display: true)
            let w = WallpaperLibrary.shared.item(wallpaperID(for: s)) ?? WallpaperScene.aurora.wallpaper
            win.show(w, sound: Prefs.bool(K.sound))
            win.orderBack(nil)
        }
        restartShuffle()
        evaluate()
        if Prefs.bool(K.still) { Task { await applyDesktopPictures() } }
    }

    /// Plays only when someone can see it: not asleep or locked, not behind a fullscreen app, and within your power settings.
    func evaluate() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let battery = BatteryMonitor.shared.hasBattery && !BatteryMonitor.shared.pluggedIn
        var reason: String?
        if asleep || locked { reason = "Paused while your Mac is locked or asleep" }
        else if LowBatteryMode.shared.active { reason = "Paused in Low Battery Mode" }
        else if Prefs.bool(K.pauseLowPower) && lowPower { reason = "Paused in Low Power Mode" }
        else if Prefs.bool(K.pauseBattery) && battery { reason = "Paused on battery power" }
        for (k, w) in windows {
            let screen = NSScreen.screens.first { Self.key($0) == k }
            let covered = !w.occlusionState.contains(.visible) || (screen.map { FullscreenWatcher.frontAppIsFullscreen(on: $0) } ?? false)
            if reason == nil && !covered { w.play() } else { w.pause() }
        }
        pausedReason = reason
    }

    private func minuteTick() {
        guard enabled else { return }
        let night = Self.isNight()
        if let was = wasNight, was != night, !(UserDefaults.standard.string(forKey: K.night) ?? "").isEmpty { rebuild() }
        wasNight = night
    }

    private func restartShuffle() {
        shuffleTimer?.invalidate(); shuffleTimer = nil
        let minutes = UserDefaults.standard.integer(forKey: K.shuffle)
        guard enabled, minutes > 0 else { return }
        shuffleTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            let d = UserDefaults.standard
            let pool = WallpaperLibrary.shared.all.filter { $0.id != d.string(forKey: K.current) }
            guard let next = pool.randomElement() else { return }
            d.set(next.id, forKey: K.current); d.set([String: String](), forKey: K.screens)
            self?.rebuild()
        }.tolerant(0.05)
    }

    // MARK: Desktop picture (lock screen, Mission Control)

    /// Optionally makes your real desktop picture a still of the wallpaper, so the lock screen and Mission Control match.
    /// The picture you had before is remembered and put back when this is turned off.
    @MainActor func applyDesktopPictures() async {
        let d = UserDefaults.standard
        var saved = d.dictionary(forKey: "wall.previousPictures") as? [String: String] ?? [:]
        for s in NSScreen.screens {
            guard let w = WallpaperLibrary.shared.item(wallpaperID(for: s)) else { continue }
            let out = WallpaperLibrary.shared.folder.appendingPathComponent("Thumbnails/still-\(w.id).jpg")
            if !FileManager.default.fileExists(atPath: out.path) {
                var img: NSImage? = w.scene.map { WallpaperLibrary.preview($0, size: s.frame.size) }
                if img == nil, let u = WallpaperLibrary.shared.url(w) { img = await WallpaperLibrary.frame(u, at: 1, maxSize: CGSize(width: 3840, height: 2400)) }
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { continue }
                try? jpg.write(to: out)
            }
            if saved[Self.key(s)] == nil, let cur = NSWorkspace.shared.desktopImageURL(for: s), !cur.path.contains("/Onyx/Wallpapers/") {
                saved[Self.key(s)] = cur.path
            }
            try? NSWorkspace.shared.setDesktopImageURL(out, for: s, options: [:])
        }
        d.set(saved, forKey: "wall.previousPictures")
    }

    func restoreDesktopPictures() {
        let d = UserDefaults.standard
        guard let saved = d.dictionary(forKey: "wall.previousPictures") as? [String: String], !saved.isEmpty else { return }
        for s in NSScreen.screens { if let p = saved[Self.key(s)] { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: p), for: s, options: [:]) } }
        d.removeObject(forKey: "wall.previousPictures")
    }

    // MARK: Day and night

    static func isNight(_ now: Date = Date()) -> Bool {
        if let (lat, lon) = WeatherService.shared.coordinates, let sun = sunTimes(lat: lat, lon: lon, date: now) {
            return now < sun.rise || now > sun.set
        }
        let h = Calendar.current.component(.hour, from: now)
        return h < 7 || h >= 19
    }

    /// Sunrise and sunset (NOAA's approximation, good to a couple of minutes). nil during polar day or night.
    static func sunTimes(lat: Double, lon: Double, date: Date) -> (rise: Date, set: Date)? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        // The local calendar day, so an evening sunset in the Americas isn't counted on the next UTC day.
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let day = utc.date(from: local), let n = utc.ordinality(of: .day, in: .year, for: day).map(Double.init) else { return nil }
        let rad = Double.pi / 180
        func time(_ rising: Bool) -> Date? {
            let lngHour = lon / 15, t = n + ((rising ? 6 : 18) - lngHour) / 24
            let m = 0.9856 * t - 3.289
            var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
            l = (l.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            var ra = atan(0.91764 * tan(l * rad)) / rad
            ra = (ra.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            ra = (ra + (floor(l / 90) * 90 - floor(ra / 90) * 90)) / 15
            let sinDec = 0.39782 * sin(l * rad), cosDec = cos(asin(sinDec))
            let cosH = (cos(90.833 * rad) - sinDec * sin(lat * rad)) / (cosDec * cos(lat * rad))
            guard cosH >= -1, cosH <= 1 else { return nil }
            let h = (rising ? 360 - acos(cosH) / rad : acos(cosH) / rad) / 15
            let ut = ((h + ra - 0.06571 * t - 6.622 - lngHour).truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
            return day.addingTimeInterval(ut * 3600)
        }
        guard let rise = time(true), var set = time(false) else { return nil }
        if set < rise { set.addTimeInterval(86400) }
        var r = rise
        if r.timeIntervalSince(date) > 14 * 3600 { r.addTimeInterval(-86400); set.addTimeInterval(-86400) }
        return (r, set)
    }
}

// MARK: - The window behind your icons

final class WallpaperWindow: NSWindow {
    private let host = NSView()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var current: String?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true; hasShadow = false; backgroundColor = .black
        isReleasedWhenClosed = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self, queue: .main) { _ in
            WallpaperEngine.shared.evaluate()
        }
    }

    func show(_ w: Wallpaper, sound: Bool) {
        player?.isMuted = !sound
        guard current != w.id else { return }
        stop()
        current = w.id
        host.subviews.forEach { $0.removeFromSuperview() }
        host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        if let scene = w.scene {
            let v = SceneView(scene: scene, frame: host.bounds)
            v.autoresizingMask = [.width, .height]
            host.addSubview(v)
        } else if let url = WallpaperLibrary.shared.url(w) {
            let item = AVPlayerItem(url: url)
            let p = AVQueuePlayer()
            p.isMuted = !sound
            p.preventsDisplaySleepDuringVideoPlayback = false   // never keep your screen awake
            p.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: p, templateItem: item)   // seamless loop
            let layer = AVPlayerLayer(player: p)
            layer.videoGravity = .resizeAspectFill
            layer.frame = host.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            host.layer?.addSublayer(layer)
            player = p
        }
    }

    // A desktop window is never the focused one, and macOS draws Liquid Glass dimmed in unfocused windows.
    // Report the "active" look so the Liquid Glass scene stays bright (same AppKit hooks as the notch).
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }

    func play() {
        player?.play()
        host.subviews.compactMap { $0 as? SceneView }.forEach { $0.setRunning(true) }
    }
    func pause() {
        player?.pause()
        host.subviews.compactMap { $0 as? SceneView }.forEach { $0.setRunning(false) }
    }
    func stop() { player?.pause(); looper?.disableLooping(); looper = nil; player = nil; current = nil }
}

// MARK: - Animated scenes (Core Animation: the GPU does the work, so they cost almost no CPU)

final class SceneView: NSView {
    let scene: WallpaperScene

    init(scene: WallpaperScene, frame: NSRect) {
        self.scene = scene
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); if layer?.sublayers?.first?.frame != bounds { build() } }

    /// Freezes the animations in place (layer speed 0) while hidden, and picks up where they left off.
    func setRunning(_ on: Bool) {
        subviews.compactMap { $0 as? ShaderView }.forEach { $0.setRunning(on) }
        guard let l = layer, (l.speed == 0) == on else { return }
        if on {
            let paused = l.timeOffset
            l.speed = 1; l.timeOffset = 0; l.beginTime = 0
            l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            let t = l.convertTime(CACurrentMediaTime(), from: nil)
            l.speed = 0; l.timeOffset = t
        }
    }

    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let root = layer, bounds.width > 0 else { return }
        let bg = CAGradientLayer()
        bg.frame = bounds
        bg.colors = scene.background.map(\.cgColor)
        bg.startPoint = CGPoint(x: 0.5, y: 1); bg.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(bg)

        switch scene {
        case .aurora, .glass:
            let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.2, 0.7, 0.75, 0.35), (0.75, 0.3, 0.5, 0.8), (0.5, 0.15, 0.85, 0.55), (0.9, 0.8, 0.3, 0.25)]
            for (i, c) in scene.palette.enumerated() {
                let (x1, y1, x2, y2) = spots[i % spots.count]
                let d = max(bounds.width, bounds.height) * (scene == .glass ? 0.7 : 0.85)
                let blob = CAGradientLayer()
                blob.type = .radial
                blob.colors = [c.withAlphaComponent(scene == .glass ? 0.9 : 0.6).cgColor, c.withAlphaComponent(0).cgColor]
                blob.startPoint = CGPoint(x: 0.5, y: 0.5); blob.endPoint = CGPoint(x: 1, y: 1)
                blob.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                blob.position = CGPoint(x: bounds.width * x1, y: bounds.height * y1)
                blob.compositingFilter = "screenBlendMode"
                root.addSublayer(blob)
                let move = CABasicAnimation(keyPath: "position")
                move.toValue = NSValue(point: CGPoint(x: bounds.width * x2, y: bounds.height * y2))
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.8; scale.toValue = 1.25
                for (a, dur) in [(move, 26.0 + Double(i) * 7), (scale, 17.0 + Double(i) * 5)] {
                    a.duration = dur; a.autoreverses = true; a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    blob.add(a, forKey: a.keyPath)
                }
            }
            if scene == .glass { addGlassDrops() }
        case .stars:
            let nebula = CAGradientLayer()
            nebula.type = .radial
            nebula.colors = [scene.palette[0].withAlphaComponent(0.45).cgColor, NSColor.clear.cgColor]
            nebula.startPoint = CGPoint(x: 0.5, y: 0.5); nebula.endPoint = CGPoint(x: 1, y: 1)
            nebula.frame = CGRect(x: bounds.width * 0.3, y: bounds.height * 0.2, width: bounds.width * 0.9, height: bounds.height * 0.9)
            nebula.compositingFilter = "screenBlendMode"
            root.addSublayer(nebula)
            let drift = CABasicAnimation(keyPath: "transform.scale")
            drift.fromValue = 0.9; drift.toValue = 1.15; drift.duration = 40; drift.autoreverses = true; drift.repeatCount = .infinity
            nebula.add(drift, forKey: "drift")
            let stars = CAEmitterLayer()
            stars.frame = bounds
            stars.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            stars.emitterSize = bounds.size
            stars.emitterShape = .rectangle
            stars.birthRate = 1
            let cell = CAEmitterCell()
            cell.contents = Self.dot()
            cell.birthRate = Float(bounds.width * bounds.height / 12000)
            cell.lifetime = 14; cell.lifetimeRange = 6
            cell.scale = 0.06; cell.scaleRange = 0.05
            cell.alphaRange = 0.6
            cell.alphaSpeed = -0.08
            cell.velocity = 3; cell.velocityRange = 3
            cell.emissionRange = .pi * 2
            stars.emitterCells = [cell]
            root.addSublayer(stars)
        default:
            let v = ShaderView(scene: scene, frame: bounds)
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }

    /// Floating Liquid Glass shapes that bend the colors drifting behind them.
    private func addGlassDrops() {
        let shapes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [   // x, y, width, height, corner (fractions of the screen)
            (0.14, 0.58, 0.16, 0.16, 0.08), (0.62, 0.22, 0.26, 0.11, 0.055), (0.7, 0.64, 0.12, 0.12, 0.06), (0.36, 0.3, 0.09, 0.09, 0.045)]
        let s = min(bounds.width, bounds.height)
        for (i, (x, y, w, h, c)) in shapes.enumerated() {
            let g = NSGlassEffectView(frame: CGRect(x: bounds.width * x, y: bounds.height * y, width: s * w * 1.6, height: s * h * 1.6))
            g.cornerRadius = s * c * 1.6
            g.style = .clear                                  // see-through, bending the colors behind it
            g.appearance = NSAppearance(named: .aqua)         // light glass: dark glass would dim the colors instead
            g.wantsLayer = true
            addSubview(g)
            let float = CABasicAnimation(keyPath: "position")
            float.byValue = NSValue(point: CGPoint(x: s * 0.06 * (i.isMultiple(of: 2) ? 1 : -1), y: s * 0.05))
            float.duration = 14 + Double(i) * 3; float.autoreverses = true; float.repeatCount = .infinity
            float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.layer?.add(float, forKey: "float")
        }
    }

    private static func dot() -> CGImage? {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: 16, y: 16), startRadius: 0, endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
        }
        return ctx.makeImage()
    }
}
