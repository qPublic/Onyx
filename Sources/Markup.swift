import AppKit
import SwiftUI
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Screenshot tools: mark up a screenshot (pen, highlighter, arrows, boxes, blur) and copy the text out of any picture

enum TextGrabber {
    /// All the text Vision can read in a picture, top to bottom.
    static func text(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([req])
            return (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    /// Copy text from screen shortcut: drag over anything on screen, and its text is on your clipboard.
    @MainActor static func fromScreen() {
        guard !PrivateGuard.blocks() else { return }
        NotchController.current?.collapse()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-ocr-\(UUID().uuidString).png")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path]   // you pick the area; Esc cancels
            try? p.run(); p.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: file) }
            guard let img = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let text = await text(in: img)
            await MainActor.run { copy(text) }
        }
    }

    @MainActor static func copy(_ text: String) {
        guard !text.isEmpty else {
            NotchModel.shared.flash(.message(icon: "text.viewfinder", text: "No text found there", tint: .orange), for: 2)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.split(separator: "\n").count
        NotchModel.shared.flash(.message(icon: "text.viewfinder", text: "Copied \(lines) line\(lines == 1 ? "" : "s") of text", tint: .green), for: 2)
    }
}

struct Mark: Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, highlight, arrow, box, blur
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlight: "highlighter"
            case .arrow: "arrow.up.right"
            case .box: "rectangle"
            case .blur: "mosaic"
            }
        }
        var title: String { self == .blur ? "Blur" : rawValue.capitalized }
    }
    let id = UUID()
    var tool: Tool
    var points: [CGPoint]   // in the picture's pixels
    var color: Color
}

/// Draws the picture and its marks at the picture's own size; the editor scales it down, and Save renders it 1:1.
struct MarkupCanvas: View {
    let image: CGImage
    let pixelated: CGImage
    let marks: [Mark]
    let lineWidth: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let full = CGRect(origin: .zero, size: size)
            ctx.draw(Image(decorative: image, scale: 1), in: full)
            for m in marks {
                guard let first = m.points.first, let last = m.points.last else { continue }
                let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
                switch m.tool {
                case .blur:
                    ctx.drawLayer { l in
                        l.clip(to: Path(rect))
                        l.draw(Image(decorative: pixelated, scale: 1), in: full)
                    }
                case .box:
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: lineWidth), with: .color(m.color), lineWidth: lineWidth)
                case .arrow:
                    var p = Path(); p.move(to: first); p.addLine(to: last)
                    let angle = atan2(last.y - first.y, last.x - first.x), head = lineWidth * 4.5
                    for side in [-1.0, 1.0] {
                        p.move(to: last)
                        p.addLine(to: CGPoint(x: last.x - head * cos(angle + side * .pi / 7), y: last.y - head * sin(angle + side * .pi / 7)))
                    }
                    ctx.stroke(p, with: .color(m.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                case .pen, .highlight:
                    var p = Path(); p.addLines(m.points)
                    ctx.stroke(p, with: .color(m.tool == .highlight ? m.color.opacity(0.38) : m.color),
                               style: StrokeStyle(lineWidth: m.tool == .highlight ? lineWidth * 5 : lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: CGFloat(image.width), height: CGFloat(image.height))
    }
}

struct MarkupView: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    @State private var pixelated: CGImage
    @State private var marks: [Mark] = []
    @State private var tool: Mark.Tool = .arrow
    @State private var color: Color = .red
    @State private var drawing: Mark?
    @State private var status: String?

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        _pixelated = State(initialValue: Self.pixelate(image) ?? image)
    }

    private var lineWidth: CGFloat { max(3, CGFloat(max(image.width, image.height)) / 380) }
    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .white, .black]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $tool) {
                    ForEach(Mark.Tool.allCases) { t in Label(t.title, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                HStack(spacing: 4) {
                    ForEach(colors, id: \.self) { c in
                        Circle().fill(c).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.white, lineWidth: color == c ? 2 : 0))
                            .overlay(Circle().strokeBorder(.gray.opacity(0.4), lineWidth: 0.5))
                            .onTapGesture { color = c }
                    }
                }
                .opacity(tool == .blur ? 0.3 : 1)
                Button { _ = marks.popLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(marks.isEmpty).help("Undo")
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button { Task { TextGrabber.copy(await TextGrabber.text(in: image)) } } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                Button { copyImage() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { saveImage() } label: { Label("Save", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(10)
            GeometryReader { geo in
                let scale = min(geo.size.width / CGFloat(image.width), geo.size.height / CGFloat(image.height), 1)
                MarkupCanvas(image: image, pixelated: pixelated, marks: marks + (drawing.map { [$0] } ?? []), lineWidth: lineWidth)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
                        if drawing == nil { drawing = Mark(tool: tool, points: [CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)], color: color) }
                        if tool == .pen || tool == .highlight { drawing?.points.append(p) } else { drawing?.points = [drawing!.points[0], p] }
                    }.onEnded { _ in
                        if let d = drawing, d.points.count > 1 { marks.append(d) }
                        drawing = nil
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding([.horizontal, .bottom], 10)
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private func render() -> CGImage? {
        let r = ImageRenderer(content: MarkupCanvas(image: image, pixelated: pixelated, marks: marks, lineWidth: lineWidth))
        r.scale = 1
        return r.cgImage
    }

    private func copyImage() {
        guard let cg = render() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        status = "Copied"
    }

    /// Saves over the screenshot (it's already on the Shelf, so the Shelf shows the marked-up version).
    private func saveImage() {
        guard let cg = render(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        if CGImageDestinationFinalize(dest) { NotchModel.shared.flash(.message(icon: "checkmark.circle.fill", text: "Saved \(url.lastPathComponent)", tint: .green), for: 2); close() }
    }

    static func pixelate(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img)
        let f = CIFilter.pixellate()
        f.inputImage = ci.clampedToExtent()
        f.scale = Float(max(12, max(img.width, img.height) / 90))
        f.center = .zero
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }
}

@MainActor enum Markup {
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        NotchController.current?.collapse()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Mark Up · \(url.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: MarkupView(url: url, image: img) { [weak w] in w?.close() })
        w.setContentSize(NSSize(width: 980, height: 680))
        w.center()
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            MainActor.assumeIsolated { windows.removeAll { $0 === n.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The newest screenshot in Pictures › Onyx Captures.
    static var lastScreenshot: URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: QuickCapture.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "png" }
            .max { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }
}
