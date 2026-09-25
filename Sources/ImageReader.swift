import Foundation
import CoreGraphics
import Vision

// MARK: - AI effort: how hard Onyx AI works on an answer

enum AIEffort: String, CaseIterable, Identifiable {
    case low, medium, high, max
    static let key = "ai.effort"
    static var current: AIEffort { AIEffort(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .medium }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .low: "gauge.with.dots.needle.0percent"
        case .medium: "gauge.with.dots.needle.33percent"
        case .high: "gauge.with.dots.needle.67percent"
        case .max: "gauge.with.dots.needle.100percent"
        }
    }
    var detail: String {
        switch self {
        case .low: "Fastest. Short answers, quick text reading."
        case .medium: "Balanced. Reads images carefully."
        case .high: "Thinks it through first, reads tables. Slower, smarter."
        case .max: "Thinks it through three ways and picks the best. Slowest, smartest."
        }
    }
    /// How much screen/image text goes to the model (it has a small context window).
    var contextChars: Int {
        switch self {
        case .low: 1500
        case .medium: 2500
        case .high, .max: 3500
        }
    }
}

// MARK: - Image understanding (the on-device model only reads text, so images become a detailed description)

struct ImageReport {
    var text = ""
    var mathy = false
    var repairs = 0
    var tables: [String] = []
    var codes: [String] = []
    var labels: [String] = []
    var faces = 0
    var people = 0
    var animals: [String] = []

    var isEmpty: Bool { text.isEmpty && tables.isEmpty && codes.isEmpty && labels.isEmpty && faces == 0 && people == 0 && animals.isEmpty }

    /// Everything the model needs to know about the image, within `limit` characters.
    func prompt(limit: Int) -> String {
        var head: [String] = []
        var seen: [String] = []
        if !labels.isEmpty { seen.append("looks like " + labels.joined(separator: ", ")) }
        if faces > 0 { seen.append("\(faces) face\(faces == 1 ? "" : "s")") } else if people > 0 { seen.append("\(people) \(people == 1 ? "person" : "people")") }
        if !animals.isEmpty { seen.append("animals: " + animals.joined(separator: ", ")) }
        if !seen.isEmpty { head.append("What image recognition sees: " + seen.joined(separator: "; ") + ".") }
        for c in codes { head.append(c) }
        for t in tables { head.append("Table found in the image:\n" + t) }
        var out = head.joined(separator: "\n")
        if !text.isEmpty {
            var note = "Text in the image (read by OCR, in reading order"
            if mathy {
                note += "; it's math. Symbols were checked by shape: ∠ means angle, ° means degrees. OCR can still misread ∠ as <, 4, 2 or z, ° as o or 0, and √ as V, so read it the way the math problem makes sense"
            }
            note += "):"
            let room = max(200, limit - out.count - note.count - 10)
            let body = text.count > room ? String(text.prefix(room)) + "…" : text
            out += (out.isEmpty ? "" : "\n") + note + "\n\"\"\"\n" + body + "\n\"\"\""
        }
        return String(out.prefix(limit + 200))
    }
}

enum ImageReader {
    static func analyze(_ img: CGImage, effort: AIEffort) async -> ImageReport {
        var report = await Task.detached(priority: .userInitiated) { () -> ImageReport in
            var r = ImageReport()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate   // .fast misreads symbols badly (∠ → £) and saves little time
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            let labels = VNClassifyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            let people = VNDetectHumanRectanglesRequest()
            let animals = VNRecognizeAnimalsRequest()
            var reqs: [VNRequest] = [text]
            if effort != .low { reqs += [codes, labels, faces, people, animals] }
            try? VNImageRequestHandler(cgImage: img).perform(reqs)

            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first }
            let raw = lines.map(\.string).joined(separator: "\n")
            r.mathy = looksMathy(raw)
            var fixed: [String] = []
            for c in lines {
                let (s, n) = repairSymbols(c, in: img, mathy: r.mathy)
                fixed.append(s); r.repairs += n
            }
            r.text = fixed.joined(separator: "\n")
            if r.mathy { r.text = repairByContext(r.text) }

            r.codes = (codes.results ?? []).compactMap { b in
                guard let p = b.payloadStringValue, !p.isEmpty else { return nil }
                let kind = b.symbology == .qr ? "QR code" : "Barcode"
                return "\(kind) in the image: \(p)"
            }
            r.labels = (labels.results ?? []).filter { $0.confidence > 0.35 }.prefix(5)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            r.faces = faces.results?.count ?? 0
            r.people = people.results?.count ?? 0
            r.animals = (animals.results ?? []).compactMap { $0.labels.first?.identifier.lowercased() }
            return r
        }.value

        // High / Max: also read the page's structure, so tables come through as rows and columns.
        if effort == .high || effort == .max, let docs = try? await RecognizeDocumentsRequest().perform(on: img) {
            for d in docs {
                for t in d.document.tables.prefix(3) {
                    let rows = t.rows.prefix(20).map { row in
                        "| " + row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
                    }
                    if rows.count > 1 { report.tables.append(rows.joined(separator: "\n")) }
                }
            }
        }
        return report
    }

    // MARK: Math symbol repair

    static func looksMathy(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        let cues = s.range(of: #"[=+×÷^√∠°≤≥]|\b(angle|triangle|degrees?|solve|prove|equation|slope|perimeter|area|parallel|perpendicular|congruent|supplementary|complementary|m\s?<)\b|<\s?[A-Z]{2,3}\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
        return cues && (digits > 0 || s.range(of: #"<\s?[A-Z]{2,3}\b"#, options: .regularExpression) != nil)
    }

    /// Checks the pixels of symbols OCR tends to misread and fixes them:
    /// < ‹ 4 2 z L → ∠ (by shape), < → ≤, > → ≥, = → ≅, o/0 → ° (small and raised).
    static func repairSymbols(_ c: VNRecognizedText, in img: CGImage, mathy: Bool) -> (String, Int) {
        let s = c.string
        guard mathy || s.contains("<") || s.contains(">") || s.contains("‹") else { return (s, 0) }
        var chars = Array(s)
        var idx = s.startIndex
        var fixes = 0
        var prevBox: CGRect?
        var prevChar: Character?
        for i in chars.indices {
            let next = s.index(after: idx)
            let ch = chars[i]
            let box = (try? c.boundingBox(for: idx..<next))?.boundingBox
            let after = String(s[next...])
            let before: Character? = i > 0 ? chars[i - 1] : nil
            // Something that names an angle follows: "ABC", "1", "2 "…
            let namesAngle = after.range(of: #"^\s?([A-Z]{1,3}\b|\d{1,2}\b)"#, options: .regularExpression) != nil
            let angleSpot = before == nil || before == "m" || before.map { " (,;:=".contains($0) } == true
            let lookalike = "4 2zZL".contains(ch) && mathy && namesAngle && angleSpot
            // Stuck to vertex letters ("<DEF", "mzBCA") it's an angle whatever the pixels say.
            let vertexNext = after.range(of: #"^[A-Z]{2,3}\b"#, options: .regularExpression) != nil
            // Right after "m" (measure of), with no space: "m<A", "m≤B", "mzC", "m<1" are all m∠.
            let measured = before == "m" && (i < 2 || !chars[i - 2].isLetter)
                && after.range(of: ch == "<" || ch == "‹" || ch == "z" ? #"^[A-Z0-9]"# : #"^[A-Z]"#, options: .regularExpression) != nil
                && "<‹≤zZ24L".contains(ch)
            if mathy, measured || (vertexNext && angleSpot && (ch == "<" || ch == "‹" || (lookalike && before == "m"))) {
                chars[i] = "∠"; fixes += 1
            } else if ch == "<" || ch == "‹" || ch == ">" || ch == "›" || lookalike {
                if let b = box, let g = glyph(img, b), let kind = classify(g) {
                    let isLess = ch == "<" || ch == "‹"
                    let replacement: Character? = switch kind {
                    case .angle where isLess || lookalike: "∠"
                    case .lessOrEqual where isLess: "≤"
                    case .lessOrEqual where ch == ">" || ch == "›": "≥"
                    default: ch == "‹" ? "<" : ch == "›" ? ">" : nil
                    }
                    if let r = replacement, r != ch { chars[i] = r; fixes += 1 }
                } else if ch == "‹" || ch == "›" {
                    chars[i] = ch == "‹" ? "<" : ">"
                }
            } else if ch == "=", mathy, let b = box, let g = glyph(img, b, loose: true), strokes(g) >= 3 {
                chars[i] = "≅"; fixes += 1        // two bars plus a tilde
            } else if mathy, "oO0º".contains(ch), let p = prevChar, p.isNumber, let b = box, let pb = prevBox {
                // A degree sign is small and raised compared to the digit before it.
                if ch == "º" || (b.height < pb.height * 0.7 && b.midY > pb.midY + pb.height * 0.15) { chars[i] = "°"; fixes += 1 }
            }
            prevBox = box; prevChar = chars[i]
            idx = next
        }
        return (String(chars), fixes)
    }

    /// When the pixels couldn't be checked: "<ABC" / "m<1" in math means an angle; "V16" is a square root.
    static func repairByContext(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"(^|[\s(,;:=])m\s?[<‹]\s?(?=[A-Z0-9])"#, with: "$1m∠", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|[\s(,;:=])m[≤zZ24L](?=[A-Z]\b)"#, with: "$1m∠", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|[\s(,;:=])[<‹]\s?(?=[A-Z]{2,3}\b)"#, with: "$1∠", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|[\s(,;:=])m[z2Z4L]\s?(?=[A-Z]{2,3}\b)"#, with: "$1m∠", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(^|[\s(=+\-×*/])V(?=\d|\()"#, with: "$1√", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s?º"#, with: "$1°", options: .regularExpression)
        // On a line that's about angles, "<1" is angle 1.
        t = t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            guard l.contains("∠") || l.range(of: "angle", options: .caseInsensitive) != nil else { return l }
            return l.replacingOccurrences(of: #"(^|[\s(,;:])[<‹](?=\d{1,2}\b)"#, with: "$1∠", options: .regularExpression)
                .replacingOccurrences(of: #"(^|[\s(,;:=])m[≤<‹zZ24L](?=\d{1,2}\b)"#, with: "$1m∠", options: .regularExpression)
        }.joined(separator: "\n")
        return t
    }

    enum Glyph { case angle, lessOrEqual, other }

    /// Crops one character (Vision box: normalized, origin bottom-left) out of the image.
    private static func glyph(_ img: CGImage, _ b: CGRect, loose: Bool = false) -> CGImage? {
        let W = CGFloat(img.width), H = CGFloat(img.height)
        var r = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
        guard r.width >= 3, r.height >= 5, loose || r.width < r.height * 2.5 else { return nil }   // must look like one character
        r = r.insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        return img.cropping(to: r)
    }

    /// A glyph as ink / no ink, whatever the text and background colors.
    private struct Bitmap {
        let w: Int, h: Int
        private var bits: [Bool]
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1   // row 0 = top
        init?(_ g: CGImage) {
            w = g.width; h = g.height
            guard w >= 3, h >= 5, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let data = ctx.data else { return nil }
            ctx.draw(g, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = data.bindMemory(to: UInt8.self, capacity: w * h)
            var border: [Int] = []
            for x in 0..<w { border.append(Int(px[x])); border.append(Int(px[(h - 1) * w + x])) }
            for y in 0..<h { border.append(Int(px[y * w])); border.append(Int(px[y * w + w - 1])) }
            border.sort()
            let bg = border[border.count / 2]
            var far = 0
            for i in 0..<(w * h) { far = max(far, abs(Int(px[i]) - bg)) }
            guard far > 40 else { return nil }
            bits = (0..<(w * h)).map { abs(Int(px[$0]) - bg) > far / 2 }
            for y in 0..<h { for x in 0..<w where bits[y * w + x] { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            guard maxX >= 0 else { return nil }
        }
        func ink(_ x: Int, _ y: Int) -> Bool { bits[y * w + x] }
        var iw: Int { maxX - minX + 1 }
        var ih: Int { maxY - minY + 1 }
    }

    /// Shape test. ∠: a flat bottom stroke, and its left edge only has ink near the bottom (the corner).
    /// ≤ / ≥: a flat bottom stroke with the point higher up. <, 4, 2, z…: anything else.
    static func classify(_ g: CGImage) -> Glyph? {
        guard let b = Bitmap(g), b.iw >= 3, b.ih >= 4 else { return nil }
        let band = max(1, b.ih / 5)
        var bottomCover = 0.0
        for y in (b.maxY - band + 1)...b.maxY {
            let n = (b.minX...b.maxX).filter { b.ink($0, y) }.count
            bottomCover = max(bottomCover, Double(n) / Double(b.iw))
        }
        guard bottomCover >= 0.6 else { return .other }
        // How high does the ink reach along the left edge?
        var top = b.maxY
        for x in b.minX..<min(b.maxX + 1, b.minX + max(1, b.iw / 8)) {
            if let y = (b.minY...b.maxY).first(where: { b.ink(x, $0) }) { top = min(top, y) }
        }
        let reach = Double(b.maxY - top + 1) / Double(b.ih)
        return reach > 0.38 ? .lessOrEqual : .angle
    }

    /// Separate horizontal strokes crossing the glyph's middle column (= has 2, ≅ has 3).
    static func strokes(_ g: CGImage) -> Int {
        guard let b = Bitmap(g) else { return 0 }
        var runs = 0, inRun = false
        let xs = [b.minX + b.iw / 3, b.minX + b.iw / 2, b.minX + 2 * b.iw / 3]
        var best = 0
        for x in xs {
            runs = 0; inRun = false
            for y in b.minY...b.maxY { let i = b.ink(x, y); if i && !inRun { runs += 1 }; inRun = i }
            best = max(best, runs)
        }
        return best
    }
}
