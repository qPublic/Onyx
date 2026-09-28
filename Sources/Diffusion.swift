import Foundation
import CoreML
import CoreGraphics

// MARK: - On-device Stable Diffusion for the Realistic, Anime and Painted styles
//
// Community Core ML conversions of three Stable Diffusion 1.5 models (CreativeML Open RAIL-M), each downloaded once
// (about 2 GB) the first time you pick its style. They're the Neural Engine versions: they paint at 512×512 using a
// fraction of the memory the GPU versions need (which matters on 8 GB Macs), then Apple's upscaler takes it to full size.
// The pipeline: CLIP tokenizer → text encoder → UNet stepped with DPM++ 2M (Karras sigmas) → VAE decoder.

enum DiffusionStyle: String, CaseIterable {
    case realistic, anime, painted

    var source: String {
        switch self {
        case .realistic: "coreml-community/coreml-realisticVision-v20/resolve/main/split_einsum/realisticVision-v20_split-einsum.zip"
        case .anime: "coreml-community/coreml-meinamix_meinaV10/resolve/main/split-einsum/meinamix_meinaV10_split-einsum.zip"
        case .painted: "coreml-community/coreml-dreamshaper-4-and-5/resolve/main/split_einsum/dreamshaper-5_split-einsum.zip"
        }
    }
    var folder: URL { DepthModel.dir.appendingPathComponent("SD-\(rawValue)", isDirectory: true) }
    var ready: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("Unet.mlmodelc").path) }

    /// The words that steer each model toward its look (the scene goes in the middle; CLIP reads 75 tokens).
    func prompt(_ scene: String) -> String {
        switch self {
        case .realistic: "RAW photo, \(scene), landscape photography, natural light, highly detailed, sharp focus, dslr, film grain"
        case .anime: "anime scenery, no humans, \(scene), beautiful detailed background art, soft lighting, vivid colors, masterpiece"
        case .painted: "digital painting, concept art, \(scene), painterly brushstrokes, dramatic lighting, highly detailed"
        }
    }
    var negative: String {
        let common = "people, person, character, text, watermark, signature, logo, frame, border, lowres, blurry, jpeg artifacts, deformed"
        switch self {
        case .realistic: return "cartoon, anime, painting, illustration, drawing, 3d render, cgi, oversaturated, " + common
        case .anime: return "photo, realistic, 3d, girl, boy, " + common
        case .painted: return "photo, 3d render, " + common
        }
    }

    /// Downloads and unpacks the model once. progress: 0…1.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !ready else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: DepthModel.dir, withIntermediateDirectories: true)
        let zip = DepthModel.dir.appendingPathComponent("SD-\(rawValue).zip")
        if !fm.fileExists(atPath: zip.path) {
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: "https://huggingface.co/" + source)!, delegate: DownloadProgress(progress))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("Couldn't download the \(rawValue) style. Check your internet connection.") }
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: tmp, to: zip)
        }
        progress(1)
        // Unpack, then keep just the folder that has the models in it.
        let tmpDir = DepthModel.dir.appendingPathComponent("SD-\(rawValue)-unpacking", isDirectory: true)
        try? fm.removeItem(at: tmpDir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmpDir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              let unet = fm.enumerator(at: tmpDir, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "Unet.mlmodelc" })
        else { try? fm.removeItem(at: tmpDir); try? fm.removeItem(at: zip); throw VoiceError("The \(rawValue) style didn't unpack. Try again.") }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: unet.deletingLastPathComponent(), to: folder)
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zip)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ s: URLSession, didCreateTask task: URLSessionTask) {
        Task { while task.state == .running { if task.countOfBytesExpectedToReceive > 0 { report(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)) }; try? await Task.sleep(for: .milliseconds(400)) } }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

final class Diffusion {
    let style: DiffusionStyle
    private let tokenizer: CLIPTokenizer

    init(_ style: DiffusionStyle) throws {
        self.style = style
        tokenizer = try CLIPTokenizer(vocab: style.folder.appendingPathComponent("vocab.json"), merges: style.folder.appendingPathComponent("merges.txt"))
    }

    private func load(_ name: String) throws -> MLModel {
        let c = MLModelConfiguration()
        c.computeUnits = .cpuAndNeuralEngine   // split-einsum conversions: the Neural Engine, light on memory
        return try MLModel(contentsOf: style.folder.appendingPathComponent("\(name).mlmodelc"), configuration: c)
    }

    /// Paints `count` pictures of the scene. progress(done, total) counts denoising steps across all of them.
    func paint(_ scene: String, count: Int, steps: Int = 20, guidance: Float = 7, seed: UInt64 = .random(in: 0...UInt64(UInt32.max)),
               isCancelled: () -> Bool = { false }, progress: @escaping (Int, Int) -> Void, each: (CGImage) -> Void) throws {
        // 1. Text → embeddings (the "unconditional" one is the negative prompt, for classifier-free guidance).
        var cond: [Float] = [], uncond: [Float] = []
        try autoreleasepool {
            let text = try load("TextEncoder")   // let go of each model as soon as it's done, to keep memory down
            cond = try encode(style.prompt(scene), text); uncond = try encode(style.negative, text)
        }
        let tokens = cond.count / 768

        // 2. Denoise, one picture at a time (the UNet takes both halves of the guidance as a batch of 2). It's its own
        // function so the UNet is let go of before the decoder loads.
        func denoise() throws -> (latents: [[Float]], h: Int, w: Int) {
        let unet = try load("Unet")
        guard let sampleDesc = unet.modelDescription.inputDescriptionsByName["sample"]?.multiArrayConstraint else { throw VoiceError("That style's model looks damaged.") }
        let shape = sampleDesc.shape.map(\.intValue)                 // [batch, 4, h, w]
        let batch = shape[0], h = shape[2], w = shape[3], n = 4 * h * w
        let hidden = uncond + cond                                      // [2, 77, 768] → the UNet wants [2, 768, 1, 77]
        var hs = [Float](repeating: 0, count: 2 * 768 * tokens)
        for b in 0..<2 { for t in 0..<tokens { for c in 0..<768 { hs[b * 768 * tokens + c * tokens + t] = hidden[b * tokens * 768 + t * 768 + c] } } }
        let sigmas = Self.karras(steps)
        var latents: [[Float]] = []
        var rng = SplitMix(seed)
        for i in 0..<count {
            var x = (0..<n).map { _ in rng.gaussian() * sigmas[0] }
            var old: [Float]?
            for s in 0..<steps {
                if isCancelled() { throw CancellationError() }
                let sigma = sigmas[s], next = sigmas[s + 1]
                let cin = 1 / (sigma * sigma + 1).squareRoot()
                let xin = x.map { $0 * cin }
                let t = Self.timestep(sigma)
                var un: [Float], co: [Float]
                if batch == 2 {
                    let out = try run(unet, sample: xin + xin, shape: shape, t: [t, t], hidden: hs, tokens: tokens)
                    un = Array(out[0..<n]); co = Array(out[n..<(2 * n)])
                } else {
                    let half = 768 * tokens
                    un = try run(unet, sample: xin, shape: shape, t: [t], hidden: Array(hs[0..<half]), tokens: tokens)
                    co = try run(unet, sample: xin, shape: shape, t: [t], hidden: Array(hs[half..<(2 * half)]), tokens: tokens)
                }
                var denoised = [Float](repeating: 0, count: n)
                for j in 0..<n { denoised[j] = x[j] - sigma * (un[j] + guidance * (co[j] - un[j])) }
                if next == 0 {
                    x = denoised
                } else {
                    // DPM-Solver++ (2M): first-order on the first step, second-order after.
                    let tNow = -log(sigma), tNext = -log(next), hStep = tNext - tNow
                    var d = denoised
                    if let old, s > 0 {
                        let r = (tNow + log(sigmas[s - 1])) / hStep
                        d = (0..<n).map { (1 + 1 / (2 * r)) * denoised[$0] - (1 / (2 * r)) * old[$0] }
                    }
                    let k = Float(expm1(-Double(hStep)))
                    x = (0..<n).map { (next / sigma) * x[$0] - k * d[$0] }
                }
                old = denoised
                progress(i * steps + s + 1, count * steps)
            }
            latents.append(x)
        }
        return (latents, h, w)
        }
        let (latents, h, w) = try denoise()

        // 3. Latents → pixels.
        let vae = try load("VAEDecoder")
        let zName = vae.modelDescription.inputDescriptionsByName.keys.first ?? "z"
        for l in latents {
            let z = try array(l.map { $0 / 0.18215 }, shape: [1, 4, h, w], like: vae.modelDescription.inputDescriptionsByName[zName])
            let out = try vae.prediction(from: MLDictionaryFeatureProvider(dictionary: [zName: z]))
            guard let name = vae.modelDescription.outputDescriptionsByName.keys.first, let img = out.featureValue(for: name)?.multiArrayValue,
                  let cg = Self.image(floats(img), width: w * 8, height: h * 8) else { throw VoiceError("That style's model didn't finish the picture.") }
            each(cg)
        }
    }

    private func encode(_ text: String, _ model: MLModel) throws -> [Float] {
        let ids = tokenizer.encode(text)
        guard let (name, desc) = model.modelDescription.inputDescriptionsByName.first else { throw VoiceError("That style's model looks damaged.") }
        let input = try array(ids.map(Float.init), shape: [1, ids.count], like: desc)
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: input]))
        let key = model.modelDescription.outputDescriptionsByName.keys.first { $0.contains("last_hidden") } ?? "last_hidden_state"
        guard let v = out.featureValue(for: key)?.multiArrayValue else { throw VoiceError("That style's model didn't answer.") }
        return floats(v)
    }

    private func run(_ unet: MLModel, sample: [Float], shape: [Int], t: [Float], hidden: [Float], tokens: Int) throws -> [Float] {
        let d = unet.modelDescription.inputDescriptionsByName
        var shp = shape; shp[0] = t.count
        var inputs: [String: Any] = [
            "sample": try array(sample, shape: shp, like: d["sample"]),
            "timestep": try array(t, shape: [t.count], like: d["timestep"]),
            "encoder_hidden_states": try array(hidden, shape: [t.count, 768, 1, tokens], like: d["encoder_hidden_states"]),
        ]
        // Models that also take ControlNet residuals get zeros (no ControlNet here).
        for (name, desc) in d where inputs[name] == nil {
            guard let c = desc.multiArrayConstraint else { continue }
            let count = c.shape.reduce(1) { $0 * $1.intValue }
            inputs[name] = try array([Float](repeating: 0, count: count), shape: c.shape.map(\.intValue), like: desc)
        }
        let out = try unet.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let name = unet.modelDescription.outputDescriptionsByName.keys.first, let v = out.featureValue(for: name)?.multiArrayValue else {
            throw VoiceError("That style's model didn't answer.")
        }
        return floats(v)
    }

    // MARK: Numbers in and out of Core ML

    private func array(_ v: [Float], shape: [Int], like desc: MLFeatureDescription?) throws -> MLMultiArray {
        let type = desc?.multiArrayConstraint?.dataType ?? .float32
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type == .float16 ? .float16 : .float32)
        if a.dataType == .float16 {
            a.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in for i in 0..<v.count { p[i] = Float16(v[i]) } }
        } else {
            a.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in for i in 0..<v.count { p[i] = v[i] } }
        }
        return a
    }

    /// Reads any multiarray as contiguous floats (Core ML may hand back padded strides).
    private func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue), count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        let contiguous = strides == (0..<shape.count).map { i in shape[(i + 1)...].reduce(1, *) }
        func read<T: MLShapedArrayScalar>(_ type: T.Type, _ conv: (T) -> Float) {
            a.withUnsafeBufferPointer(ofType: type) { p in
                if contiguous { for i in 0..<count { out[i] = conv(p[i]) }; return }
                var idx = [Int](repeating: 0, count: shape.count)
                for i in 0..<count {
                    var off = 0
                    for d in 0..<shape.count { off += idx[d] * strides[d] }
                    out[i] = conv(p[off])
                    var d = shape.count - 1
                    while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
                }
            }
        }
        if a.dataType == .float16 { read(Float16.self) { Float($0) } } else if a.dataType == .double { read(Double.self) { Float($0) } } else { read(Float.self) { $0 } }
        return out
    }

    private static func image(_ v: [Float], width: Int, height: Int) -> CGImage? {
        let plane = width * height
        guard v.count >= plane * 3 else { return nil }
        var px = [UInt8](repeating: 255, count: plane * 4)
        for i in 0..<plane {
            for c in 0..<3 { px[i * 4 + c] = UInt8(max(0, min(255, (v[c * plane + i] / 2 + 0.5) * 255))) }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Noise schedule (Stable Diffusion 1.5's scaled-linear betas, Karras spacing)

    private static let trainSigmas: [Double] = {
        var ac = 1.0, out: [Double] = []
        let a = 0.00085.squareRoot(), b = 0.012.squareRoot()
        for i in 0..<1000 {
            let beta = pow(a + (b - a) * Double(i) / 999, 2)
            ac *= 1 - beta
            out.append(((1 - ac) / ac).squareRoot())
        }
        return out
    }()

    static func karras(_ n: Int, rho: Double = 7) -> [Float] {
        let lo = pow(trainSigmas.first!, 1 / rho), hi = pow(trainSigmas.last!, 1 / rho)
        return (0..<n).map { Float(pow(hi + Double($0) / Double(n - 1) * (lo - hi), rho)) } + [0]
    }

    /// The training timestep whose noise level is sigma (interpolated in log space).
    static func timestep(_ sigma: Float) -> Float {
        let ls = log(Double(sigma)), logs = trainSigmas.map { log($0) }
        guard ls > logs[0] else { return 0 }
        guard ls < logs[999] else { return 999 }
        var i = 0
        while i < 998 && logs[i + 1] < ls { i += 1 }
        return Float(Double(i) + (ls - logs[i]) / (logs[i + 1] - logs[i]))
    }
}

/// Reproducible noise.
struct SplitMix {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func gaussian() -> Float {
        let u = max(uniform(), 1e-7), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// OpenAI CLIP's byte-pair tokenizer, as Stable Diffusion 1.5 uses it: 77 tokens, start and end markers, padded with the end marker.
struct CLIPTokenizer {
    private let vocab: [String: Int]
    private let ranks: [String: Int]
    private static let bytes: [Character] = {
        var bs = Array(33...126) + Array(161...172) + Array(174...255), cs = bs, n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var map = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) { map[b] = Character(UnicodeScalar(c)!) }
        return map
    }()
    private static let pattern = try! NSRegularExpression(pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#)

    init(vocab: URL, merges: URL) throws {
        self.vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocab))
        var r: [String: Int] = [:]
        for (i, line) in try String(contentsOf: merges, encoding: .utf8).split(separator: "\n").dropFirst().enumerated() { r[String(line)] = i }
        ranks = r
    }

    func encode(_ text: String, length: Int = 77) -> [Int] {
        let bos = vocab["<|startoftext|>"] ?? 49406, eos = vocab["<|endoftext|>"] ?? 49407
        let clean = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var ids: [Int] = []
        for m in Self.pattern.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
            guard let r = Range(m.range, in: clean) else { continue }
            let word = String(clean[r].utf8.map { Self.bytes[Int($0)] })
            ids += bpe(word).compactMap { vocab[$0] }
        }
        ids = [bos] + ids.prefix(length - 2) + [eos]
        return ids + [Int](repeating: eos, count: length - ids.count)
    }

    private func bpe(_ word: String) -> [String] {
        var parts = word.map(String.init)
        guard !parts.isEmpty else { return [] }
        parts[parts.count - 1] += "</w>"
        while parts.count > 1 {
            var best: (rank: Int, at: Int)?
            for i in 0..<(parts.count - 1) {
                if let r = ranks[parts[i] + " " + parts[i + 1]], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let b = best else { break }
            let a = parts[b.at], c = parts[b.at + 1]
            var merged: [String] = [], i = 0
            while i < parts.count {
                if i < parts.count - 1, parts[i] == a, parts[i + 1] == c { merged.append(a + c); i += 2 } else { merged.append(parts[i]); i += 1 }
            }
            parts = merged
        }
        return parts
    }
}
