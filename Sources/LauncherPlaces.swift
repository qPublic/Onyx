import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Places inside apps: the launcher's search also finds the pages of System Settings (Wi‑Fi, Bluetooth, Displays, and
// the settings inside them, like True Tone), Onyx's own settings and Finder's folders, and opens straight to them, the way
// Spotlight does. System Settings' pages are read from macOS itself (each page ships its name, icon and search words), so
// the list matches whatever macOS this Mac runs, in its language. Other apps don't publish their windows, so they can't be listed.

struct LauncherPlace: Identifiable, Hashable {
    enum Icon: Hashable { case file(String), type(String), symbol(String) }
    let title: String       // "Wi‑Fi", "True Tone"
    let parent: String      // "System Settings", "System Settings › Displays", "Finder"
    let target: String      // a URL to open, or "onyx:<section>" for Onyx's own settings
    let icon: Icon
    let words: [String], keys: [String], parentWords: [String]   // what it's found by
    var id: String { target + "|" + title }

    init(title: String, parent: String, keywords: String = "", target: String, icon: Icon) {
        self.title = title; self.parent = parent; self.target = target; self.icon = icon
        words = LauncherPlaces.words(title); keys = LauncherPlaces.words(keywords); parentWords = LauncherPlaces.words(parent)
    }
}

@MainActor final class LauncherPlaces: ObservableObject {
    static let shared = LauncherPlaces()
    nonisolated static let settingsApp = "System Settings"
    @Published private(set) var all: [LauncherPlace] = []
    private var loaded = false, icons: [LauncherPlace.Icon: NSImage] = [:]

    /// Reads the list once, off the main thread, the first time the launcher opens.
    func load() {
        guard !loaded else { return }
        loaded = true
        let battery = BatteryMonitor.shared.hasBattery
        Task { all = await Task.detached(priority: .utility) { Self.systemSettings(battery: battery) + Self.finder() }.value }
    }

    /// The best few matches: System Settings and Finder first, then Onyx's own settings.
    func search(_ query: String) -> [LauncherPlace] {
        var out = Self.match(query, in: all, limit: 5)
        if query.trimmingCharacters(in: .whitespaces).count >= 3 {
            out += SettingsIndex.search(query).prefix(2).map {
                LauncherPlace(title: $0.title, parent: "Onyx Settings › \($0.section.title)", target: "onyx:\($0.section.rawValue)", icon: .symbol($0.section.icon))
            }
        }
        return out
    }

    func open(_ p: LauncherPlace) {
        if p.target.hasPrefix("onyx:") {
            if let s = SettingsSection(rawValue: String(p.target.dropFirst(5))) { SettingsView.open(s) }
        } else if let u = URL(string: p.target) {
            NSWorkspace.shared.open(u)
        }
    }

    func image(_ p: LauncherPlace) -> NSImage? {
        if let i = icons[p.icon] { return i }
        let i: NSImage?
        switch p.icon {
        case .file(let path): i = NSWorkspace.shared.icon(forFile: path)
        case .type(let id): i = UTType(id).map { NSWorkspace.shared.icon(for: $0) }
        case .symbol: i = nil
        }
        icons[p.icon] = i
        return i
    }

    // MARK: Matching

    /// Lowercased words, with marks inside a word dropped ("Wi‑Fi" and "wi-fi" are both "wi", "fi").
    nonisolated static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Every word typed has to start a word of the name, its search words or its app; a page's own name counts most, and
    /// a whole page comes before the settings inside one.
    nonisolated static func match(_ query: String, in places: [LauncherPlace], limit: Int) -> [LauncherPlace] {
        let q = words(query), typed = q.joined()
        guard typed.count >= 2 else { return [] }
        var hits: [(LauncherPlace, Int)] = []
        for p in places {
            let name = p.words.joined()
            var score = 0, real = false
            if name.hasPrefix(typed) {   // "wifi" and "wi fi" both find Wi‑Fi
                score = name == typed ? 100 : 80; real = true
            } else {
                for w in q {
                    if p.words.contains(where: { $0.hasPrefix(w) }) { score += 10; real = true }
                    else if w.count >= 3, p.keys.contains(where: { $0.hasPrefix(w) }) { score += 4; real = true }
                    else if p.parentWords.contains(where: { $0.hasPrefix(w) }) { score += 1 }
                    else { score = 0; real = false; break }
                }
            }
            guard real else { continue }
            hits.append((p, score + (p.parent.contains("›") ? 0 : 3)))
        }
        return hits.sorted { ($1.1, $0.0.title.count, $0.0.title) < ($0.1, $1.0.title.count, $1.0.title) }.prefix(limit).map(\.0)
    }

    // MARK: Where the places come from

    /// Pages macOS keeps for hardware this Mac may not have, or for its own use.
    nonisolated static let hiddenPanes = ["FollowUp", "CD-DVD", "Classroom", "ClassKit"]

    /// Every page of System Settings and the settings inside each, from the extensions macOS ships them as.
    nonisolated static func systemSettings(in dir: URL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions"), battery: Bool,
                                           legacy: [String] = ["/Library/PreferencePanes", NSHomeDirectory() + "/Library/PreferencePanes"]) -> [LauncherPlace] {
        let fm = FileManager.default
        var out: [LauncherPlace] = [], seen = Set<String>()
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "appex" {
            guard let b = Bundle(url: u), let id = b.bundleIdentifier, let info = b.infoDictionary,
                  let ex = info["EXAppExtensionAttributes"] as? [String: Any], ex["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  !hiddenPanes.contains(where: id.contains) else { continue }
            let attrs = ex["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
            // How the sidebar shows it on this Mac: Battery on a laptop, Energy on a desktop.
            let rep = (attrs["representations"] as? [[String: Any]] ?? []).first { r in
                let rule = r["predicate"] as? String ?? ""
                return !(r["sidebar-name"] as? String ?? "").isEmpty && rule.hasSuffix(rule.contains("battery") && !battery ? "!= YES" : "== YES")
            }
            let sidebar = (rep?["sidebar-name"] as? String).map { b.localizedString(forKey: $0, value: nil, table: nil) }
            let plain = (info["CFBundleDisplayName"] as? String).flatMap { $0.range(of: "[a-z][A-Z]|_", options: .regularExpression) == nil ? $0 : nil }   // not a code name
            guard let name = (b.localizedInfoDictionary?["CFBundleDisplayName"] as? String) ?? sidebar ?? plain, !name.isEmpty else { continue }
            let type = (rep?["sidebar-iconUTTypeIdentifier"] as? String).flatMap { UTType($0) == nil ? nil : $0 }
            let icon: LauncherPlace.Icon = type.map { .type($0) } ?? .file(u.path)
            let link = "x-apple.systempreferences:" + id
            out.append(LauncherPlace(title: name, parent: settingsApp, target: link, icon: icon))

            // The settings inside the page: each has a title, words it's found by, and a spot the page can open at.
            guard let file = attrs["searchTermsFileName"] as? String, let tu = b.url(forResource: file, withExtension: "searchTerms"),
                  let terms = NSDictionary(contentsOf: tu) as? [String: Any] else { continue }
            for anchor in terms.keys.sorted() {
                for s in (terms[anchor] as? [String: Any])?["localizableStrings"] as? [[String: Any]] ?? [] {
                    guard let t = s["title"] as? String, !t.isEmpty, t != name, seen.insert(id + "|" + t).inserted else { continue }
                    let spot = anchor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? anchor
                    out.append(LauncherPlace(title: t, parent: settingsApp + " › " + name, keywords: s["index"] as? String ?? "", target: link + "?" + spot, icon: icon))
                }
            }
        }
        for d in legacy {   // pages other apps add
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".prefPane") {
                out.append(LauncherPlace(title: String(n.dropLast(9)), parent: settingsApp, target: URL(fileURLWithPath: d + "/" + n).absoluteString, icon: .file(d + "/" + n)))
            }
        }
        return out.sorted { $0.title < $1.title }
    }

    /// Finder's usual folders, by their own names: nothing inside them is looked at.
    nonisolated static func finder() -> [LauncherPlace] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        var urls = [FileManager.SearchPathDirectory.downloadsDirectory, .documentDirectory, .desktopDirectory, .picturesDirectory, .moviesDirectory, .musicDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        urls += [URL(fileURLWithPath: "/Applications"), home, home.appendingPathComponent(".Trash")]
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: cloud.path) { urls.append(cloud) }
        return urls.map { u in
            let name = u.lastPathComponent == ".Trash" ? "Trash" : u == cloud ? "iCloud Drive" : u.lastPathComponent
            return LauncherPlace(title: name, parent: "Finder", keywords: u == home ? "home folder" : "folder", target: u.absoluteString, icon: .file(u.path))
        }
    }
}

/// A place in the launcher's results.
struct LauncherPlaceRow: View {
    let place: LauncherPlace
    var highlighted = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if case .symbol(let s) = place.icon { Image(systemName: s).font(.system(size: 15)).foregroundStyle(.white.opacity(0.9)) }
                    else if let i = LauncherPlaces.shared.image(place) { Image(nsImage: i).resizable() }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(place.parent).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if highlighted { Text("↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(highlighted ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
    }
}
