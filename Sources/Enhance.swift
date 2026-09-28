import AppKit
import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo

// MARK: - AI enhance: smoother (more frames) and sharper (more pixels) wallpaper videos, made on this Mac
//
// Uses Apple's on-device video models in VideoToolbox: frame-rate conversion (ML frame interpolation) and
// super resolution. The super-resolution model downloads once, the first time you use it.

@MainActor final class VideoEnhancer: ObservableObject {
    static let shared = VideoEnhancer()
    enum State: Equatable {
        case idle
        case downloadingModel(Double)
        case working(Double)
        case done(String)          // the new wallpaper's id
        case failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var source: String?   // id of the wallpaper being enhanced
    private var task: Task<Void, Never>?

    var busy: Bool { if case .working = state { return true }; if case .downloadingModel = state { return true }; return false }

    nonisolated static var canInterpolate: Bool { VTFrameRateConversionConfiguration.isSupported }
    nonisolated static var canUpscale: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    /// Scale factors Apple's model supports for this size (2× turns 1080p into 4K), capped so the result stays ≤ 8K wide.
    nonisolated static func scaleFactors(width: Int, height: Int) -> [Int] {
        guard canUpscale, width > 0 else { return [] }
        if let m = VTSuperResolutionScalerConfiguration.maximumDimensions, width > Int(m.width) || height > Int(m.height) { return [] }
        return VTSuperResolutionScalerConfiguration.supportedScaleFactors.filter { $0 > 1 && width * $0 <= 7680 }.sorted()
    }

    /// Frame rates worth offering: clearly above what the video already has.
    nonisolated static func frameRates(from fps: Double) -> [Int] {
        guard canInterpolate, fps > 0 else { return [] }
        return [60, 120].filter { Double($0) > fps * 1.2 && Double($0) <= fps * 5 }
    }

    func start(_ w: Wallpaper, scale: Int, fps: Int) {
        guard !busy, let input = WallpaperLibrary.shared.url(w) else { return }
        source = w.id
        state = .working(0)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-enhanced-\(UUID().uuidString).mov")
        task = Task {
            do {
                try await Self.enhance(input: input, output: out, scale: scale, fps: Double(fps)) { p in
                    Task { @MainActor in if case .working = self.state { self.state = .working(p) } else if case .downloadingModel = self.state, p >= 0 { self.state = .working(p) } }
                } modelProgress: { p in
                    Task { @MainActor in self.state = .downloadingModel(p) }
                }
                try Task.checkCancellation()
                var parts: [String] = []
                if scale > 1 { parts.append("\(scale)×") }
                if fps > 0 { parts.append("\(fps) fps") }
                let added = try await WallpaperLibrary.shared.add(out, name: "\(w.name) (\(parts.joined(separator: ", ")))", enhanced: true, move: true)
                state = .done(added.id)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: out); state = .idle
            } catch {
                try? FileManager.default.removeItem(at: out)
                state = .failed((error as? VoiceError)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }
    func reset() { if !busy { state = .idle; source = nil } }

    // MARK: The pipeline (off the main thread)

    nonisolated static func enhance(input: URL, output: URL, scale: Int, fps target: Double,
                                    progress: @escaping @Sendable (Double) -> Void,
                                    modelProgress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VoiceError("That file has no video in it.") }
        let (size, transform, srcFPS) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let w = Int(size.width), h = Int(size.height)

        // Frame interpolation, when a higher frame rate was asked for.
        var frc: VTFrameRateConversionConfiguration?
        if target > Double(srcFPS) * 1.2 {
            guard let c = VTFrameRateConversionConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                                             qualityPrioritization: .normal, revision: VTFrameRateConversionConfiguration.defaultRevision)
            else { throw VoiceError("This Mac can't make this video smoother.") }
            frc = c
        }
        // Super resolution, when a bigger size was asked for.
        var sr: VTSuperResolutionScalerConfiguration?
        if scale > 1 {
            guard let c = VTSuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: scale, inputType: .video,
                                                               usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                               revision: VTSuperResolutionScalerConfiguration.defaultRevision)
            else { throw VoiceError("This Mac can't upscale a video this size.") }
            if c.configurationModelStatus != .ready {
                modelProgress(0)
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                    c.downloadConfigurationModel { err in if let err { k.resume(throwing: err) } else { k.resume() } }
                    Task { while c.configurationModelStatus == .downloading { modelProgress(Double(c.configurationModelPercentageAvailable) / 100); try? await Task.sleep(for: .milliseconds(300)) } }
                }
                guard c.configurationModelStatus == .ready else { throw VoiceError("Apple's upscaling model didn't finish downloading.") }
                progress(0)
            }
            sr = c
        }
        guard frc != nil || sr != nil else { throw VoiceError("Nothing to do: pick a bigger size or a higher frame rate.") }

        // Decode.
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)

        // Encode (HEVC). Enhanced copies are silent; wallpapers play muted anyway.
        let outW = w * max(scale, 1), outH = h * max(scale, 1), outFPS = frc != nil ? target : Double(srcFPS)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let bitrate = min(Double(outW * outH) * outFPS * 0.1, 80_000_000)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: outFPS],
        ])
        vin.transform = transform
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
        writer.add(vin)

        guard reader.startReading() else { throw reader.error ?? VoiceError("Couldn't read the video.") }
        guard writer.startWriting() else { throw writer.error ?? VoiceError("Couldn't write the new video.") }
        writer.startSession(atSourceTime: .zero)

        let stage = try Stages(frc: frc, sr: sr)
        defer { stage.end() }
        let expected = max(duration * Double(srcFPS), 1)
        var decoded = 0.0
        var previous: (buffer: CVPixelBuffer, time: CMTime)?
        var nextOut = 0.0                                  // next output timestamp on the target frame grid

        func write(_ buf: CVPixelBuffer, _ t: CMTime) async throws {
            let finalBuf = try await stage.upscale(buf, t)
            while !vin.isReadyForMoreMediaData { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(finalBuf, withPresentationTime: t) else { throw writer.error ?? VoiceError("Couldn't write a frame.") }
        }

        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let img = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            if frc == nil {
                try await write(img, t)
            } else if let (pb, pt) = previous {
                // Every output time between the previous frame and this one: the previous frame itself, or an in-between.
                var times: [Double] = []
                while nextOut < t.seconds - 0.0005 { times.append(nextOut); nextOut += 1 / target }
                let span = t.seconds - pt.seconds
                let phases = times.map { span > 0 ? Float(($0 - pt.seconds) / span) : 0 }
                let made = try await stage.interpolate(from: pb, at: pt, to: img, at: t, phases: phases.filter { $0 > 0.01 },
                                                       times: zip(times, phases).filter { $0.1 > 0.01 }.map(\.0))
                var k = 0
                for (time, phase) in zip(times, phases) {
                    let ct = CMTime(seconds: time, preferredTimescale: 600)
                    if phase <= 0.01 { try await write(pb, ct) } else { try await write(made[k], ct); k += 1 }
                }
            } else {
                nextOut = t.seconds
            }
            if frc != nil { previous = (try stage.copy(img), t) }
            decoded += 1
            progress(min(decoded / expected, 0.99))
        }
        if let (pb, pt) = previous, nextOut <= pt.seconds + 0.0005 { try await write(pb, CMTime(seconds: nextOut, preferredTimescale: 600)) }
        if reader.status == .failed { throw reader.error ?? VoiceError("Couldn't read the whole video.") }
        vin.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VoiceError("Couldn't finish the new video.") }
        progress(1)
    }

    /// The two model sessions and the buffer pools that feed them.
    private final class Stages {
        let frc: VTFrameProcessor?, sr: VTFrameProcessor?
        let frcIn: CVPixelBufferPool?, frcOut: CVPixelBufferPool?, srIn: CVPixelBufferPool?, srOut: CVPixelBufferPool?
        var transfer: VTPixelTransferSession?
        var prevSrc: VTFrameProcessorFrame?, prevOut: VTFrameProcessorFrame?

        init(frc fc: VTFrameRateConversionConfiguration?, sr sc: VTSuperResolutionScalerConfiguration?) throws {
            func pool(_ attrs: [String: Any]?) -> CVPixelBufferPool? {
                guard let attrs else { return nil }
                var p: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
                return p
            }
            frcIn = pool(fc?.sourcePixelBufferAttributes); frcOut = pool(fc?.destinationPixelBufferAttributes)
            srIn = pool(sc?.sourcePixelBufferAttributes); srOut = pool(sc?.destinationPixelBufferAttributes)
            if let fc { let p = VTFrameProcessor(); try p.startSession(configuration: fc); frc = p } else { frc = nil }
            if let sc { let p = VTFrameProcessor(); try p.startSession(configuration: sc); sr = p } else { sr = nil }
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        }

        func end() { frc?.endSession(); sr?.endSession() }

        private func make(_ pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
            var b: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) == kCVReturnSuccess, let b else { throw VoiceError("Ran out of memory for video frames.") }
            return b
        }

        /// A copy in the format the frame interpolator wants (decoded frames are recycled by the reader).
        func copy(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
            let dst = try make(frcIn ?? srIn)
            guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { throw VoiceError("Couldn't convert a frame.") }
            return dst
        }

        func interpolate(from a: CVPixelBuffer, at ta: CMTime, to bRaw: CVPixelBuffer, at tb: CMTime, phases: [Float], times: [Double]) async throws -> [CVPixelBuffer] {
            guard let frc, !phases.isEmpty else { return [] }
            let b = try copy(bRaw)
            let outs = try phases.map { _ in try make(frcOut) }
            guard let src = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: ta),
                  let next = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: tb) else { throw VoiceError("Couldn't prepare frames.") }
            let dst = try zip(outs, times).map { buf, t -> VTFrameProcessorFrame in
                guard let f = VTFrameProcessorFrame(buffer: buf, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600)) else { throw VoiceError("Couldn't prepare frames.") }
                return f
            }
            guard let p = VTFrameRateConversionParameters(sourceFrame: src, nextFrame: next, opticalFlow: nil, interpolationPhase: phases,
                                                          submissionMode: .sequential, destinationFrames: dst) else { throw VoiceError("Couldn't prepare frames.") }
            try await Self.run(frc, p)
            return outs
        }

        /// Upscales one frame (keeping track of the previous ones, which keeps detail steady from frame to frame).
        func upscale(_ raw: CVPixelBuffer, _ t: CMTime) async throws -> CVPixelBuffer {
            guard let sr else { return raw }
            let inBuf = try make(srIn), outBuf = try make(srOut)
            guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: raw, to: inBuf) == noErr,
                  let src = VTFrameProcessorFrame(buffer: inBuf, presentationTimeStamp: t),
                  let dst = VTFrameProcessorFrame(buffer: outBuf, presentationTimeStamp: t),
                  let p = VTSuperResolutionScalerParameters(sourceFrame: src, previousFrame: prevSrc, previousOutputFrame: prevOut,
                                                            opticalFlow: nil, submissionMode: .sequential, destinationFrame: dst)
            else { throw VoiceError("Couldn't prepare a frame for upscaling.") }
            try await Self.run(sr, p)
            prevSrc = src; prevOut = dst
            return outBuf
        }

        static func run(_ proc: VTFrameProcessor, _ p: any VTFrameProcessorParameters) async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                proc.process(parameters: p) { _, err in if let err { k.resume(throwing: err) } else { k.resume() } }
            }
        }
    }
}

// MARK: - The "Enhance with AI" sheet

struct EnhanceSheet: View {
    let wallpaper: Wallpaper
    let close: () -> Void
    @ObservedObject var enhancer = VideoEnhancer.shared
    @State private var scale = 1
    @State private var fps = 0

    var body: some View {
        let scales = VideoEnhancer.scaleFactors(width: wallpaper.width, height: wallpaper.height)
        let rates = VideoEnhancer.frameRates(from: wallpaper.fps)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles").font(.system(size: 22)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enhance with AI").font(.system(size: 16, weight: .semibold))
                    Text("\(wallpaper.name) · \(wallpaper.width)×\(wallpaper.height) · \(Int(wallpaper.fps.rounded())) fps")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if scales.isEmpty && rates.isEmpty {
                Text("This video is already as sharp and smooth as Apple's models can make it on this Mac.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Resolution", selection: $scale) {
                    Text("Keep \(wallpaper.width)×\(wallpaper.height)").tag(1)
                    ForEach(scales, id: \.self) { s in Text("\(s)× (\(wallpaper.width * s)×\(wallpaper.height * s))").tag(s) }
                }
                .disabled(scales.isEmpty || enhancer.busy)
                Picker("Frame rate", selection: $fps) {
                    Text("Keep \(Int(wallpaper.fps.rounded())) fps").tag(0)
                    ForEach(rates, id: \.self) { r in Text("\(r) fps (smoother)").tag(r) }
                }
                .disabled(rates.isEmpty || enhancer.busy)
                Text("Runs on this Mac with Apple's video models: frame interpolation adds in-between frames, super resolution adds real detail. The upscaling model downloads once, the first time. Your original stays in your library, and enhanced copies play without sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            status
            HStack {
                Spacer()
                if enhancer.busy {
                    Button("Cancel") { enhancer.cancel() }
                } else {
                    Button("Close") { enhancer.reset(); close() }
                    if case .done(let id) = enhancer.state, let w = WallpaperLibrary.shared.item(id) {
                        Button("Use It") { WallpaperEngine.shared.set(w); enhancer.reset(); close() }.buttonStyle(.glassProminent)
                    } else {
                        Button("Enhance") { enhancer.start(wallpaper, scale: scale, fps: fps) }
                            .buttonStyle(.glassProminent).disabled(scale == 1 && fps == 0)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if !enhancer.busy { enhancer.reset() } }
    }

    @ViewBuilder private var status: some View {
        switch enhancer.state {
        case .downloadingModel(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Downloading Apple's upscaling model (one time)…").font(.caption).foregroundStyle(.secondary)
            }
        case .working(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Enhancing… \(Int(p * 100))%. You can close this; it keeps going.").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Done! The enhanced copy is in your library.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .idle:
            EmptyView()
        }
    }
}
