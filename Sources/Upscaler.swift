import AppKit
import CoreML

// MARK: - Real-ESRGAN: an AI upscaler that paints in real detail, so a 512-pixel painting looks sharp at 4K instead of
// stretched. By Xintao Wang et al. (BSD-3-Clause, github.com/xinntao/Real-ESRGAN), converted to Core ML for Onyx. Runs on
// this Mac; the model downloads once (33 MB, or 9 MB for the anime one) the first time it's needed.

enum Upscaler {
    enum Kind: String { case general = "RealESRGAN-x4plus", anime = "RealESRGAN-x4plus-anime" }

    static let base = "https://raw.githubusercontent.com/qPublic/Onyx/release-assets/models/"
    static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    static let tile = 256, margin = 16   // input pixels; tiles overlap by 2 × margin

    static func compiled(_ k: Kind) -> URL {
        Prefs.supportDir.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(k.rawValue + ".mlmodelc")
    }
    static func ready(_ k: Kind) -> Bool { FileManager.default.fileExists(atPath: compiled(k).path) }

    static func load(_ k: Kind, progress: @escaping @Sendable (Double) -> Void) async throws -> MLModel {
        if !ready(k) {
            let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-\(k.rawValue)-\(UUID().uuidString).mlpackage")
            defer { try? FileManager.default.removeItem(at: pkg) }
            for (i, f) in files.enumerated() {
                let dest = pkg.appendingPathComponent(f)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (tmp, resp) = try await URLSession.shared.download(from: URL(string: base + k.rawValue + ".mlpackage/" + f)!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Couldn't download the upscaler. Check your internet connection.") }
                try FileManager.default.moveItem(at: tmp, to: dest)
                progress(Double(i + 1) / Double(files.count))
            }
            let c = try await MLModel.compileModel(at: pkg)
            try FileManager.default.createDirectory(at: compiled(k).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled(k))
            try FileManager.default.moveItem(at: c, to: compiled(k))
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        return try MLModel(contentsOf: compiled(k), configuration: cfg)
    }

    /// At least `width` pixels wide with real detail: one 4× pass (two for very small pictures), then an exact resize.
    static func upscale(_ img: CGImage, toWidth width: Int, kind: Kind = .general,
                        progress: @escaping @Sendable (String, Double) -> Void) async throws -> CGImage {
        let model = try await load(kind) { p in progress("Downloading the AI upscaler (once)…", p) }
        var cur = img
        repeat {
            try Task.checkCancellation()
            cur = try upscale4x(cur, model: model) { p in progress("Adding detail…", p) }
        } while cur.width * 2 < width
        let height = Int((Double(width) * Double(cur.height) / Double(cur.width)).rounded())
        return cur.width == width ? cur : resize(cur, width, height) ?? cur
    }

    /// Four times bigger, tile by tile. Each tile's outer edge (where the model sees least) is dropped and the seams fade
    /// into each other, so no grid shows.
    static func upscale4x(_ img: CGImage, model: MLModel, progress: (Double) -> Void) throws -> CGImage {
        let w = img.width, h = img.height, pw = max(w, tile), ph = max(h, tile)
        // Pictures smaller than a tile get their last row and column repeated out to the tile's size.
        guard let px = rgba(img, pw, ph), let src = image(px, pw, ph) else { throw VoiceError("Couldn't read the picture.") }
        let W = pw * 4, H = ph * 4
        var out = [UInt8](repeating: 0, count: W * H * 4)
        let step = tile - 2 * margin
        func starts(_ n: Int) -> [Int] { n <= tile ? [0] : Array(Set(Array(stride(from: 0, to: n - tile, by: step)) + [n - tile])).sorted() }
        let xs = starts(pw), ys = starts(ph)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw VoiceError("The upscaler didn't load right.") }
        // Neighbouring tiles overlap by 8 × margin output pixels. Switch from the old tile to the new one over `ramp` pixels
        // in the middle of that overlap, so each side's pixels come from well inside its own tile.
        let ramp = 32, keep = 4 * margin - ramp / 2
        var done = 0
        for (yi, ty) in ys.enumerated() {
            for (xi, tx) in xs.enumerated() {
                guard let piece = src.cropping(to: CGRect(x: tx, y: ty, width: tile, height: tile)) else { continue }
                let input = try MLFeatureValue(cgImage: piece, constraint: constraint, options: nil)
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
                guard let pb = result.featureValue(for: "upscaled")?.imageBufferValue else { throw VoiceError("The upscaler didn't answer.") }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
                let bpr = CVPixelBufferGetBytesPerRow(pb), T = tile * 4
                let bgra = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
                let left = xi > 0, top = yi > 0
                for y in 0..<T {
                    let oy = ty * 4 + y
                    let b: Float = top ? min(max(Float(y - keep) / Float(ramp), 0), 1) : 1
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<T {
                        let a: Float = left ? min(max(Float(x - keep) / Float(ramp), 0), 1) : 1
                        let k = a * b
                        if k <= 0 { continue }
                        let o = (oy * W + tx * 4 + x) * 4, p = x * 4
                        let (r, g, bl) = bgra ? (row[p + 2], row[p + 1], row[p]) : (row[p + 1], row[p + 2], row[p + 3])   // else ARGB
                        if k >= 1 { out[o] = r; out[o + 1] = g; out[o + 2] = bl }
                        else {
                            out[o] = UInt8(Float(out[o]) * (1 - k) + Float(r) * k)
                            out[o + 1] = UInt8(Float(out[o + 1]) * (1 - k) + Float(g) * k)
                            out[o + 2] = UInt8(Float(out[o + 2]) * (1 - k) + Float(bl) * k)
                        }
                        out[o + 3] = 255
                    }
                }
                done += 1
                progress(Double(done) / Double(xs.count * ys.count))
            }
        }
        guard let full = image(out, W, H), let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: w * 4, height: h * 4)) else {
            throw VoiceError("Couldn't finish the picture.")
        }
        return cropped
    }

    /// The picture as RGBA bytes on a `pw` × `ph` canvas (top-left aligned), edges repeated into any extra space.
    static func rgba(_ img: CGImage, _ pw: Int, _ ph: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: pw * ph * 4)
        let ok = px.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: ph - img.height, width: img.width, height: img.height))   // CG's origin is bottom-left
            return true
        }
        guard ok else { return nil }
        let w = img.width, h = img.height
        for y in 0..<ph { for x in 0..<pw where x >= w || y >= h {
            let s = (min(y, h - 1) * pw + min(x, w - 1)) * 4, d = (y * pw + x) * 4
            px[d] = px[s]; px[d + 1] = px[s + 1]; px[d + 2] = px[s + 2]; px[d + 3] = 255
        } }
        return px
    }

    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func resize(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension Diffusion {
    /// Repaints a picture lightly in overlapping 512 px tiles (one model load for all of them), then fades the tiles into
    /// each other. `strength`: how much each tile may change; low keeps the picture and adds detail.
    func refine(_ img: CGImage, scene: String, people: Bool, look: String?, strength: Double = 0.3,
                isCancelled: () -> Bool = { false }, progress: @escaping (Int, Int) -> Void) throws -> CGImage {
        let size = 512, over = 128, W = img.width, H = img.height
        guard W >= size, H >= size else { return img }
        func starts(_ n: Int) -> [Int] { Array(Set(Array(stride(from: 0, to: n - size, by: size - over)) + [n - size])).sorted() }
        var tiles: [CGImage] = [], spots: [(x: Int, y: Int)] = []
        for y in starts(H) { for x in starts(W) {
            if let t = img.cropping(to: CGRect(x: x, y: y, width: size, height: size)) { tiles.append(t); spots.append((x, y)) }
        } }
        var done: [CGImage] = []
        try paint(scene, people: people, look: look, count: tiles.count, tiles: tiles, strength: strength, isCancelled: isCancelled, progress: progress) { done.append($0) }
        guard done.count == tiles.count else { return img }
        // Each tile counts most in its middle and fades out toward any edge that another tile overlaps.
        var acc = [Float](repeating: 0, count: W * H * 3), weight = [Float](repeating: 0, count: W * H)
        func ramp(_ i: Int, _ before: Bool, _ after: Bool) -> Float {
            min(1, before ? Float(i + 1) / Float(over) : 1, after ? Float(size - i) / Float(over) : 1)
        }
        for (t, spot) in zip(done, spots) {
            guard let px = Upscaler.rgba(t, size, size) else { continue }
            for y in 0..<size {
                let wy = ramp(y, spot.y > 0, spot.y + size < H)
                for x in 0..<size {
                    let w = wy * ramp(x, spot.x > 0, spot.x + size < W), o = (spot.y + y) * W + spot.x + x, p = (y * size + x) * 4
                    acc[o * 3] += Float(px[p]) * w; acc[o * 3 + 1] += Float(px[p + 1]) * w; acc[o * 3 + 2] += Float(px[p + 2]) * w
                    weight[o] += w
                }
            }
        }
        var out = [UInt8](repeating: 255, count: W * H * 4)
        for i in 0..<(W * H) {
            let w = max(weight[i], 1e-6)
            out[i * 4] = UInt8(min(255, acc[i * 3] / w)); out[i * 4 + 1] = UInt8(min(255, acc[i * 3 + 1] / w)); out[i * 4 + 2] = UInt8(min(255, acc[i * 3 + 2] / w))
        }
        return Upscaler.image(out, W, H) ?? img
    }
}
