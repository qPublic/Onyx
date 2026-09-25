import AppKit
import SwiftUI

// MARK: - Download progress (live activity + finished files onto the Shelf)

struct DownloadItem: Identifiable, Equatable {
    let id: String          // final file name
    var fraction: Double?   // nil when the browser doesn't report a total
    var bytes: Int64
}

/// Watches ~/Downloads two ways: browsers publish NSProgress for their downloads (what Finder's
/// progress bars use), and as a fallback we look for partial files (.crdownload, .download, .part).
final class DownloadMonitor: ObservableObject {
    static let shared = DownloadMonitor()
    @Published private(set) var items: [DownloadItem] = []

    private static let partialExts: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    private let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var subscriber: Any?
    private var tracked: [String: Progress] = [:]
    private var partials: [String: URL] = [:]
    private var finished: [String: Date] = [:]
    private var timer: Timer?
    private var lastScan = Date.distantPast

    var enabled: Bool { Prefs.bool(Prefs.downloadActivity) }

    /// Overall progress across active downloads (nil if any is indeterminate).
    var overall: Double? {
        let f = items.compactMap(\.fraction)
        guard !items.isEmpty, f.count == items.count else { return nil }
        return f.reduce(0, +) / Double(f.count)
    }

    func start() {
        subscriber = Progress.addSubscriber(forFileURL: dir) { [weak self] p in
            let id = Self.finalName(p.fileURL ?? (p.userInfo[.fileURLKey] as? URL))
            DispatchQueue.main.async { if let id { self?.tracked[id] = p } }
            return {
                let done = p.isFinished || p.fractionCompleted >= 0.999
                DispatchQueue.main.async {
                    guard let self, let id else { return }
                    self.tracked[id] = nil
                    if done && !p.isCancelled { self.finish(id) }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }.tolerant()
    }

    private static func finalName(_ u: URL?) -> String? {
        guard let u else { return nil }
        return partialExts.contains(u.pathExtension.lowercased()) ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent
    }

    private func tick() {
        guard enabled else { if !items.isEmpty { items = [] }; return }
        // Look at the folder every 3s when nothing is downloading, every second while something is.
        if items.isEmpty && tracked.isEmpty && partials.isEmpty && Date().timeIntervalSince(lastScan) < 3 { return }
        lastScan = Date()
        // Fallback: partial files the browser didn't publish progress for.
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var now: [String: URL] = [:]
        for u in urls where Self.partialExts.contains(u.pathExtension.lowercased()) { now[u.deletingPathExtension().lastPathComponent] = u }
        for id in partials.keys where now[id] == nil && tracked[id] == nil { finish(id) }   // partial gone → renamed to final (or cancelled)
        partials = now

        var list: [DownloadItem] = tracked.map { id, p in
            DownloadItem(id: id, fraction: p.totalUnitCount > 0 ? min(1, max(0, p.fractionCompleted)) : nil, bytes: p.completedUnitCount)
        }
        for (id, u) in now where tracked[id] == nil { list.append(DownloadItem(id: id, fraction: nil, bytes: Self.size(u))) }
        list.sort { $0.id < $1.id }
        if list != items { withAnimation(.snappy) { items = list } }
    }

    private func finish(_ id: String) {
        if let t = finished[id], Date().timeIntervalSince(t) < 10 { return }   // both paths can report the same file
        // Give the browser a moment to rename the partial file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let u = dir.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: u.path), !(finished[id].map { Date().timeIntervalSince($0) < 10 } ?? false) else { return }
            finished[id] = Date()
            if Prefs.bool(Prefs.downloadToShelf) { ShelfStore.shared.add([u]) }
            if enabled { NotchModel.shared.flash(.message(icon: "arrow.down.circle.fill", text: id, tint: .green), for: 3) }
            tick()
        }
    }

    private static func size(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        if !isDir.boolValue { return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }
        // Safari's .download is a bundle holding the partial file.
        let files = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Calculator (math, percentages, unit conversion)

enum Calc {
    struct Result { let display: String; let copy: String }

    static func evaluate(_ input: String) -> Result? {
        var s = input.lowercased().trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("=") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty else { return nil }
        if let r = convert(s) { return r }
        guard let v = Parser(s)?.parse(), v.isFinite else { return nil }
        return Result(display: format(v, grouped: true, digits: 6), copy: format(v, grouped: false))
    }

    static func format(_ v: Double, grouped: Bool, digits: Int = 10) -> String {
        if v != 0 && (abs(v) >= 1e15 || abs(v) < 1e-6) { return String(format: "%.6g", v) }
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.usesGroupingSeparator = grouped
        f.maximumFractionDigits = digits; f.maximumSignificantDigits = digits + 2; f.usesSignificantDigits = abs(v) < 1
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    // MARK: Units

    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604800))
    private static let year = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600))

    static let units: [String: Dimension] = {
        var u: [String: Dimension] = [:]
        func add(_ d: Dimension, _ names: String...) { for n in names { u[n] = d } }
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters")
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers")
        add(UnitLength.inches, "in", "inch", "inches", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitMass.milligrams, "mg", "milligram", "milligrams")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.kilograms, "kg", "kilogram", "kilograms", "kilo", "kilos")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.stones, "st", "stone", "stones")
        add(UnitMass.shortTons, "ton", "tons")
        add(UnitMass.metricTons, "tonne", "tonnes")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.pints, "pt", "pint", "pints")
        add(UnitVolume.cups, "cup", "cups")
        add(UnitVolume.fluidOunces, "fl oz", "floz")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon", "tablespoons")
        add(UnitVolume.teaspoons, "tsp", "teaspoon", "teaspoons")
        add(UnitTemperature.celsius, "c", "°c", "celsius")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")
        add(UnitDuration.milliseconds, "ms", "millisecond", "milliseconds")
        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        add(day, "d", "day", "days")
        add(week, "wk", "week", "weeks")
        add(year, "yr", "year", "years")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.kilometersPerHour, "kph", "km/h", "kmh")
        add(UnitSpeed.metersPerSecond, "m/s")
        add(UnitSpeed.knots, "knot", "knots", "kn")
        add(UnitInformationStorage.bytes, "byte", "bytes")
        add(UnitInformationStorage.bits, "bit", "bits")
        add(UnitInformationStorage.kilobytes, "kb")
        add(UnitInformationStorage.megabytes, "mb")
        add(UnitInformationStorage.gigabytes, "gb")
        add(UnitInformationStorage.terabytes, "tb")
        add(UnitArea.squareFeet, "sq ft", "sqft", "ft²", "ft2")
        add(UnitArea.squareMeters, "sq m", "sqm", "m²", "m2")
        add(UnitArea.squareKilometers, "sq km", "km²", "km2")
        add(UnitArea.squareMiles, "sq mi", "mi²", "mi2")
        add(UnitArea.acres, "acre", "acres")
        add(UnitArea.hectares, "ha", "hectare", "hectares")
        return u
    }()
    private static let unitNames = units.keys.sorted { $0.count > $1.count }

    /// "5 ft in cm", "100 f to c", "2.5 kg as lbs"
    private static func convert(_ s: String) -> Result? {
        var split: Range<String.Index>?
        for kw in [" in ", " to ", " as ", " into "] {
            if let r = s.range(of: kw, options: .backwards), split.map({ r.lowerBound > $0.lowerBound }) ?? true { split = r }
        }
        guard let split else { return nil }
        let left = s[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
        let target = s[split.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let to = units[target],
              let name = unitNames.first(where: { left.hasSuffix($0) && Self.boundary(left, before: $0) }),
              let from = units[name], type(of: from) == type(of: to) else { return nil }
        let expr = String(left.dropLast(name.count)).trimmingCharacters(in: .whitespaces)
        guard let v = expr.isEmpty ? 1 : Parser(expr)?.parse(), v.isFinite else { return nil }
        let out = Measurement(value: v, unit: from).converted(to: to).value
        return Result(display: "\(format(out, grouped: true, digits: 6)) \(target)", copy: format(out, grouped: false))
    }

    /// A unit suffix must not be the tail of a longer word ("pi" isn't "i" + …).
    private static func boundary(_ s: String, before suffix: String) -> Bool {
        let rest = s.dropLast(suffix.count)
        guard let c = rest.last else { return true }
        return !c.isLetter
    }

    // MARK: Expression parser (recursive descent)

    private enum Tok: Equatable { case num(Double), op(Character), word(String) }

    private final class Parser {
        private var toks: [Tok] = []
        private var i = 0

        init?(_ s: String) {
            var cs = Array(s), j = 0
            while j < cs.count {
                let c = cs[j]
                if c.isWhitespace { j += 1; continue }
                if c.isNumber || c == "." {
                    var n = ""
                    while j < cs.count, cs[j].isNumber || cs[j] == "." || (cs[j] == "," && j + 1 < cs.count && cs[j + 1].isNumber) {
                        if cs[j] != "," { n.append(cs[j]) }
                        j += 1
                    }
                    // Scientific notation: 1e3, 2.5e-4
                    if j + 1 < cs.count, cs[j] == "e", cs[j + 1].isNumber || ((cs[j + 1] == "-" || cs[j + 1] == "+") && j + 2 < cs.count && cs[j + 2].isNumber) {
                        n.append("e"); n.append(cs[j + 1]); j += 2
                        while j < cs.count, cs[j].isNumber { n.append(cs[j]); j += 1 }
                    }
                    guard let v = Double(n) else { return nil }
                    toks.append(.num(v)); continue
                }
                if c.isLetter || c == "π" {
                    var w = ""
                    while j < cs.count, cs[j].isLetter || cs[j] == "π" { w.append(cs[j]); j += 1 }
                    switch w {
                    case "x": toks.append(.op("*"))
                    case "of": toks.append(.op("*"))
                    case "mod": toks.append(.op("m"))
                    default: toks.append(.word(w))
                    }
                    continue
                }
                switch c {
                case "×": toks.append(.op("*"))
                case "÷": toks.append(.op("/"))
                case "−": toks.append(.op("-"))
                case "*" where j + 1 < cs.count && cs[j + 1] == "*": toks.append(.op("^")); j += 1
                case "+", "-", "*", "/", "^", "%", "(", ")", "!": toks.append(.op(c))
                default: return nil
                }
                j += 1
            }
            cs = []
        }

        func parse() -> Double? {
            guard !toks.isEmpty, let v = expr(), i == toks.count else { return nil }
            return v
        }

        private var peek: Tok? { i < toks.count ? toks[i] : nil }
        private func eat(_ c: Character) -> Bool { if peek == .op(c) { i += 1; return true }; return false }

        private func expr() -> Double? {
            guard var v = term() else { return nil }
            while true {
                let add = eat("+"), sub = !add && eat("-")
                guard add || sub else { return v }
                guard let r = term() else { return nil }
                // "200 + 10%" → 220, like a normal calculator
                let pct = i > 0 && toks[i - 1] == .op("%")
                let rhs = pct ? v * r : r
                v = add ? v + rhs : v - rhs
            }
        }

        private func term() -> Double? {
            guard var v = unary() else { return nil }
            while true {
                if eat("*") { guard let r = unary() else { return nil }; v *= r }
                else if eat("/") { guard let r = unary() else { return nil }; v /= r }
                else if eat("m") { guard let r = unary() else { return nil }; v = v.truncatingRemainder(dividingBy: r) }
                else if let t = peek, t == .op("(") || { if case .word = t { return true }; if case .num = t { return true }; return false }() {
                    guard let r = unary() else { return nil }; v *= r   // implicit: 2pi, 3(4+1)
                } else { return v }
            }
        }

        private func unary() -> Double? {
            if eat("-") { return unary().map { -$0 } }
            if eat("+") { return unary() }
            return power()
        }

        private func power() -> Double? {
            guard let b = postfix() else { return nil }
            if eat("^") { guard let e = unary() else { return nil }; return pow(b, e) }
            return b
        }

        private func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while true {
                if eat("%") { v /= 100 }
                else if eat("!") { guard v >= 0, v <= 170, v == v.rounded() else { return nil }; v = (1...max(1, Int(v))).reduce(1.0) { $0 * Double($1) } }
                else { return v }
            }
        }

        private func primary() -> Double? {
            guard let t = peek else { return nil }
            i += 1
            switch t {
            case .num(let v): return v
            case .op("("):
                guard let v = expr() else { return nil }
                _ = eat(")")   // forgive a missing close paren
                return v
            case .word(let w):
                switch w {
                case "pi", "π": return .pi
                case "e": return M_E
                default: break
                }
                let fns: [String: (Double) -> Double] = [
                    "sqrt": { $0.squareRoot() }, "cbrt": cbrt, "abs": abs, "ln": log, "log": log10,
                    "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
                    "round": { $0.rounded() }, "floor": floor, "ceil": ceil,
                ]
                guard let f = fns[w], let a = power() else { return nil }
                return f(a)
            default: return nil
            }
        }
    }
}

struct CalculatorPanel: View {
    @AppStorage("calc.history") private var historyRaw = ""
    @State private var input = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    private var history: [(String, String)] {
        historyRaw.split(separator: "\n").compactMap {
            let p = $0.split(separator: "\t", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
    }

    var body: some View {
        let r = Calc.evaluate(input)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "equal.square.fill").foregroundStyle(.orange)
                    Text("Calculator").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if copied { Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green).transition(.opacity) }
                }
                TextField("15% of 80, 5 ft in cm", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .focused($focused)
                    .onSubmit { commit(r) }
                    .simultaneousGesture(TapGesture().onEnded { NotchController.current?.panel.makeKey(); focused = true })
                Text(r.map { "= \($0.display)" } ?? " ")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .onTapGesture { if let r { copy(r.copy) } }
                    .help("Click to copy")
                ForEach(Array(history.prefix(4).enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 4) {
                        Text(h.0).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(h.1).lineLimit(1)
                    }
                    .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture { input = h.0 }
                }
            }
        }
    }

    private func commit(_ r: Calc.Result?) {
        guard let r else { return }
        copy(r.copy)
        let entry = "\(input.replacingOccurrences(of: "\t", with: " "))\t\(r.display)"
        historyRaw = ([entry] + historyRaw.split(separator: "\n").map(String.init).filter { $0 != entry }).prefix(20).joined(separator: "\n")
        input = ""
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }
}

// MARK: - Color picker (system eyedropper, copies hex)

final class ColorPickerStore: ObservableObject {
    static let shared = ColorPickerStore()
    @Published private(set) var recent: [String]
    private let key = "colorPicker.recent"
    private var sampler: NSColorSampler?

    init() { recent = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func pick() {
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] c in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampler = nil
                guard let c = c?.usingColorSpace(.sRGB) else { return }
                let hex = Self.hex(c)
                self.add(hex)
                Self.copy(hex)
                NotchModel.shared.flash(.message(icon: "eyedropper.full", text: "\(hex) copied", tint: Color(nsColor: c)))
            }
        }
    }

    func add(_ hex: String) {
        recent = Array(([hex] + recent.filter { $0 != hex }).prefix(12))
        UserDefaults.standard.set(recent, forKey: key)
    }
    func clear() { recent = []; UserDefaults.standard.removeObject(forKey: key) }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func hex(_ c: NSColor) -> String {
        func b(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    static func rgb(_ hex: String) -> (Int, Int, Int)? {
        guard hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF)
    }

    static func color(_ hex: String) -> Color {
        guard let (r, g, b) = rgb(hex) else { return .clear }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    static func hsl(_ hex: String) -> String? {
        guard let (r8, g8, b8) = rgb(hex) else { return nil }
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = d / (1 - abs(2 * l - 1))
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

struct ColorPickerPanel: View {
    @ObservedObject var store = ColorPickerStore.shared
    @State private var selected = 0
    @State private var copied: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "eyedropper.halffull").foregroundStyle(.pink)
                    Text("Color Picker").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let copied { Text("Copied \(copied)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green).lineLimit(1) }
                }
                let hex = store.recent.indices.contains(selected) ? store.recent[selected] : store.recent.first
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hex.map(ColorPickerStore.color) ?? Color.primary.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.2)))
                        .overlay { if hex == nil { Image(systemName: "eyedropper").foregroundStyle(.secondary) } }
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        if let hex, let (r, g, b) = ColorPickerStore.rgb(hex) {
                            value(hex, size: 15, weight: .semibold)
                            value("rgb(\(r), \(g), \(b))", size: 10.5)
                            if let h = ColorPickerStore.hsl(hex) { value(h, size: 10.5) }
                        } else {
                            Text("Grab any color on screen").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Button { selected = 0; store.pick() } label: {
                    Label("Pick color", systemImage: "eyedropper").font(.system(size: 11.5, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).tint(.pink).controlSize(.small)
                if !store.recent.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(store.recent.prefix(8).enumerated()), id: \.element) { i, h in
                            Circle().fill(ColorPickerStore.color(h))
                                .overlay(Circle().stroke(i == selected ? Color.primary : Color.primary.opacity(0.2), lineWidth: i == selected ? 2 : 1))
                                .frame(width: 16, height: 16)
                                .onTapGesture { selected = i; copy(h) }
                                .help(h)
                        }
                    }
                }
            }
        }
    }

    private func value(_ s: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(s).font(.system(size: size, weight: weight, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            .onTapGesture { copy(s) }
            .help("Click to copy")
    }

    private func copy(_ s: String) {
        ColorPickerStore.copy(s)
        withAnimation { copied = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { if copied == s { copied = nil } } }
    }
}

struct ColorPickerWidget: View {
    @ObservedObject var store = ColorPickerStore.shared
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: "eyedropper")
                if let h = store.recent.first { Circle().fill(ColorPickerStore.color(h)).frame(width: 9, height: 9) }
            }
        }
        .onTapGesture { store.pick() }
        .help("Pick a color from the screen (copies its hex)")
    }
}
