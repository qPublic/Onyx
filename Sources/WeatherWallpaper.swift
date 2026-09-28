import AppKit
import SwiftUI
import Combine
import Metal
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Weather-reactive wallpapers: when it's really raining, snowing, foggy or stormy where you are, the live
// wallpaper gets it too, drawn on top by a see-through GPU layer (Live Wallpapers › Match the weather)

enum WallWeather: UInt32 {
    case none = 0, rain, snow, fog, storm, drizzle

    static let key = "wall.weather"

    /// From the weather code (WMO) Onyx already has. ONYX_WEATHER=rain|snow|fog|storm|drizzle forces one, for testing.
    static var now: WallWeather {
        if let f = ProcessInfo.processInfo.environment["ONYX_WEATHER"] {
            return ["rain": .rain, "snow": .snow, "fog": .fog, "storm": .storm, "drizzle": .drizzle][f] ?? .none
        }
        guard Prefs.bool(key) else { return .none }
        switch WeatherService.shared.code {
        case 45, 48: return .fog
        case 51...57: return .drizzle
        case 61...67, 80...82: return .rain
        case 71...77, 85, 86: return .snow
        case 95...99: return .storm
        default: return .none
        }
    }

    var title: String {
        switch self {
        case .none: "Clear"
        case .rain: "Rain"
        case .snow: "Snow"
        case .fog: "Fog"
        case .storm: "Thunderstorm"
        case .drizzle: "Drizzle"
        }
    }
}

private struct WeatherUniforms { var res: SIMD2<Float>; var time: Float; var kind: UInt32 }

final class WeatherOverlayView: MTKView, MTKViewDelegate {
    var kind: WallWeather = .none { didSet { isHidden = kind == .none; updateRunning() } }
    private var wantsToRun = false
    private let start = CACurrentMediaTime()
    private static var pipeline: MTLRenderPipelineState? = {
        guard let device = GPU.device, let lib = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "wx_vertex")
        d.fragmentFunction = lib.makeFunction(name: "wx_fragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }()

    init(frame: NSRect) {
        super.init(frame: frame, device: GPU.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false   // see-through: only the weather is drawn
        preferredFramesPerSecond = 30
        autoResizeDrawable = false
        isPaused = true; enableSetNeedsDisplay = false
        isHidden = true
        autoresizingMask = [.width, .height]
    }
    required init(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        let k = (window?.backingScaleFactor ?? 2) * 0.5   // half resolution is plenty for rain and snow
        drawableSize = CGSize(width: max(s.width * k, 1), height: max(s.height * k, 1))
    }

    func setRunning(_ on: Bool) { wantsToRun = on; updateRunning() }
    private func updateRunning() { isPaused = !(wantsToRun && kind != .none) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipe = Self.pipeline, let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cmd = GPU.queue?.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = WeatherUniforms(res: SIMD2(Float(drawableSize.width), Float(drawableSize.height)), time: Float(CACurrentMediaTime() - start), kind: kind.rawValue)
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(&u, length: MemoryLayout<WeatherUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Premultiplied color: streaks of rain, drifting snow, low fog, and the odd lightning flash.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut wx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    struct U { float2 res; float time; uint kind; };
    float h21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
        return mix(mix(h21(i), h21(i + float2(1, 0)), f.x), mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), f.x), f.y);
    }
    fragment float4 wx_fragment(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 uv = in.uv; float aspect = u.res.x / u.res.y; float t = u.time;
        float2 st = float2(uv.x * aspect, uv.y);
        float a = 0.0; float3 col = float3(0.78, 0.84, 0.95);
        if (u.kind == 1u || u.kind == 4u || u.kind == 5u) {            // rain, storm, drizzle
            float density = u.kind == 5u ? 0.25 : u.kind == 4u ? 0.7 : 0.5;
            float2 r = st; r.x += r.y * 0.1;                                // a little slant
            for (int l = 0; l < 3; l++) {
                float s = 38.0 + float(l) * 26.0;
                float2 g = float2(r.x * s, r.y * s * 0.07 - t * (1.6 + float(l) * 0.5));
                float2 id = floor(g), f = fract(g);
                float h = h21(id + float(l) * 31.7);
                if (h < density) {
                    float x = abs(f.x - 0.5 - (h - 0.5) * 0.5);
                    float len = 0.35 + 0.3 * h21(id + 9.1);
                    float streak = smoothstep(0.09, 0.0, x) * smoothstep(0.0, 0.1, f.y) * smoothstep(len, len - 0.15, f.y);
                    a += streak * (0.16 + 0.1 * float(l));
                }
            }
            if (u.kind == 4u) {                                             // lightning, now and then
                float slot = floor(t * 2.0);
                float strike = step(0.985, h21(float2(slot, 3.7)));
                float flick = strike * (0.5 + 0.5 * sin(fract(t * 2.0) * 40.0)) * (1.0 - fract(t * 2.0));
                a += flick * 0.28;
            }
        }
        if (u.kind == 2u) {                                                 // snow
            for (int l = 0; l < 3; l++) {
                float s = 7.0 + float(l) * 5.0;
                float2 g = st * s; g.y -= t * (0.22 + 0.1 * float(l)); g.x += sin(t * 0.6 + g.y * 0.8 + float(l) * 2.0) * 0.35;
                float2 id = floor(g), f = fract(g);
                if (h21(id + float(l) * 7.1) < 0.55) {
                    float2 c = float2(0.5 + (h21(id + 3.1) - 0.5) * 0.6, 0.5 + (h21(id + 5.3) - 0.5) * 0.6);
                    a += smoothstep(0.09 - float(l) * 0.018, 0.0, length(f - c)) * (0.45 + 0.2 * float(l));
                }
            }
            col = float3(0.95, 0.97, 1.0);
        }
        if (u.kind == 3u || u.kind == 4u) {                                 // fog (and storm haze), thickest low down
            float n = vnoise(st * 2.2 + float2(t * 0.03, 0.0)) * 0.6 + vnoise(st * 5.0 - float2(t * 0.05, 0.0)) * 0.4;
            float fog = n * smoothstep(0.15, 1.0, uv.y) * (u.kind == 3u ? 0.42 : 0.18);
            a = a + fog * (1.0 - a);
        }
        a = clamp(a, 0.0, 0.85);
        return float4(col * a, a);
    }
    """
}

/// Keeps every wallpaper window's weather layer in step with the actual weather.
final class WeatherWallpaper {
    static let shared = WeatherWallpaper()
    private var bag = Set<AnyCancellable>()

    func start() {
        WeatherService.shared.$code.removeDuplicates().receive(on: DispatchQueue.main).sink { _ in
            DispatchQueue.main.async { WallpaperEngine.shared.updateWeather() }
        }.store(in: &bag)
    }
}

// MARK: - Day, sunset and night versions of an AI loop, switched by the real sun

enum DayPhase: String, CaseIterable {
    case day, dusk, night

    /// Night from 40 minutes after sunset to 40 minutes before sunrise; dusk within an hour either side of them.
    static func now(_ date: Date = Date()) -> DayPhase {
        if let (lat, lon) = WeatherService.shared.coordinates, let sun = WallpaperEngine.sunTimes(lat: lat, lon: lon, date: date) {
            let toRise = date.timeIntervalSince(sun.rise), toSet = date.timeIntervalSince(sun.set)
            if toSet > 40 * 60 || toRise < -40 * 60 { return .night }
            if abs(toSet) <= 60 * 60 || abs(toRise) <= 60 * 60 { return .dusk }
            return .day
        }
        let h = Calendar.current.component(.hour, from: date)
        return h < 6 || h >= 20 ? .night : (h < 8 || h >= 18) ? .dusk : .day
    }

    /// The picture relit for this time of day (the same scene, so the loops match; night adds stars).
    static func relight(_ img: CGImage, for phase: DayPhase) -> CGImage? {
        guard phase != .day else { return img }
        let ci = CIImage(cgImage: img)
        let m = CIFilter.colorMatrix()
        m.inputImage = ci
        let exposure = CIFilter.exposureAdjust(), sat = CIFilter.colorControls()
        switch phase {
        case .dusk:
            m.rVector = CIVector(x: 1.12, y: 0, z: 0, w: 0); m.gVector = CIVector(x: 0, y: 0.88, z: 0, w: 0); m.bVector = CIVector(x: 0, y: 0, z: 0.72, w: 0)
            exposure.ev = -0.35; sat.saturation = 1.15
        default:
            m.rVector = CIVector(x: 0.5, y: 0, z: 0, w: 0); m.gVector = CIVector(x: 0, y: 0.62, z: 0, w: 0); m.bVector = CIVector(x: 0, y: 0, z: 1.05, w: 0)
            exposure.ev = -1.5; sat.saturation = 0.65
        }
        exposure.inputImage = m.outputImage
        sat.inputImage = exposure.outputImage; sat.brightness = 0; sat.contrast = 1.05
        guard let out = sat.outputImage else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    /// Effects that suit the time of day, on top of the ones picked for the scene.
    var extraEffects: UInt32 { self == .night ? LoopEffect.stars.bit : 0 }
}
