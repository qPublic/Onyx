import AppKit
import Metal
import MetalKit
import QuartzCore
import CoreText

// MARK: - GPU scenes: the game-style pack (Neon Horizon, Rain City, Pixel Dusk, Hyperspace, Code Rain) and the
// "living picture" effect behind AI loops. Metal shaders, compiled on this Mac the first time they're used.

struct SceneUniforms { var res: SIMD2<Float>; var time: Float; var seed: Float }
struct LivingUniforms { var res: SIMD2<Float>; var time: Float; var period: Float; var motion: Float; var fx: UInt32; var seed: Float; var pad: Float = 0 }

enum GPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    nonisolated(unsafe) static var compileError: String?
    nonisolated(unsafe) private static var pipelines: [String: MTLRenderPipelineState] = [:]
    private static let lock = NSLock()

    static let library: MTLLibrary? = {
        guard let device else { return nil }
        do { return try device.makeLibrary(source: shaderSource, options: nil) } catch { compileError = "\(error)"; return nil }
    }()

    static func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[fragment] { return p }
        guard let device, let lib = library, let v = lib.makeFunction(name: "fullscreen"), let f = lib.makeFunction(name: fragment) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        do { let p = try device.makeRenderPipelineState(descriptor: d); pipelines[fragment] = p; return p } catch { compileError = "\(error)"; return nil }
    }

    /// Code Rain's characters: mirrored half-width katakana and digits, white on black, 8×8 to a texture.
    static let glyphs: MTLTexture? = {
        guard let device else { return nil }
        let n = 8, cell = 64, size = n * cell
        let chars = Array("ｦｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789Z:=*+-<>")
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let font = CTFontCreateWithName("HiraginoSans-W4" as CFString, 46, nil)
        for (i, ch) in chars.prefix(n * n).enumerated() {
            let str = NSAttributedString(string: String(ch), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(str)
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let cx = CGFloat(i % n * cell) + CGFloat(cell) / 2, cy = CGFloat(size - (i / n + 1) * cell) + CGFloat(cell) / 2
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: -1, y: 1)   // mirrored, like the films
            ctx.textPosition = CGPoint(x: -b.midX, y: -b.midY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)
        tex?.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: data, bytesPerRow: size)
        return tex
    }()

    /// Draws one frame into a texture (the view, a video frame, or a snapshot).
    static func encode(_ cmd: MTLCommandBuffer, into target: MTLTexture, fragment: String, bytes: UnsafeRawPointer, length: Int, textures: [MTLTexture?]) -> Bool {
        guard let pipe = pipeline(fragment) else { return false }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return false }
        enc.setRenderPipelineState(pipe)
        enc.setFragmentBytes(bytes, length: length, index: 0)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    /// A still of a scene, for library cards and desktop pictures.
    static func snapshot(_ scene: WallpaperScene, size: CGSize, time: Float = 14) -> CGImage? {
        guard let device, let queue, let fragment = scene.shader else { return nil }
        let w = max(Int(size.width), 8), h = max(Int(size.height), 8)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d), let cmd = queue.makeCommandBuffer() else { return nil }
        var u = SceneUniforms(res: SIMD2(Float(w), Float(h)), time: time, seed: 0)
        guard encode(cmd, into: tex, fragment: fragment, bytes: &u, length: MemoryLayout<SceneUniforms>.stride,
                     textures: scene == .codeRain ? [glyphs] : []) else { return nil }
        cmd.commit(); cmd.waitUntilCompleted()
        return image(tex)
    }

    static func image(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A live GPU scene on the desktop. Draws at 30 fps, at a fraction of the screen's pixels (the scenes are soft
/// or pixel-art, so it doesn't show), and stops drawing entirely while paused.
final class ShaderView: MTKView, MTKViewDelegate {
    let scene: WallpaperScene
    private var start = CACurrentMediaTime()
    private var pausedAt: CFTimeInterval?

    init(scene: WallpaperScene, frame: NSRect) {
        self.scene = scene
        super.init(frame: frame, device: GPU.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 30
        autoResizeDrawable = false
        layer?.isOpaque = true
        if scene == .pixelDusk { layer?.magnificationFilter = .nearest }
        resize()
    }
    required init(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); resize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize() }
    private func resize() {
        let k = (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) * scene.renderScale
        drawableSize = CGSize(width: max(bounds.width * k, 16), height: max(bounds.height * k, 16))
    }

    func setRunning(_ on: Bool) {
        if on, let p = pausedAt { start += CACurrentMediaTime() - p; pausedAt = nil; isPaused = false }
        else if !on, pausedAt == nil { pausedAt = CACurrentMediaTime(); isPaused = true }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let fragment = scene.shader, let drawable = currentDrawable, let cmd = GPU.queue?.makeCommandBuffer() else { return }
        var u = SceneUniforms(res: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                              time: Float(fmod(CACurrentMediaTime() - start, 3000)), seed: 0)
        guard GPU.encode(cmd, into: drawable.texture, fragment: fragment, bytes: &u, length: MemoryLayout<SceneUniforms>.stride,
                         textures: scene == .codeRain ? [GPU.glyphs] : []) else { return }
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - The shaders

private let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float2 res; float time; float seed; };
struct LU { float2 res; float time; float period; float motion; uint fx; float seed; float pad; };

// One triangle that covers the screen; uv is 0…1 with y pointing up.
vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float hash21(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}
float fbm(float2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; } return v; }
float3 vignette(float3 c, float2 uv, float k) { float2 v = uv - 0.5; return c * (1.0 - dot(v, v) * k); }

// ---- Neon Horizon: an 80s synthwave sunset over an endless neon grid
fragment float4 synthwave(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float a = u.res.x / u.res.y;
    float2 p = float2((in.uv.x - 0.5) * a, in.uv.y);
    float t = u.time;
    const float hz = 0.38;
    // Everything that needs screen-space derivatives is worked out before branching.
    float dep = max(hz - p.y, 1e-4);
    float z = 0.28 / dep;
    float2 g = float2(p.x * z, z + t * 1.6);
    float2 gfw = fwidth(g);
    float2 sc = float2(0.0, hz + 0.17);
    const float sr = 0.2;
    float d = length(p - sc);
    float daa = fwidth(d);
    float sy = (sc.y + sr * 0.15 - p.y) / sr;
    float sfw = fwidth(sy * 5.5);
    float3 col;
    if (p.y >= hz) {
        float h = (p.y - hz) / (1.0 - hz);
        col = mix(float3(1.0, 0.42, 0.40), float3(0.62, 0.14, 0.52), smoothstep(0.0, 0.35, h));
        col = mix(col, float3(0.07, 0.02, 0.17), smoothstep(0.3, 0.95, h));
        float2 sp = p * 80.0;
        float2 id = floor(sp);
        float r = hash21(id);
        if (r > 0.975) {
            float2 off = hash22(id) - 0.5;
            float sd = length(fract(sp) - 0.5 - off * 0.6);
            float tw = 0.55 + 0.45 * sin(t * (0.8 + r * 3.0) + r * 60.0);
            col += float3(1.0, 0.9, 1.0) * smoothstep(0.09, 0.0, sd) * tw * smoothstep(0.3, 0.75, h);
        }
        float3 sunCol = mix(float3(1.0, 0.18, 0.55), float3(1.0, 0.9, 0.3), smoothstep(sc.y - sr * 0.9, sc.y + sr * 0.8, p.y));
        float cut = 1.0;
        if (sy > 0.0) {
            float k = fract(sy * 5.5 + t * 0.12);
            float gap = 0.08 + 0.42 * clamp(sy, 0.0, 1.0);
            cut = smoothstep(gap - sfw, gap + sfw, k);
        }
        col = mix(col, sunCol, smoothstep(sr + daa, sr - daa, d) * cut);
        col += float3(1.0, 0.3, 0.5) * 0.45 * exp(-max(d - sr, 0.0) * 7.0);
        float edge = smoothstep(0.12, 0.95, abs(p.x) / (a * 0.5));
        float m = hz + (0.015 + 0.2 * edge) * fbm(float2(p.x * 2.2 + 3.0, 0.5)) * 1.5;
        if (p.y < m) {
            float f = (p.y - hz) / max(m - hz, 1e-3);
            col = mix(float3(0.05, 0.01, 0.10), float3(0.18, 0.04, 0.28), f);
            float wire = smoothstep(0.035, 0.0, abs(fract(p.x * 14.0 + f * 1.5) - 0.5) - 0.44) * f;
            col += float3(0.5, 0.15, 0.7) * wire * 0.25;
            col += float3(0.3, 0.9, 1.0) * smoothstep(0.006, 0.0, m - p.y) * 0.9;
        }
    } else {
        float2 dist = abs(fract(g + 0.5) - 0.5);
        float2 line = 1.0 - smoothstep(gfw * 0.8, gfw * 2.2, dist);        // a couple of pixels wide at any distance
        float2 glow = exp(-dist / (gfw * 7.0 + 1e-4)) * 0.35;
        float grid = max(max(line.x, line.y), max(glow.x, glow.y));
        float fade = smoothstep(0.0, 0.1, dep) * (1.0 - smoothstep(0.2, 0.5, max(gfw.x, gfw.y)));
        col = mix(float3(0.10, 0.01, 0.16), float3(0.03, 0.0, 0.07), smoothstep(0.0, 0.38, dep));
        col += float3(1.0, 0.2, 0.85) * grid * fade * 1.1;
        col += float3(1.0, 0.25, 0.6) * exp(-dep * 18.0) * 0.55;
        col += float3(1.0, 0.45, 0.5) * exp(-abs(p.x) * 5.0) * exp(-dep * 6.0) * 0.25;
    }
    col += float3(1.0, 0.35, 0.6) * exp(-abs(p.y - hz) * 60.0) * 0.5;
    return float4(vignette(col, in.uv, 0.6), 1.0);
}

// ---- Rain City: a night skyline scrolling past in the rain
fragment float4 raincity(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float a = u.res.x / u.res.y;
    float2 p = float2((in.uv.x - 0.5) * a, in.uv.y);
    float t = u.time;
    float3 col = mix(float3(0.17, 0.07, 0.23), float3(0.015, 0.02, 0.06), smoothstep(0.05, 0.9, p.y));
    float cl = fbm(float2(p.x * 1.4 + t * 0.008, p.y * 3.0 + 4.0));
    col += float3(0.4, 0.14, 0.38) * smoothstep(0.45, 0.85, cl) * smoothstep(1.0, 0.4, p.y) * 0.45;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float den = 15.0 - fi * 3.4;
        float x = p.x * den + t * (0.03 + fi * 0.035) + fi * 37.0;
        float id = floor(x), fx = fract(x);
        float hb = hash11(id * 1.37 + fi * 11.0);
        float h = 0.22 + hb * (0.45 - fi * 0.06) + (3.0 - fi) * 0.07;
        float gap = 0.04 + hash11(id + fi * 5.0) * 0.12;
        if (fx > gap && fx < 1.0 - gap && p.y < h) {
            float3 fog = float3(0.22, 0.10, 0.30);
            float3 b = mix(fog * 0.85, float3(0.015, 0.015, 0.04), (fi + 1.0) / 4.0);
            float bw = (fx - gap) / (1.0 - 2.0 * gap);
            float cols = floor(4.0 + hb * 5.0);
            float rows = 80.0 - fi * 12.0;
            float2 wc = float2(bw * cols, p.y * rows);
            float2 wid = floor(wc), wf = fract(wc);
            float lit = step(0.6, hash21(wid + float2(id * 7.0, fi * 100.0) + floor(t * 0.03 + hash21(wid + id) * 10.0)));
            float win = step(0.22, wf.x) * step(wf.x, 0.78) * step(0.3, wf.y) * step(wf.y, 0.75) * step(wc.y, h * rows - 1.5);
            float hue = hash21(wid * 3.1 + id);
            float3 wcol = hue < 0.6 ? float3(1.0, 0.75, 0.4) : (hue < 0.85 ? float3(0.5, 0.85, 1.0) : float3(1.0, 0.4, 0.8));
            b += wcol * win * lit * mix(0.3, 0.95, fi / 3.0);
            if (i > 0 && hash11(id * 3.7 + fi) > 0.72) {
                float sx = abs(bw - 0.5);
                float inY = step(h * 0.35, p.y) * step(p.y, h * 0.75);
                float3 nc = hash11(id + 2.0) > 0.5 ? float3(1.0, 0.2, 0.6) : float3(0.2, 0.9, 1.0);
                float flick = step(0.06, hash11(floor(t * 7.0) + id * 13.0));
                b = mix(b, nc * 1.2, step(sx, 0.07) * inY * flick);
                b += nc * 0.3 * exp(-sx * 16.0) * inY * flick;
            }
            col = b;
        }
    }
    col += float3(0.45, 0.15, 0.4) * exp(-p.y * 10.0) * 0.5;
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float2 rp = float2((p.x + p.y * 0.15) * (70.0 + fk * 45.0), p.y * (5.0 + fk * 2.0) + t * (3.5 + fk * 1.2));
        float cid = floor(rp.x);
        float y = rp.y + hash11(cid * 1.3 + fk * 10.0) * 7.0;
        float fy = fract(y);
        float show = step(0.6, hash21(float2(cid, floor(y)) + fk * 3.0));
        float streak = (1.0 - fy / 0.3) * step(fy, 0.3);
        float w = smoothstep(0.14, 0.0, abs(fract(rp.x) - 0.5));
        col += float3(0.55, 0.65, 0.85) * streak * w * show * (0.24 - fk * 0.06);
    }
    return float4(vignette(col, in.uv, 0.7), 1.0);
}

// ---- Pixel Dusk: a pixel-art sunset over the sea
constant float bayer4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

fragment float4 pixeldusk(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float ps = max(u.res.y / 180.0, 1.0);
    float2 vp = floor(in.pos.xy / ps);
    float2 vres = u.res / ps;
    float2 uv = float2((vp.x + 0.5) / vres.x, 1.0 - (vp.y + 0.5) / vres.y);
    float a = u.res.x / u.res.y;
    float2 p = float2((uv.x - 0.5) * a, uv.y);
    float t = u.time;
    float dither = (bayer4[int(fmod(vp.x, 4.0)) + int(fmod(vp.y, 4.0)) * 4] + 0.5) / 16.0;
    const float hz = 0.34;
    float3 col;
    if (p.y >= hz) {
        float h = (p.y - hz) / (1.0 - hz);
        float band = clamp(floor(h * 5.0 + dither - 0.5), 0.0, 4.0);
        col = band < 0.5 ? float3(1.0, 0.78, 0.42) : band < 1.5 ? float3(0.99, 0.52, 0.36) : band < 2.5 ? float3(0.80, 0.30, 0.45)
            : band < 3.5 ? float3(0.45, 0.17, 0.47) : float3(0.19, 0.10, 0.33);
        float2 sc = float2(0.0, hz + 0.06);
        const float sr = 0.15;
        float d = length(p - sc);
        if (d < sr) {
            col = p.y > sc.y + sr * 0.1 ? float3(1.0, 0.95, 0.62) : float3(1.0, 0.8, 0.42);
            float ry = (sc.y - p.y) / sr;
            if (ry > 0.05 && fract(ry * 3.2 + t * 0.05) < 0.16 + ry * 0.12) col = float3(0.99, 0.52, 0.36);
        }
        float c = fbm(float2(p.x * 1.6 + t * 0.012, p.y * 5.0));
        float cm = c * (0.55 + 0.6 * sin(clamp((h - 0.2) / 0.75, 0.0, 1.0) * 3.14159));
        if (cm > 0.6) col = cm > 0.67 ? float3(0.98, 0.64, 0.62) : float3(0.62, 0.25, 0.50);
        float m1 = hz + 0.02 + 0.10 * fbm(float2(p.x * 2.5 + t * 0.004 + 10.0, 1.0));
        float m2 = hz + 0.16 * smoothstep(0.35, 1.0, abs(p.x) / (a * 0.5)) * (0.4 + fbm(float2(p.x * 4.0 + 2.0 + t * 0.008, 3.0)));
        if (p.y < m1) col = float3(0.36, 0.16, 0.42);
        if (p.y < m2) col = float3(0.17, 0.08, 0.26);
    } else {
        float dep = (hz - p.y) / hz;
        float band = clamp(floor(dep * 4.0 + dither - 0.5), 0.0, 3.0);
        col = band < 0.5 ? float3(0.55, 0.25, 0.47) : band < 1.5 ? float3(0.36, 0.16, 0.42) : band < 2.5 ? float3(0.22, 0.10, 0.34) : float3(0.12, 0.07, 0.24);
        float row = vp.y;
        float wv = 0.15 * (0.35 + 0.65 * hash11(row * 0.37)) * (0.75 + 0.25 * sin(t * 1.3 + row * 0.9));
        float shift = sin(t * 0.8 + row * 0.5) * 0.02;
        if (abs(p.x - shift) < wv * (1.0 - dep * 0.4) && hash11(row * 1.7 + floor(t * 2.0)) > 0.25)
            col = dep < 0.35 ? float3(1.0, 0.85, 0.5) : float3(0.99, 0.55, 0.40);
        float s = hash21(floor(vp / float2(6.0, 3.0)));
        if (s > 0.93 && fract(t * 0.5 + s * 10.0) < 0.12 && fmod(vp.x, 6.0) == 2.0 && fmod(vp.y, 3.0) == 1.0) col = float3(1.0, 0.9, 0.8);
    }
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float bx = fract(t * 0.008 + fk * 0.31) * (vres.x + 40.0) - 20.0;
        float by = vres.y * (0.2 + fk * 0.06) + sin(t * 0.7 + fk) * 2.0;
        float2 l = vp - floor(float2(bx + fk * 9.0, by));
        if (l.x >= 0.0 && l.x < 5.0 && l.y >= 0.0 && l.y < 3.0) {
            uint bits = fract(t * 2.2 + fk * 0.3) < 0.5 ? 0x1151u : 0x1360u;
            if (((bits >> uint(l.y * 5.0 + l.x)) & 1u) != 0u) col = float3(0.15, 0.06, 0.2);
        }
    }
    return float4(col, 1.0);
}

// ---- Hyperspace: stars stretching into streaks as you jump
fragment float4 hyperspace(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float a = u.res.x / u.res.y;
    float2 p = (in.uv - 0.5) * float2(a, 1.0);
    float t = u.time;
    float r = max(length(p), 1e-4);
    float ang = atan2(p.y, p.x) + t * 0.02;
    float3 col = float3(0.0, 0.0, 0.02);
    col += float3(0.3, 0.45, 1.0) * 0.1 / (r * 6.0 + 0.25);
    float n = fbm(p / r * 1.6 + float2(0.0, log(r) * 2.0 - t * 0.7));
    col += mix(float3(0.25, 0.1, 0.6), float3(0.1, 0.35, 0.8), n) * n * n * 0.55 * smoothstep(0.02, 0.5, r);
    float a01 = fract(ang / 6.2831853 + 0.5);
    for (int L = 0; L < 3; L++) {
        float fl = float(L);
        float bins = 90.0 + fl * 70.0;
        float bin = floor(a01 * bins);
        float fa = fract(a01 * bins) - 0.5;
        float h = hash11(bin * 7.13 + fl * 31.0);
        float z = fract(h * 13.7 + t * (0.18 + h * 0.3) * (0.6 + fl * 0.3));
        float rs = 0.04 / max(1.0 - z * 0.985, 0.02);
        float len = rs * (0.12 + z * 0.55);
        float across = smoothstep(0.0012 + z * 0.0035, 0.0, abs(fa) / bins * 6.2831853 * r);
        float along = smoothstep(rs - len, rs, r) * step(r, rs);
        col += mix(float3(0.45, 0.55, 1.0), float3(1.0), z) * along * across * z * 1.6;
    }
    return float4(vignette(col, in.uv, 0.5), 1.0);
}

// ---- Code Rain: falling green characters
fragment float4 coderain(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float t = u.time;
    float3 col = float3(0.0, 0.02, 0.01);
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        float rows = L == 0 ? 72.0 : 44.0;
        float ch = u.res.y / rows, cw = ch * 0.62;
        float2 cf = in.pos.xy / float2(cw, ch);
        float2 cell = floor(cf), f = fract(cf);
        float colId = cell.x + fl * 1000.0;
        float inten = 0.0, head = 0.0;
        for (int k = 0; k < 2; k++) {
            float fk = float(k);
            float h = hash11(colId * 1.13 + fk * 57.0);
            float speed = 5.0 + h * 12.0;
            float len = 6.0 + hash11(colId + fk * 3.0) * 22.0;
            float total = rows + len + 10.0 + h * 30.0;
            float dd = fmod(t * speed + h * 400.0, total) - cell.y;
            if (dd >= 0.0 && dd < len) { float v = 1.0 - dd / len; if (v > inten) { inten = v; head = step(dd, 1.0); } }
        }
        if (inten > 0.0) {
            float gh = hash21(cell + float2(fl * 50.0, 0.0));
            float gi = fmod(floor(gh * 64.0 + floor(t * (0.6 + gh * 2.5) + gh * 10.0) + head * floor(t * 12.0)), 64.0);
            float2 guv = (float2(fmod(gi, 8.0), floor(gi / 8.0)) + f * 0.9 + 0.05) / 8.0;
            float gl = atlas.sample(s, guv).r;
            float bright = L == 0 ? 0.32 : 1.0;
            float3 gc = mix(float3(0.1, 0.9, 0.35) * pow(inten, 1.6), float3(0.85, 1.0, 0.9), head);
            col += gc * gl * bright + float3(0.0, 0.25, 0.08) * inten * inten * 0.12 * bright;
        }
    }
    return float4(vignette(col, in.uv, 0.9), 1.0);
}

// ---- Living picture: a still brought to life. Near things drift against far things (from its depth map), plus
// weather and light. Everything moves on whole cycles of the loop, so the last frame runs straight into the first.
float2 rot(float2 v, float a) { float c = cos(a), s = sin(a); return float2(c * v.x - s * v.y, s * v.x + c * v.y); }
// How much of something floating at depth z shows at a spot whose scene depth is d (nearer things hide it).
float occ(float z, float d) { return 1.0 - smoothstep(z - 0.06, z + 0.06, d); }

fragment float4 living(VOut in [[stage_in]], constant LU &u [[buffer(0)]],
                       texture2d<float> img [[texture(0)]], texture2d<float> dep [[texture(1)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float a = u.res.x / u.res.y;
    float lt = u.time / u.period;          // 0…1 over one loop
    float ph = 6.2831853 * lt;
    float2 tuv = float2(in.uv.x, 1.0 - in.uv.y);
    // A slow, mostly sideways drift of the viewpoint, with just enough zoom that the edges never show.
    float2 cam = float2(cos(ph), sin(ph) * 0.35) * u.motion;
    float2 c = (tuv - 0.5) / (1.0 + u.motion * 1.6) + 0.5;
    // March from near (t = 1) to far (t = 0) and stop at the first surface the ray meets, so near things slide over
    // far ones as solid objects instead of dragging the background along with them. Then narrow it down.
    const float d0 = 0.4;                   // this depth stays put; nearer moves with the camera, farther against it
    float hit = 0.0, miss = 1.0, d = 0.0;
    for (int i = 0; i <= 32; i++) {
        float t = 1.0 - float(i) / 32.0;
        if (dep.sample(s, c + cam * (t - d0)).r >= t) { hit = t; break; }
        miss = t;
    }
    for (int k = 0; k < 5; k++) {
        float m = 0.5 * (hit + miss);
        if (dep.sample(s, c + cam * (m - d0)).r >= m) hit = m; else miss = m;
    }
    float2 q = c + cam * (hit - d0);
    d = dep.sample(s, q).r;
    if ((u.fx & 1024u) != 0u) q.x += 0.0012 * d * d * sin(ph * 2.0 + q.y * 30.0);   // wind: near leaves and grass sway
    float3 col = img.sample(s, q).rgb;
    float2 p = float2(in.uv.x * a, in.uv.y);

    if ((u.fx & 32u) != 0u) {          // fog, drifting on a circle through the noise
        float2 fp = float2(q.x * a, q.y) * 2.2;
        float n = fbm(fp + float2(cos(ph), sin(ph)) * 0.8) * 0.6 + fbm(fp * 1.9 + float2(sin(ph), cos(ph)) * 0.5 + 7.0) * 0.4;
        float amt = smoothstep(0.4, 0.8, n) * smoothstep(0.85, 0.25, d) * 0.32;
        float3 fogc = img.sample(s, q, level(7.0)).rgb * 1.25 + 0.1;
        col = mix(col, fogc, amt);
    }
    if ((u.fx & 16u) != 0u) {          // stars twinkling in dark, far-away sky
        float2 sp = float2(q.x * a, q.y) * 110.0;
        float2 id = floor(sp);
        float h = hash21(id + 5.0 + u.seed);
        if (h > 0.982 && d < 0.25 && dot(col, float3(0.3, 0.59, 0.11)) < 0.45) {
            float2 o = hash22(id) - 0.5;
            float m = smoothstep(0.14, 0.0, length(fract(sp) - 0.5 - o * 0.6));
            float tw = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(ph * (1.0 + fmod(floor(h * 997.0), 4.0)) + h * 40.0), 2.0);
            col += float3(1.0, 0.97, 0.9) * m * tw;
        }
    }
    if ((u.fx & 1u) != 0u) {           // rain
        col *= 0.97;
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float rep = 6.0 + fk * 3.0;
            float K = rep * (20.0 - fk * 4.0);
            float2 rp = float2((p.x + p.y * 0.12) * (80.0 + fk * 60.0) / a, p.y * rep + lt * K);
            float cid = floor(rp.x);
            float y = rp.y + floor(hash11(cid * 1.7 + fk * 13.0) * K);
            float fy = fract(y);
            float show = step(0.62, hash21(float2(cid, fmod(floor(y), K)) + fk * 7.0 + u.seed));
            float streak = (1.0 - fy / 0.3) * step(fy, 0.3);
            float w = smoothstep(0.14, 0.0, abs(fract(rp.x) - 0.5));
            col += float3(0.72, 0.8, 0.92) * streak * w * show * (0.17 - fk * 0.04) * occ(0.9 - fk * 0.25, d);
        }
    }
    for (int k = 0; k < 3; k++) {       // things that drift: snow, embers, leaves, petals, dust, bubbles
        float fk = float(k);
        float dens = 7.0 + fk * 5.0;
        if ((u.fx & 2u) != 0u) {
            float K = floor(dens * (1.3 - fk * 0.3));
            float2 sp = p * dens + float2(0.0, lt * K);
            float2 id = floor(sp); id.y = fmod(id.y, K);
            float h = hash21(id + fk * 31.0 + u.seed);
            if (h > 0.35) {
                float2 o = (hash22(id + fk * 7.0) - 0.5) * 0.5;
                o.x += 0.12 * sin(ph * (1.0 + floor(h * 3.0)) + h * 6.28);
                float r = 0.04 + 0.06 * hash11(h * 91.0);
                col = mix(col, float3(0.96, 0.97, 1.0), smoothstep(r, r * 0.2, length(fract(sp) - 0.5 - o)) * (0.75 - fk * 0.2) * occ(0.9 - fk * 0.25, d));
            }
        }
        if ((u.fx & 4u) != 0u) {
            float K = floor(dens * (1.6 - fk * 0.3));
            float2 sp = p * dens - float2(0.0, lt * K);
            float2 id = floor(sp); id.y = fmod(id.y, K);
            float h = hash21(id + fk * 17.0 + u.seed);
            if (h > 0.55) {
                float2 o = (hash22(id + 3.0) - 0.5) * 0.5;
                o.x += 0.15 * sin(ph * (1.0 + floor(h * 2.0)) + h * 9.0);
                float dist = length(fract(sp) - 0.5 - o);
                float fl = 0.55 + 0.45 * sin(ph * (3.0 + floor(h * 4.0)) + h * 20.0);
                col += float3(1.0, 0.45, 0.12) * (smoothstep(0.05, 0.0, dist) + exp(-dist * 18.0) * 0.2) * fl * smoothstep(1.0, 0.15, p.y) * (0.8 - fk * 0.2) * occ(0.9 - fk * 0.25, d);
            }
        }
        if ((u.fx & (64u | 128u)) != 0u && k < 2) {
            bool petals = (u.fx & 128u) != 0u;
            float dn = 4.0 + fk * 3.0;
            float K = floor(dn * (1.2 - fk * 0.2));
            float2 sp = p * dn + float2(0.0, lt * K);
            float2 id = floor(sp); id.y = fmod(id.y, K);
            float h = hash21(id + fk * 23.0 + u.seed);
            if (h > 0.55) {
                float2 o = (hash22(id + 9.0) - 0.5) * 0.4;
                o.x += 0.14 * sin(ph * (1.0 + floor(h * 2.0)) + h * 7.0);
                float2 f = rot(fract(sp) - 0.5 - o, ph * (1.0 + floor(h * 3.0)) + h * 6.28);
                float sz = petals ? 0.05 : 0.08;
                float m = smoothstep(1.0, 0.75, length(f / float2(sz, sz * 0.5)));
                float3 lc = petals ? mix(float3(1.0, 0.72, 0.84), float3(1.0, 0.9, 0.94), hash11(h * 13.0))
                                   : (h < 0.7 ? float3(0.86, 0.36, 0.1) : h < 0.85 ? float3(0.95, 0.62, 0.16) : float3(0.7, 0.2, 0.1));
                col = mix(col, lc, m * (0.85 - fk * 0.3) * occ(0.9 - fk * 0.25, d));
            }
        }
        if ((u.fx & 256u) != 0u) {
            float K = 2.0 + fk;
            float2 sp = p * (dens * 2.0) - float2(0.0, lt * K);
            float2 id = floor(sp); id.y = fmod(id.y, K);
            float h = hash21(id + fk * 41.0 + u.seed);
            if (h > 0.8) {
                float2 o = (hash22(id + 1.0) - 0.5) * 0.5 + 0.15 * float2(sin(ph + h * 9.0), cos(ph * 2.0 + h * 5.0));
                float tw = 0.5 + 0.5 * sin(ph * (2.0 + floor(h * 3.0)) + h * 30.0);
                col += float3(1.0, 0.92, 0.75) * smoothstep(0.06, 0.0, length(fract(sp) - 0.5 - o)) * tw * 0.35 * occ(0.9 - fk * 0.25, d);
            }
        }
        if ((u.fx & 512u) != 0u && k < 2) {
            float dn = 6.0 + fk * 4.0;
            float K = floor(dn * 1.5);
            float2 sp = p * dn - float2(0.0, lt * K);
            float2 id = floor(sp); id.y = fmod(id.y, K);
            float h = hash21(id + fk * 5.0 + u.seed);
            if (h > 0.6) {
                float2 o = (hash22(id + 4.0) - 0.5) * 0.4;
                o.x += 0.1 * sin(ph * (2.0 + floor(h * 2.0)) + h * 8.0);
                float r = 0.06 + 0.08 * hash11(h * 3.0);
                float dist = length(fract(sp) - 0.5 - o);
                float ring = smoothstep(r, r * 0.88, dist) - smoothstep(r * 0.82, r * 0.7, dist);
                float shine = smoothstep(r * 0.3, 0.0, length(fract(sp) - 0.5 - o - float2(-r * 0.4, r * 0.4)));
                col += float3(0.85, 0.95, 1.0) * (ring * 0.35 + shine * 0.45) * occ(0.9 - fk * 0.25, d);
            }
        }
    }
    if ((u.fx & 8u) != 0u) {           // fireflies
        for (int i = 0; i < 22; i++) {
            float fi = float(i);
            float h1 = hash11(fi * 3.1 + u.seed), h2 = hash11(fi * 7.7 + u.seed), h3 = hash11(fi * 1.9 + 4.0);
            float2 pos = float2(a * (0.08 + 0.84 * h1) + 0.05 * a * sin(ph * (1.0 + floor(h2 * 2.0)) + h3 * 6.28),
                                0.08 + 0.5 * h2 + 0.05 * sin(ph * (1.0 + floor(h3 * 3.0)) + h1 * 6.28));
            float dist = length(p - pos);
            float pulse = pow(0.5 + 0.5 * sin(ph * (2.0 + floor(h3 * 3.0)) + h2 * 40.0), 3.0);
            col += float3(0.85, 1.0, 0.45) * (smoothstep(0.004, 0.0, dist) + exp(-dist * 55.0) * 0.3) * pulse * occ(0.6, d);
        }
    }
    if ((u.fx & 2048u) != 0u) {        // lights: lamps, windows and glowing things flicker gently, each on its own beat
        // Only small bright spots that stand out from their surroundings (not a glowing sky), with a flicker whose
        // timing drifts smoothly across the picture.
        float lum = dot(col, float3(0.3, 0.59, 0.11)), around = dot(img.sample(s, q, level(5.0)).rgb, float3(0.3, 0.59, 0.11));
        float m = smoothstep(0.55, 0.85, lum) * smoothstep(0.08, 0.22, lum - around) * smoothstep(0.02, 0.25, col.r - col.b);
        float h = noise(q * float2(a, 1.0) * 14.0);
        float fl = 0.5 + 0.35 * sin(ph * 4.0 + h * 25.0) + 0.15 * sin(ph * 13.0 + h * 40.0);
        col *= 1.0 + m * 0.16 * (fl - 0.5);
    }
    float g = hash21(in.pos.xy + floor(u.time * 30.0) * 37.0) - 0.5;
    // Film grain for photo-like scenes, so they don't look airbrushed; otherwise just enough dither that smooth skies
    // don't turn into bands and blocks in the video.
    col += g * ((u.fx & 4096u) != 0u ? 0.018 : 0.006);
    return float4(col, 1.0);
}
"""#
