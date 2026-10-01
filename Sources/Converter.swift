import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Convert on the Shelf: right-click a file on the shelf and make what you need from it, on this Mac. The new
// file goes next to the original (or in Downloads if that folder can't be written to) and joins the shelf.

enum Conversion: String, CaseIterable, Identifiable {
    case jpeg, png, heic, smaller, pdf, mp4, smallerVideo, gif, audio, zip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC (smaller, same quality)"
        case .smaller: "Half the Size"
        case .pdf: "PDF"
        case .mp4: "MP4 (plays anywhere)"
        case .smallerVideo: "Smaller Video (720p)"
        case .gif: "GIF (first 8 seconds)"
        case .audio: "Audio Only (M4A)"
        case .zip: "ZIP (for email)"
        }
    }
    var icon: String {
        switch self {
        case .jpeg, .png, .heic: "photo"
        case .smaller: "arrow.down.right.and.arrow.up.left"
        case .pdf: "doc.richtext"
        case .mp4, .smallerVideo: "film"
        case .gif: "sparkles.tv"
        case .audio: "waveform"
        case .zip: "doc.zipper"
        }
    }
}

@MainActor final class ShelfConverter: ObservableObject {
    static let shared = ShelfConverter()
    @Published private(set) var working: String?   // what's being made, while it's being made

    enum Kind { case image, video, audio, pdf, other }

    nonisolated static func kind(_ url: URL) -> Kind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .pdf) { return .pdf }
        return .other
    }

    /// What this file can become (never the format it already is).
    nonisolated static func options(for url: URL) -> [Conversion] {
        let ext = url.pathExtension.lowercased()
        switch kind(url) {
        case .image:
            var o: [Conversion] = []
            if !["jpg", "jpeg"].contains(ext) { o.append(.jpeg) }
            if ext != "png" { o.append(.png) }
            if ext != "heic" { o.append(.heic) }
            return o + [.smaller, .pdf, .zip]
        case .video: return (ext == "mp4" ? [] : [.mp4]) + [.smallerVideo, .gif, .audio, .zip]
        case .audio: return (ext == "m4a" ? [] : [.audio]) + [.zip]
        case .pdf, .other: return [.zip]
        }
    }

    func convert(_ c: Conversion, _ urls: [URL]) {
        guard working == nil, let first = urls.first else { return }
        working = "\(c.title) from \(urls.count == 1 ? first.lastPathComponent : "\(urls.count) files")"
        NotchModel.shared.flash(.message(icon: "gearshape.2.fill", text: "Making \(c.title)…", tint: .blue), for: 2)
        Task {
            defer { working = nil }
            do {
                let out = try await Self.make(c, urls)
                ShelfStore.shared.add([out])
                NotchModel.shared.flash(.message(icon: "checkmark.circle.fill", text: "Made \(out.lastPathComponent)", tint: .green), for: 3)
            } catch {
                NotchModel.shared.flash(.message(icon: "exclamationmark.triangle.fill", text: (error as? ConvertError)?.message ?? "Couldn't convert that", tint: .orange), for: 4)
            }
        }
    }

    struct ConvertError: Error { let message: String }

    // MARK: The work (off the main thread)

    nonisolated static func make(_ c: Conversion, _ urls: [URL]) async throws -> URL {
        guard let first = urls.first else { throw ConvertError(message: "Nothing to convert") }
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Shelf"
        switch c {
        case .jpeg: return try image(first, to: .jpeg, out: destination(base, "jpg", near: first))
        case .png: return try image(first, to: .png, out: destination(base, "png", near: first))
        case .heic: return try image(first, to: .heic, out: destination(base, "heic", near: first))
        case .smaller:
            let ext = first.pathExtension.lowercased() == "png" ? "png" : "jpg"
            return try image(first, to: ext == "png" ? .png : .jpeg, out: destination(base + " (smaller)", ext, near: first), half: true)
        case .pdf: return try pdf(urls, out: destination(base, "pdf", near: first))
        case .mp4: return try await export(first, preset: AVAssetExportPresetHighestQuality, type: .mp4, out: destination(base, "mp4", near: first))
        case .smallerVideo: return try await export(first, preset: AVAssetExportPreset1280x720, type: .mp4, out: destination(base + " (smaller)", "mp4", near: first))
        case .audio: return try await export(first, preset: AVAssetExportPresetAppleM4A, type: .m4a, out: destination(base, "m4a", near: first))
        case .gif: return try await gif(first, out: destination(base, "gif", near: first))
        case .zip: return try zip(urls, out: destination(base, "zip", near: first))
        }
    }

    /// Next to the original if that folder can be written to, otherwise Downloads; never over an existing file.
    nonisolated static func destination(_ name: String, _ ext: String, near original: URL) -> URL {
        let fm = FileManager.default
        var dir = original.deletingLastPathComponent()
        if !fm.isWritableFile(atPath: dir.path) || dir.path.hasPrefix(Prefs.supportDir.path) {
            dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        }
        var u = dir.appendingPathComponent(name).appendingPathExtension(ext), n = 2
        while fm.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext); n += 1 }
        return u
    }

    nonisolated static func image(_ src: URL, to type: UTType, out: URL, half: Bool = false) throws -> URL {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw ConvertError(message: "Couldn't open that picture") }
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
        let img: CGImage?
        if half {
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 2000, h = props[kCGImagePropertyPixelHeight] as? Int ?? 2000
            img = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                             kCGImageSourceThumbnailMaxPixelSize: max(w, h) / 2] as CFDictionary)
        } else {
            img = CGImageSourceCreateImageAtIndex(s, 0, nil)
        }
        guard let img, let d = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError(message: "Couldn't make a \(type.preferredFilenameExtension?.uppercased() ?? "picture")")
        }
        var keep = props   // keeps the picture's details, and its orientation unless it was already turned upright
        if half { keep[kCGImagePropertyOrientation] = 1 }
        keep[kCGImageDestinationLossyCompressionQuality] = 0.85
        CGImageDestinationAddImage(d, img, keep as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ConvertError(message: "Couldn't save the picture") }
        return out
    }

    nonisolated static func pdf(_ urls: [URL], out: URL) throws -> URL {
        let doc = PDFDocument()
        for u in urls where kind(u) == .image {
            if let img = NSImage(contentsOf: u), let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw ConvertError(message: "Couldn't make the PDF") }
        return out
    }

    nonisolated static func export(_ src: URL, preset: String, type: AVFileType, out: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConvertError(message: "This Mac can't convert that video") }
        do { try await s.export(to: out, as: type) } catch { throw ConvertError(message: "Couldn't convert that: \(error.localizedDescription)") }
        return out
    }

    /// The first 8 seconds, 480 pixels wide, 12 frames a second, looping.
    nonisolated static func gif(_ src: URL, out: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let duration = min(try await asset.load(.duration).seconds, 8)
        guard duration > 0 else { throw ConvertError(message: "That video has no frames") }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let fps = 12.0, count = max(1, Int(duration * fps))
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw ConvertError(message: "Couldn't make the GIF") }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            if let img = try? await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image { CGImageDestinationAddImage(d, img, frame) }
        }
        guard CGImageDestinationFinalize(d) else { throw ConvertError(message: "Couldn't save the GIF") }
        return out
    }

    nonisolated static func zip(_ urls: [URL], out: URL) throws -> URL {
        let fm = FileManager.default
        var source = urls[0]
        if urls.count > 1 {   // several files: zip a folder of them
            let dir = fm.temporaryDirectory.appendingPathComponent("Shelf-\(UUID().uuidString)").appendingPathComponent("Shelf")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for u in urls { try? fm.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
            source = dir
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, out.path]
        try p.run(); p.waitUntilExit()
        if urls.count > 1 { try? fm.removeItem(at: source.deletingLastPathComponent()) }
        guard p.terminationStatus == 0 else { throw ConvertError(message: "Couldn't make the ZIP") }
        return out
    }
}

/// The Convert menu for a file on the shelf.
struct ConvertMenu: View {
    let url: URL
    var body: some View {
        let options = ShelfConverter.options(for: url)
        if !options.isEmpty {
            Menu("Convert To") {
                ForEach(options) { c in Button { ShelfConverter.shared.convert(c, [url]) } label: { Label(c.title, systemImage: c.icon) } }
            }
        }
    }
}
