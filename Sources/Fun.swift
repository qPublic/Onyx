import AppKit
import SwiftUI
import AVFoundation
import CoreImage
import Vision

// MARK: - Fun mode preferences

enum Fun {
    static let enabled = "fun.enabled"
    static let mirrorFilters = "fun.mirrorFilters"
    static let mirrorFilter = "fun.mirrorFilter"
    static let goose = "fun.goose"
    static let gooseHonks = "fun.gooseHonks"
    static let vinyl = "fun.vinyl"
    static let bomb = "fun.bomb"
    static let sounds = "fun.sounds"
    static let surprise = "fun.surprise"
    static let redButton = "fun.redButton"
    static let notchSounds = "fun.notchSounds"
    static let openSound = "fun.openSound"      // "random", "none", or a FunSound raw value
    static let closeSound = "fun.closeSound"
    static let notchVolume = "fun.notchVolume"

    static let defaults: [String: Any] = [
        enabled: false, mirrorFilters: true, mirrorFilter: "none", goose: true, gooseHonks: false,
        vinyl: true, bomb: true, sounds: true, surprise: false, redButton: true,
        notchSounds: true, openSound: "random", closeSound: "random", notchVolume: 0.7,
    ]

    static var on: Bool { Prefs.bool(enabled) }
    /// A fun feature is active only when Fun mode itself is on.
    static func has(_ key: String) -> Bool { on && Prefs.bool(key) }
}

/// Starts/stops the always-running fun bits (goose, surprise noises) as settings change.
final class FunController {
    static let shared = FunController()
    private var observer: Any?
    private var surprise: DispatchWorkItem?

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    private func apply() {
        GooseController.shared.setEnabled(Fun.has(Fun.goose))
        if Fun.has(Fun.surprise) && Fun.has(Fun.sounds) {
            if surprise == nil { scheduleSurprise() }
        } else {
            surprise?.cancel(); surprise = nil
        }
    }

    /// A random noise every 5–20 minutes.
    private func scheduleSurprise() {
        let w = DispatchWorkItem { [weak self] in
            self?.surprise = nil
            if Fun.has(Fun.surprise) && Fun.has(Fun.sounds) { SoundBoard.playRandom() }
            self?.apply()
        }
        surprise = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 300...1200), execute: w)
    }
}

// MARK: - Sound board (synthesized sound-alikes; drop your own files in to replace them)

enum FunSound: String, CaseIterable {
    case clown, eat, wasted, boom, beep, goose

    var title: String {
        switch self {
        case .clown: "Clown horn"
        case .eat: "Munch"
        case .wasted: "Wasted"
        case .boom: "Boom"
        case .beep: "Beep"
        case .goose: "Goose honk"
        }
    }
    var emoji: String {
        switch self {
        case .clown: "🤡"
        case .eat: "🍗"
        case .wasted: "💀"
        case .boom: "💥"
        case .beep: "📟"
        case .goose: "🪿"
        }
    }
    static let board: [FunSound] = [.clown, .eat, .wasted]
}

enum SoundBoard {
    private static var cache: [FunSound: NSSound] = [:]

    /// ~/Library/Application Support/Onyx/Sounds — put clown.mp3, eat.mp3, wasted.mp3 (etc.) here to override.
    static var folder: URL {
        let u = Prefs.supportDir.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func customFile(_ s: FunSound) -> URL? {
        for ext in ["mp3", "m4a", "wav", "aiff", "aif", "caf"] {
            let u = folder.appendingPathComponent("\(s.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Test hook: when set, sounds are reported here instead of played.
    static var testLog: ((FunSound, Float) -> Void)?

    @discardableResult
    static func play(_ s: FunSound, volume: Float = 1) -> NSSound? {
        if let log = testLog { log(s, volume); return nil }
        if let u = customFile(s) {
            let n = NSSound(contentsOf: u, byReference: true)
            n?.volume = volume; n?.play()
            return n
        }
        let snd = cache[s] ?? NSSound(data: Synth.wav(Synth.samples(s)))
        cache[s] = snd
        if snd?.isPlaying == true { snd?.stop() }
        snd?.volume = volume
        snd?.play()
        return snd
    }

    private static var lastNotch: NSSound?

    /// Sound for the notch opening/closing (Settings › Fun Mode › Sounds). A new one cuts off the
    /// previous one so quick hover in/out doesn't stack sounds.
    static func notch(opening: Bool) {
        guard Fun.has(Fun.notchSounds) else { return }
        let raw = Prefs.string(opening ? Fun.openSound : Fun.closeSound)
        guard raw != "none" else { return }
        let s = FunSound(rawValue: raw) ?? FunSound.board.randomElement()!
        lastNotch?.stop()
        lastNotch = play(s, volume: Float(Prefs.double(Fun.notchVolume)))
    }

    static func playRandom() { play(FunSound.board.randomElement()!) }
}

/// Small procedural synth — generates each sound once as 16-bit mono WAV.
enum Synth {
    static let rate = 44100.0

    static func samples(_ s: FunSound) -> [Float] {
        var out: [Float]
        switch s {
        case .clown:
            out = []
            horn(&out, at: 0, dur: 0.2, f0: 440, gain: 1)
            horn(&out, at: 0.29, dur: 0.34, f0: 440, gain: 1)
        case .goose:
            out = []
            horn(&out, at: 0, dur: 0.14, f0: 330, gain: 0.8, droop: 0.2)
            horn(&out, at: 0.18, dur: 0.2, f0: 300, gain: 0.8, droop: 0.25)
        case .eat: out = eat()
        case .wasted: out = wasted()
        case .boom: out = boom()
        case .beep: out = tone(880, dur: 0.12)
        }
        normalize(&out)
        return out
    }

    private static func ensure(_ out: inout [Float], _ n: Int) {
        if out.count < n { out += [Float](repeating: 0, count: n - out.count) }
    }

    /// Bulb/clown horn: nasal, harmonic-rich tone with a squeaky pitch rise on the attack.
    static func horn(_ out: inout [Float], at t0: Double, dur: Double, f0: Double, gain: Float, droop: Double = 0.08) {
        let start = max(0, Int(t0 * rate)), n = Int(dur * rate)
        ensure(&out, start + n)
        let amps: [Double] = [1, 0.75, 0.95, 0.55, 0.65, 0.35, 0.4, 0.2, 0.22, 0.1]
        var ph = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let env = min(1, t / 0.012) * min(1, (dur - t) / 0.05)
            let bend = t < 0.035 ? 0.82 + 0.18 * t / 0.035 : 1
            let f = f0 * bend * (1 - droop * t / dur) * (1 + 0.012 * sin(2 * .pi * 9 * t))
            ph += 2 * .pi * f / rate
            var v = 0.0
            for (k, a) in amps.enumerated() { v += a * sin(Double(k + 1) * ph) }
            out[start + i] += Float(v * env) * gain
        }
    }

    /// Crunchy chomps followed by a burp.
    static func eat() -> [Float] {
        var out = [Float](repeating: 0, count: Int(1.55 * rate))
        for (i, c) in [0.0, 0.21, 0.43, 0.64].enumerated() {
            crunch(&out, at: max(0, c + .random(in: -0.015...0.015)), dur: 0.09 + Double(i % 2) * 0.03)
        }
        burp(&out, at: 0.95, dur: 0.48)
        return out
    }

    private static func crunch(_ out: inout [Float], at t0: Double, dur: Double) {
        let start = max(0, Int(t0 * rate)), n = Int(dur * rate)
        ensure(&out, start + n)
        var lp: Float = 0, lp2: Float = 0
        let a: Float = .random(in: 0.3...0.55)
        for i in 0..<n {
            let t = Double(i) / rate
            let env = Float(min(1, t / 0.003) * exp(-t / 0.028))
            let grain: Float = Float.random(in: 0...1) < 0.45 ? 1 : 0.15
            let x = Float.random(in: -1...1) * grain
            lp += a * (x - lp)
            lp2 += 0.03 * (lp - lp2)          // subtract a slow low-pass → keeps the crunchy mids
            out[start + i] += (lp - lp2) * env * 1.6
        }
    }

    private static func burp(_ out: inout [Float], at t0: Double, dur: Double) {
        let start = max(0, Int(t0 * rate)), n = Int(dur * rate)
        ensure(&out, start + n)
        var ph = 0.0, lp: Float = 0
        for i in 0..<n {
            let t = Double(i) / rate
            let env = min(1, t / 0.02) * min(1, (dur - t) / 0.09)
            let f = 92 + 18 * sin(2 * .pi * 3.3 * t) + Double.random(in: -4...4)
            ph += 2 * .pi * f / rate
            var v = 0.0
            for k in 1...12 { v += sin(Double(k) * ph) / Double(k) }
            v *= 0.55 + 0.45 * sin(2 * .pi * 27 * t)      // vocal-fry flutter
            lp += 0.18 * (Float(v) - lp)
            out[start + i] += lp * Float(env) * 1.3
        }
    }

    /// Slow-motion whoosh, deep hit, then a long ominous ring.
    static func wasted() -> [Float] {
        let total = 3.2
        var out = [Float](repeating: 0, count: Int(total * rate))
        var lp: Float = 0
        let hit = 0.7
        for i in 0..<out.count {
            let t = Double(i) / rate
            var v: Float = 0
            if t < hit {                                   // whoosh swell
                let e = pow(t / hit, 2)
                lp += Float(0.02 + 0.25 * e) * (Float.random(in: -1...1) - lp)
                v += lp * Float(e) * 0.8
            } else {
                let u = t - hit
                let f = 30 + 80 * exp(-u * 1.3)            // falling boom
                v += Float(sin(2 * .pi * f * u) * exp(-u / 0.9))
                lp += 0.06 * (Float.random(in: -1...1) - lp)
                v += lp * Float(exp(-u / 0.15)) * 1.2      // impact noise
                let ring = sin(2 * .pi * 196 * u) + sin(2 * .pi * 233.1 * u) * 0.8 + sin(2 * .pi * 293.7 * u) * 0.6
                v += Float(ring * exp(-u / 1.1)) * 0.22
            }
            out[i] = v
        }
        return out
    }

    static func boom() -> [Float] {
        var out = [Float](repeating: 0, count: Int(1.6 * rate))
        var lp: Float = 0
        for i in 0..<out.count {
            let t = Double(i) / rate
            let a = Float(0.02 + 0.45 * exp(-t / 0.12))
            lp += a * (Float.random(in: -1...1) - lp)
            let thump = sin(2 * .pi * (48 + 40 * exp(-t * 6)) * t)
            out[i] = lp * Float(exp(-t / 0.35)) * 1.4 + Float(thump * exp(-t / 0.45))
        }
        return out
    }

    static func tone(_ f: Double, dur: Double) -> [Float] {
        let n = Int(dur * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            return Float(sin(2 * .pi * f * t) * min(1, t / 0.005) * min(1, (dur - t) / 0.03))
        }
    }

    static func normalize(_ s: inout [Float], peak: Float = 0.85) {
        let m = s.map { abs($0) }.max() ?? 0
        guard m > 0 else { return }
        let g = peak / m
        for i in s.indices { s[i] *= g }
    }

    static func wav(_ s: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(s.count * 2), r = UInt32(rate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(r); u32(r * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for x in s { u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32767))) }
        return d
    }
}

// MARK: - Desktop goose

final class GooseModel: ObservableObject {
    @Published var facingRight = false
    @Published var walking = false
    @Published var phase = 0.0
    @Published var honking = false
}

final class GooseController {
    static let shared = GooseController()
    private let model = GooseModel()
    private var window: NSPanel?
    private var timer: Timer?
    private var pos = CGPoint.zero, target = CGPoint.zero
    private var idleUntil = Date()
    private let size = CGSize(width: 96, height: 96)

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    private var area: NSRect {
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(x: f.minX, y: f.minY, width: f.width - size.width, height: f.height - size.height)
    }

    private func randomPoint() -> CGPoint {
        let a = area
        return CGPoint(x: .random(in: a.minX...a.maxX), y: .random(in: a.minY...a.maxY))
    }

    private func start() {
        guard window == nil else { return }
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.level = .floating
        w.ignoresMouseEvents = true            // it wanders; it never gets in the way of clicks
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GooseView(model: model))
        pos = randomPoint(); target = randomPoint()
        w.setFrameOrigin(pos)
        w.orderFrontRegardless()
        window = w
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
    }

    private func step() {
        guard let w = window else { return }
        if Date() < idleUntil {
            if model.walking { model.walking = false }
            return
        }
        let dx = target.x - pos.x, dy = target.y - pos.y, dist = hypot(dx, dy)
        if dist < 3 {
            idleUntil = Date().addingTimeInterval(.random(in: 0.8...4))
            if Double.random(in: 0...1) < 0.35 { honk() }
            target = randomPoint()
            return
        }
        let speed = 85.0 / 30
        pos.x += dx / dist * min(speed, dist)
        pos.y += dy / dist * min(speed, dist)
        model.walking = true
        if abs(dx) > 1 { model.facingRight = dx > 0 }
        model.phase += 0.42
        w.setFrameOrigin(pos)
    }

    private func honk() {
        model.honking = true
        if Fun.has(Fun.gooseHonks) { SoundBoard.play(.goose) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self.model.honking = false }
    }
}

struct GooseView: View {
    @ObservedObject var model: GooseModel
    var body: some View {
        ZStack(alignment: .top) {
            Text("🪿")
                .font(.system(size: 58))
                .scaleEffect(x: model.facingRight ? -1 : 1, y: 1)     // the emoji faces left
                .rotationEffect(.degrees(model.walking ? sin(model.phase) * 7 : 0), anchor: .bottom)
                .offset(y: model.walking ? -abs(sin(model.phase)) * 4 : 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
            if model.honking {
                Text("HONK!")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white, in: Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 1.5))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 96, height: 96)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: model.honking)
    }
}

// MARK: - Mirror filters

enum MirrorFilter: String, CaseIterable, Identifiable {
    case none, catEars, noir, comic, thermal, xray, sepia, pixel, posterize, invert, bulge, pinch, twirl, kaleidoscope
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Normal"
        case .catEars: "Cat Ears"
        case .noir: "Noir"
        case .comic: "Comic"
        case .thermal: "Thermal"
        case .xray: "X-Ray"
        case .sepia: "Sepia"
        case .pixel: "Pixel"
        case .posterize: "Pop Art"
        case .invert: "Invert"
        case .bulge: "Bulge"
        case .pinch: "Pinch"
        case .twirl: "Twirl"
        case .kaleidoscope: "Kaleidoscope"
        }
    }

    func make() -> CIFilter? {
        switch self {
        case .none, .catEars: return nil   // cat ears are drawn over the face, not a Core Image filter
        case .noir: return CIFilter(name: "CIPhotoEffectNoir")
        case .comic: return CIFilter(name: "CIComicEffect")
        case .thermal: return CIFilter(name: "CIThermal")
        case .xray: return CIFilter(name: "CIXRay")
        case .sepia: return CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .pixel: return CIFilter(name: "CIPixellate", parameters: [kCIInputScaleKey: 16])
        case .posterize: return CIFilter(name: "CIColorPosterize", parameters: ["inputLevels": 4])
        case .invert: return CIFilter(name: "CIColorInvert")
        case .bulge: return CIFilter(name: "CIBumpDistortion")
        case .pinch: return CIFilter(name: "CIPinchDistortion")
        case .twirl: return CIFilter(name: "CITwirlDistortion")
        case .kaleidoscope: return CIFilter(name: "CIKaleidoscope")
        }
    }

    /// Distortions are centered on the frame.
    func configure(_ f: CIFilter, extent: CGRect) {
        let c = CIVector(x: extent.midX, y: extent.midY), r = min(extent.width, extent.height) * 0.45
        switch self {
        case .bulge: f.setValue(c, forKey: kCIInputCenterKey); f.setValue(r, forKey: kCIInputRadiusKey); f.setValue(0.9, forKey: kCIInputScaleKey)
        case .pinch: f.setValue(c, forKey: kCIInputCenterKey); f.setValue(r, forKey: kCIInputRadiusKey); f.setValue(0.6, forKey: kCIInputScaleKey)
        case .twirl: f.setValue(c, forKey: kCIInputCenterKey); f.setValue(r, forKey: kCIInputRadiusKey); f.setValue(3.14, forKey: kCIInputAngleKey)
        case .kaleidoscope: f.setValue(c, forKey: kCIInputCenterKey); f.setValue(6, forKey: "inputCount")
        default: break
        }
    }
}

/// Camera feed that runs each frame through a Core Image filter (only used when a filter is picked;
/// the plain mirror keeps using the cheaper preview layer).
struct FilteredCamera: NSViewRepresentable {
    let filter: MirrorFilter

    final class View: NSView, AVCaptureVideoDataOutputSampleBufferDelegate {
        let session = AVCaptureSession()
        private let output = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "onyx.mirror.filter")
        private let ctx = CIContext(options: [.cacheIntermediates: false])
        private let lock = NSLock()
        private var kind: MirrorFilter = .none
        private var ciFilter: CIFilter?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.contentsGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError() }

        func setFilter(_ f: MirrorFilter) {
            lock.lock(); defer { lock.unlock() }
            guard f != kind else { return }
            kind = f; ciFilter = f.make()
        }

        func start() {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { return }
                self.queue.async {
                    guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { return }
                    self.session.beginConfiguration()
                    if self.session.canSetSessionPreset(.vga640x480) { self.session.sessionPreset = .vga640x480 }
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.setSampleBufferDelegate(self, queue: self.queue)
                    if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                    self.session.commitConfiguration()
                    self.session.startRunning()
                }
            }
        }
        func stop() { queue.async { self.session.stopRunning() } }

        func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            var img = CIImage(cvPixelBuffer: pb).oriented(.upMirrored)
            let extent = img.extent
            lock.lock(); let f = ciFilter, k = kind; lock.unlock()
            if let f {
                f.setValue(img, forKey: kCIInputImageKey)
                k.configure(f, extent: extent)
                if let o = f.outputImage { img = o.cropped(to: extent) }
            }
            guard var cg = ctx.createCGImage(img, from: extent) else { return }
            if k == .catEars { cg = drawCatEars(on: cg, source: img) ?? cg }
            DispatchQueue.main.async { self.layer?.contents = cg }
        }

        // MARK: Cat ears (face tracking; only touched on `queue`)
        private let faceRequest = VNDetectFaceLandmarksRequest()
        private var ears: (rect: CGRect, angle: CGFloat)?
        private var missed = 0

        private func drawCatEars(on cg: CGImage, source: CIImage) -> CGImage? {
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            try? VNImageRequestHandler(ciImage: source, options: [:]).perform([faceRequest])
            if let face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                let b = face.boundingBox
                let r = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
                var angle: CGFloat = 0
                if let l = face.landmarks?.leftEye, let rt = face.landmarks?.rightEye {
                    let size = CGSize(width: w, height: h)
                    let p1 = Self.centroid(l.pointsInImage(imageSize: size)), p2 = Self.centroid(rt.pointsInImage(imageSize: size))
                    let (a, c) = p1.x < p2.x ? (p1, p2) : (p2, p1)
                    angle = atan2(c.y - a.y, c.x - a.x)
                }
                // Smooth so the ears don't jitter.
                if let e = ears {
                    let t: CGFloat = 0.45
                    func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
                    ears = (CGRect(x: mix(e.rect.minX, r.minX), y: mix(e.rect.minY, r.minY),
                                   width: mix(e.rect.width, r.width), height: mix(e.rect.height, r.height)), mix(e.angle, angle))
                } else { ears = (r, angle) }
                missed = 0
            } else {
                missed += 1
                if missed > 8 { ears = nil }
            }
            guard let e = ears,
                  let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Face box runs brow → chin, so the ears sit a bit above its top edge, tilted with the head.
            c.translateBy(x: e.rect.midX, y: e.rect.midY)
            c.rotate(by: e.angle)
            for side: CGFloat in [-1, 1] {
                Self.drawEar(c, at: CGPoint(x: side * e.rect.width * 0.32, y: e.rect.height * 0.6),
                             size: e.rect.width * 0.38, tilt: -side * 0.3)
            }
            return c.makeImage()
        }

        private static func centroid(_ pts: [CGPoint]) -> CGPoint {
            guard !pts.isEmpty else { return .zero }
            let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
        }

        private static func drawEar(_ c: CGContext, at p: CGPoint, size s: CGFloat, tilt: CGFloat) {
            func shape(_ k: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: -s * 0.5 * k, y: 0))
                path.addQuadCurve(to: CGPoint(x: 0, y: s * 1.1 * k), control: CGPoint(x: -s * 0.42 * k, y: s * 0.7 * k))
                path.addQuadCurve(to: CGPoint(x: s * 0.5 * k, y: 0), control: CGPoint(x: s * 0.42 * k, y: s * 0.7 * k))
                path.addQuadCurve(to: CGPoint(x: -s * 0.5 * k, y: 0), control: CGPoint(x: 0, y: -s * 0.12 * k))
                return path
            }
            c.saveGState()
            c.translateBy(x: p.x, y: p.y); c.rotate(by: tilt)
            c.addPath(shape(1))
            c.setFillColor(CGColor(red: 0.17, green: 0.14, blue: 0.13, alpha: 1))
            c.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)); c.setLineWidth(max(1.5, s * 0.04))
            c.drawPath(using: .fillStroke)
            c.translateBy(x: 0, y: s * 0.1)
            c.addPath(shape(0.6))
            c.setFillColor(CGColor(red: 1, green: 0.64, blue: 0.74, alpha: 1)); c.fillPath()
            c.restoreGState()
        }
    }

    func makeNSView(context: Context) -> View { let v = View(frame: .zero); v.setFilter(filter); v.start(); return v }
    func updateNSView(_ v: View, context: Context) { v.setFilter(filter) }
    static func dismantleNSView(_ v: View, coordinator: ()) { v.stop() }
}

/// The mirror's camera: plain preview, or the filtered feed when Fun mode has a filter picked.
struct MirrorCamera: View {
    @AppStorage(Fun.mirrorFilter) private var raw = "none"
    @ObservedObject private var appearance = AppearanceStore.shared
    var showPicker = true

    var body: some View {
        let f = Fun.has(Fun.mirrorFilters) ? (MirrorFilter(rawValue: raw) ?? .none) : .none
        ZStack(alignment: .topLeading) {
            if f == .none { CameraPreview() } else { FilteredCamera(filter: f) }
            if showPicker && Fun.has(Fun.mirrorFilters) {
                HStack(spacing: 4) {
                    Menu {
                        ForEach(MirrorFilter.allCases) { m in
                            Button { raw = m.rawValue } label: { Label(m.title, systemImage: m == f ? "checkmark" : "camera.filters") }
                        }
                    } label: { Label(f.title, systemImage: "camera.filters").font(.system(size: 10, weight: .semibold)) }
                        .menuStyle(.borderlessButton).fixedSize()
                    Button {
                        let all = MirrorFilter.allCases
                        raw = all[((all.firstIndex(of: f) ?? 0) + 1) % all.count].rawValue
                    } label: { Image(systemName: "shuffle").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).help("Next filter")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
        }
    }
}
