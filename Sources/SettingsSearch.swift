import SwiftUI

// MARK: - Smart search for Settings: every individual setting, with synonyms and typo tolerance

struct SettingEntry: Identifiable, Hashable {
    let title: String
    let section: SettingsSection
    let group: String          // the heading it sits under on its page
    let keywords: String       // synonyms people might type instead
    var id: String { "\(section.rawValue)/\(group)/\(title)" }
}

enum SettingsIndex {
    private static func e(_ s: SettingsSection, _ g: String, _ t: String, _ k: String = "") -> SettingEntry {
        SettingEntry(title: t, section: s, group: g, keywords: k)
    }

    static let all: [SettingEntry] = [
        // Appearance
        e(.appearance, "Style", "Notch material", "liquid glass frosted blur solid style look theme translucent transparent"),
        e(.appearance, "Style", "Glass variant", "liquid glass clear regular transparent see through invisible adaptive text color contrast"),
        e(.appearance, "Style", "Blur what's behind clear glass", "blur text distracting readable frosted soften clear glass"),
        e(.appearance, "Style", "Use this style even when collapsed", "collapsed pill glass idle"),
        e(.appearance, "Colors", "Accent color", "accent highlight pink color theme"),
        e(.appearance, "Colors", "Background color", "background black color fill dark"),
        e(.appearance, "Colors", "Tint", "tint color glass overlay"),
        e(.appearance, "Colors", "Tint strength", "tint opacity intensity"),
        e(.appearance, "Depth", "Shadow", "shadow depth drop"),
        e(.appearance, "Depth", "Show a subtle border", "border outline stroke edge"),
        e(.appearance, "Reset", "Reset appearance to defaults", "reset default restore"),
        // Size & Position
        e(.layout, "Expanded size", "Expanded width & height", "size big wide tall dimensions open expanded bigger smaller"),
        e(.layout, "Collapsed size", "Collapsed width & height", "size pill small collapsed idle dimensions"),
        e(.layout, "Position", "Placement", "floating attached island top gap position"),
        e(.layout, "Position", "Horizontal offset", "offset move left right center position side"),
        e(.layout, "Position", "Show on display", "monitor screen display external builtin"),
        e(.layout, "Reset", "Reset size & position", "reset default"),
        // Behavior
        e(.behavior, "Opening", "Open on hover or click", "hover click open trigger"),
        e(.behavior, "Opening", "Hover delay", "hover delay wait open speed"),
        e(.behavior, "Opening", "Close when the pointer leaves", "close auto mouse leave pointer away"),
        e(.behavior, "Opening", "Close delay", "close delay seconds timeout auto close"),
        e(.behavior, "Motion", "Animation", "animation bouncy smooth snappy spring motion"),
        e(.behavior, "Motion", "Haptic feedback on open", "haptic vibration trackpad feedback"),
        e(.behavior, "System", "Hide while an app is fullscreen", "fullscreen full screen hide video"),
        e(.behavior, "System", "Hide from screen recordings & shares", "privacy screen share zoom meet recording screenshot hide capture"),
        e(.behavior, "System", "Keep clear of app menus", "menu bar menus dodge chrome help overlap cover move accessibility"),
        e(.behavior, "System", "Replace the volume & brightness sliders", "volume brightness hud slider osd sound display keys accessibility"),
        e(.behavior, "System", "Pop-out style for the volume/brightness HUD", "popup pop out hud volume brightness"),
        e(.behavior, "System", "Show menu bar icon", "menu bar icon status item tray"),
        e(.behavior, "System", "Open at login", "startup login launch boot automatically"),
        e(.behavior, "Hide notch", "Hide the notch completely", "hide disable test exam presentation invisible off"),
        e(.behavior, "Shortcuts", "Keyboard shortcuts", "shortcut hotkey keybind keyboard key binding rebind"),
        e(.behavior, "Shortcuts", "Screenshot & recording shortcuts", "screenshot record capture shortcut"),
        e(.behavior, "Shortcuts", "Restore default shortcuts", "reset shortcut hotkey default"),
        // Widgets & Tabs
        e(.widgets, "Collapsed notch", "Collapsed notch left / center / right widgets", "glance ears pill idle battery weather clock collapsed widget"),
        e(.widgets, "Header widgets", "Header widgets", "top bar header widgets clock weather battery mirror cpu"),
        e(.widgets, "Header widgets", "Focus status widget / box", "focus do not disturb dnd sleep work moon status"),
        e(.widgets, "Home boxes", "Home boxes", "home boxes panels cards music calendar layout dashboard"),
        e(.widgets, "File Shelf", "Bookshelf look", "shelf files books bookshelf drop"),
        e(.widgets, "Tabs", "Tabs", "tabs home shelf ai live tools hide"),
        e(.widgets, "Tabs", "Default tab when opened", "default tab start open"),
        e(.widgets, "Tabs", "Go back to Home after being closed", "home reset return idle timeout seconds default tab reopen"),
        // Live
        e(.live, "Live activities in the notch", "Live games for favorite teams", "sports scores games teams nfl nba live"),
        e(.live, "Live activities in the notch", "Stock ticker", "stocks market ticker watchlist"),
        e(.live, "Leagues", "Leagues", "nfl nba mlb nhl soccer epl football basketball baseball hockey"),
        e(.live, "Favorites", "Favorite teams", "favorite team teams follow"),
        e(.live, "Watchlist", "Stock watchlist", "stocks symbols tickers crypto bitcoin"),
        e(.live, "Canvas", "Connect Canvas LMS", "canvas lms school assignments homework todo to-do instructure classes"),
        e(.live, "Canvas", "How to get a Canvas token", "canvas token access api guide help instructure"),
        e(.widgets, "Home boxes", "Dancing cow under Now Playing", "cow dancing polish gif music fun"),
        e(.widgets, "Home boxes", "Aquarium live stream box", "aquarium fish monterey bay live stream video youtube"),
        e(.live, "Weather", "Weather city", "weather city location forecast"),
        e(.live, "Weather", "Fahrenheit", "celsius fahrenheit temperature units"),
        // Fun
        e(.fun, "Fun mode", "Fun mode", "fun silly party toys"),
        e(.fun, "Mirror", "Mirror filters", "camera filters mirror effects comic thermal"),
        e(.fun, "Desktop goose", "Desktop goose", "goose duck bird honk wander"),
        e(.fun, "Now Playing & Timer", "Vinyl record for Now Playing", "vinyl record music spin album"),
        e(.fun, "Now Playing & Timer", "Bomb timer", "bomb timer fuse explode focus"),
        e(.fun, "Sounds", "Sound board", "sounds clown horn munch eat wasted soundboard noise"),
        e(.fun, "Sounds", "Surprise me (random noises)", "random surprise noise"),
        e(.fun, "Sounds", "Sounds when the notch opens and closes", "open close sound noise expand collapse volume"),
        e(.fun, "Sounds", "Custom sounds folder", "custom sounds mp3 replace folder"),
        e(.fun, "Big red button", "Big red button", "red button shutdown shut down nuke nuclear power off"),
        // Privacy
        e(.lock, "Permissions", "Permissions", "privacy permission screen recording camera calendar accessibility automation access"),
        e(.lock, "Permissions", "Re-run setup", "onboarding setup permissions wizard"),
        e(.lock, "AI", "AI model", "ai assistant model apple intelligence status"),
    ]

    // MARK: Matching

    private static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Levenshtein distance, capped for speed (we only care about 0, 1 or 2).
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 2 { return 3 }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// How well one typed word matches a set of words (0 = no match).
    private static func tokenScore(_ t: String, in ws: [String], weight: Int) -> Int {
        if ws.contains(t) { return 10 * weight }
        if ws.contains(where: { $0.hasPrefix(t) }) { return 7 * weight }
        if t.count >= 4, ws.contains(where: { $0.count >= 4 && $0.first == t.first && $0.dropFirst().first != nil && distance(t, $0) <= (t.count >= 8 ? 2 : 1) }) { return 4 * weight }   // typos
        if t.count >= 3, ws.contains(where: { $0.contains(t) }) { return 3 * weight }
        return 0
    }

    static func search(_ query: String) -> [SettingEntry] {
        let q = words(query)
        guard !q.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespaces)
        var scored: [(SettingEntry, Int)] = []
        for e in all {
            let title = words(e.title), kw = words(e.keywords), sec = words(e.section.title + " " + e.group)
            var total = 0
            var matchedAll = true
            for t in q {
                let s = max(tokenScore(t, in: title, weight: 5), tokenScore(t, in: kw, weight: 3), tokenScore(t, in: sec, weight: 2))
                if s == 0 { matchedAll = false; break }
                total += s
            }
            guard matchedAll else { continue }
            if e.title.lowercased().hasPrefix(phrase) { total += 60 }
            else if e.title.lowercased().contains(phrase) { total += 30 }
            scored.append((e, total))
        }
        // Ties: the shorter, more specific title first.
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }.prefix(25).map(\.0)
    }
}

// MARK: - Views

struct SettingsSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(focused ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 1.5))
        .animation(.smooth(duration: 0.15), value: focused)
    }
}

struct SettingsSearchResults: View {
    let results: [SettingEntry]
    var open: (SettingEntry) -> Void

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.tertiary)
                Text("No matching settings").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 24)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(results) { r in
                        Button { open(r) } label: {
                            HStack(spacing: 9) {
                                IconTile(symbol: r.section.icon, colors: r.section.tint).scaleEffect(0.8).frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Text("\(r.section.title) › \(r.group)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SearchRowStyle())
                    }
                }
            }
        }
    }
}

private struct SearchRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0)))
            .onHover { hover = $0 }
    }
}
