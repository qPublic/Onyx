import Foundation
import SwiftUI

// MARK: - Sports (ESPN public scoreboard / summary / standings)

struct League: Identifiable, Hashable {
    let id: String       // short key used in prefs
    let name: String
    let path: String     // sport/league for ESPN

    static let all: [League] = [
        League(id: "nfl", name: "NFL", path: "football/nfl"),
        League(id: "nba", name: "NBA", path: "basketball/nba"),
        League(id: "mlb", name: "MLB", path: "baseball/mlb"),
        League(id: "nhl", name: "NHL", path: "hockey/nhl"),
        League(id: "wnba", name: "WNBA", path: "basketball/wnba"),
        League(id: "cfb", name: "NCAAF", path: "football/college-football"),
        League(id: "cbb", name: "NCAAM", path: "basketball/mens-college-basketball"),
        League(id: "epl", name: "Premier League", path: "soccer/eng.1"),
        League(id: "mls", name: "MLS", path: "soccer/usa.1"),
        League(id: "ucl", name: "Champions League", path: "soccer/uefa.champions"),
        League(id: "laliga", name: "La Liga", path: "soccer/esp.1"),
        League(id: "f1", name: "F1", path: "racing/f1"),
    ]
    static func byID(_ id: String) -> League? { all.first { $0.id == id } }
}

struct TeamLine: Hashable {
    let id: String
    let abbr: String
    let name: String
    let logo: URL?
    let score: String
    let record: String
    let color: String
    let linescores: [String]
    let isHome: Bool
}

struct Game: Identifiable, Hashable {
    let id: String
    let league: League
    let name: String
    let state: String        // pre / in / post
    let detail: String       // "Bot 4th", "Final", "7:05 PM"
    let date: Date
    let away: TeamLine
    let home: TeamLine
    let lastPlay: String?
    let leaders: [String]
    let broadcast: String?
    var live: Bool { state == "in" }
}

struct BoxRow: Hashable { let name: String; let stats: [String] }
struct BoxTable: Hashable { let team: String; let labels: [String]; let rows: [BoxRow] }
struct GameDetail {
    var plays: [String] = []
    var box: [BoxTable] = []
}
struct StandingRow: Identifiable, Hashable { let id: String; let team: String; let logo: URL?; let record: String; let pct: String; let gb: String }
struct StandingGroup: Identifiable, Hashable { let id: String; let rows: [StandingRow] }

final class SportsService: ObservableObject {
    static let shared = SportsService()
    @Published var games: [String: [Game]] = [:]  // league id -> games
    @Published var selectedLeague = "nfl"
    @Published var detail: GameDetail?
    @Published var standings: [StandingGroup] = []
    @Published var loading = false
    private var timer: Timer?
    private let base = "https://site.api.espn.com/apis/site/v2/sports/"

    var enabledLeagues: [League] { Prefs.list(Prefs.leagues).compactMap(League.byID) }
    var favorites: [String] { Prefs.list(Prefs.favoriteTeams).map { $0.uppercased() } }

    /// The live (or most recent today) game involving a favorite team — shown as a live activity.
    var favoriteLiveGame: Game? {
        let favs = Set(favorites)
        guard !favs.isEmpty else { return nil }
        return games.values.flatMap { $0 }.first { $0.live && (favs.contains($0.home.abbr) || favs.contains($0.away.abbr)) }
    }

    func start() {
        selectedLeague = enabledLeagues.first?.id ?? "nfl"
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.wantsFast || Date().timeIntervalSince(self.lastRefresh) > 300 { self.refreshAll() }
        }.tolerant()
    }

    private var lastRefresh = Date.distantPast
    /// Every 30s only while scores are on screen or a favorite team is playing; otherwise every 5 minutes.
    private var wantsFast: Bool {
        let m = NotchModel.shared
        return (m.expanded && m.tab == .live) || (Prefs.bool(Prefs.sportsActivity) && favoriteLiveGame != nil)
    }

    func refreshAll() {
        lastRefresh = Date()
        for l in enabledLeagues { Task { await load(l) } }
    }
    func refreshIfStale() { if Date().timeIntervalSince(lastRefresh) > 30 { refreshAll() } }

    private func fetch(_ s: String) async -> [String: Any]? {
        guard let u = URL(string: s), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    func load(_ l: League) async {
        guard let j = await fetch(base + l.path + "/scoreboard"),
              let events = j["events"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoNoSec = DateFormatter(); isoNoSec.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
        let parsed: [Game] = events.compactMap { e in
            guard let id = e["id"] as? String,
                  let comp = (e["competitions"] as? [[String: Any]])?.first,
                  let cs = comp["competitors"] as? [[String: Any]], cs.count >= 2 else { return nil }
            let status = (e["status"] as? [String: Any])?["type"] as? [String: Any]
            let lines = cs.map { c -> TeamLine in
                let t = c["team"] as? [String: Any] ?? [:]
                let rec = ((c["records"] as? [[String: Any]])?.first?["summary"] as? String) ?? ""
                let ls = (c["linescores"] as? [[String: Any]])?.map { ($0["displayValue"] as? String) ?? "\($0["value"] ?? "")" } ?? []
                return TeamLine(id: t["id"] as? String ?? "",
                                abbr: (t["abbreviation"] as? String ?? "?").uppercased(),
                                name: t["shortDisplayName"] as? String ?? t["displayName"] as? String ?? "",
                                logo: (t["logo"] as? String).flatMap(URL.init(string:)),
                                score: c["score"] as? String ?? "",
                                record: rec,
                                color: t["color"] as? String ?? "444444",
                                linescores: ls,
                                isHome: (c["homeAway"] as? String) == "home")
            }
            let home = lines.first { $0.isHome } ?? lines[0]
            let away = lines.first { !$0.isHome } ?? lines[1]
            var leaders: [String] = []
            for c in cs {
                for cat in (c["leaders"] as? [[String: Any]] ?? []).prefix(2) {
                    guard let top = (cat["leaders"] as? [[String: Any]])?.first,
                          let ath = top["athlete"] as? [String: Any] else { continue }
                    leaders.append("\(ath["shortName"] as? String ?? "") · \(cat["shortDisplayName"] as? String ?? cat["abbreviation"] as? String ?? "") \(top["displayValue"] as? String ?? "")")
                }
            }
            let dateStr = e["date"] as? String ?? ""
            let date = iso.date(from: dateStr) ?? isoNoSec.date(from: dateStr.replacingOccurrences(of: "Z", with: "+0000")) ?? Date()
            let bc = (comp["broadcasts"] as? [[String: Any]])?.first.flatMap { ($0["names"] as? [String])?.first }
            return Game(id: id, league: l, name: e["shortName"] as? String ?? "",
                        state: status?["state"] as? String ?? "pre",
                        detail: status?["shortDetail"] as? String ?? "",
                        date: date, away: away, home: home,
                        lastPlay: ((comp["situation"] as? [String: Any])?["lastPlay"] as? [String: Any])?["text"] as? String,
                        leaders: leaders, broadcast: bc)
        }
        .sorted { ($0.live ? 0 : $0.state == "pre" ? 1 : 2, $0.date) < ($1.live ? 0 : $1.state == "pre" ? 1 : 2, $1.date) }
        await MainActor.run { self.games[l.id] = parsed }
    }

    func loadDetail(_ g: Game) {
        detail = nil
        Task {
            guard let j = await fetch(base + g.league.path + "/summary?event=\(g.id)") else { return }
            var d = GameDetail()
            if let plays = j["plays"] as? [[String: Any]] {
                d.plays = plays.suffix(12).reversed().compactMap { $0["text"] as? String }.filter { !$0.hasPrefix("Pitch ") }
            }
            if d.plays.isEmpty, let drives = (j["drives"] as? [String: Any])?["previous"] as? [[String: Any]] {
                d.plays = drives.suffix(3).reversed().flatMap { ($0["plays"] as? [[String: Any]] ?? []).suffix(4).reversed() }
                    .compactMap { $0["text"] as? String }
            }
            if let players = (j["boxscore"] as? [String: Any])?["players"] as? [[String: Any]] {
                for p in players {
                    let team = (p["team"] as? [String: Any])?["abbreviation"] as? String ?? ""
                    guard let st = (p["statistics"] as? [[String: Any]])?.first,
                          let labels = st["labels"] as? [String],
                          let aths = st["athletes"] as? [[String: Any]] else { continue }
                    let rows = aths.prefix(8).compactMap { a -> BoxRow? in
                        guard let n = (a["athlete"] as? [String: Any])?["shortName"] as? String,
                              let s = a["stats"] as? [String] else { return nil }
                        return BoxRow(name: n, stats: Array(s.prefix(7)))
                    }
                    d.box.append(BoxTable(team: team, labels: Array(labels.prefix(7)), rows: rows))
                }
            }
            await MainActor.run { self.detail = d }
        }
    }

    func loadStandings(_ l: League) {
        standings = []
        Task {
            guard let j = await fetch("https://site.api.espn.com/apis/v2/sports/\(l.path)/standings") else { return }
            var groups: [StandingGroup] = []
            func parse(_ node: [String: Any]) {
                if let entries = (node["standings"] as? [String: Any])?["entries"] as? [[String: Any]] {
                    let rows: [StandingRow] = entries.compactMap { e in
                        guard let t = e["team"] as? [String: Any] else { return nil }
                        let stats = e["stats"] as? [[String: Any]] ?? []
                        func v(_ n: String) -> String { stats.first { ($0["name"] as? String) == n }?["displayValue"] as? String ?? "" }
                        let rec = v("overall").isEmpty ? "\(v("wins"))-\(v("losses"))" : v("overall")
                        let logo = ((t["logos"] as? [[String: Any]])?.first?["href"] as? String).flatMap(URL.init(string:))
                        return StandingRow(id: t["id"] as? String ?? UUID().uuidString, team: t["abbreviation"] as? String ?? "",
                                           logo: logo, record: rec, pct: v("winPercent").isEmpty ? v("points") : v("winPercent"),
                                           gb: v("gamesBehind"))
                    }
                    .sorted { (Double($0.pct) ?? 0) > (Double($1.pct) ?? 0) }
                    groups.append(StandingGroup(id: node["name"] as? String ?? "Standings", rows: rows))
                }
                for c in node["children"] as? [[String: Any]] ?? [] { parse(c) }
            }
            parse(j)
            await MainActor.run { self.standings = groups }
        }
    }
}

// MARK: - Markets (Yahoo Finance chart endpoint, no key)

struct Quote: Identifiable, Hashable {
    let id: String   // symbol
    let name: String
    let price: Double
    let previousClose: Double
    let points: [Double]
    let currency: String
    var change: Double { price - previousClose }
    var changePct: Double { previousClose == 0 ? 0 : change / previousClose * 100 }
    var up: Bool { change >= 0 }
}

final class MarketsService: ObservableObject {
    static let shared = MarketsService()
    @Published var quotes: [Quote] = []
    @Published var lastUpdate: Date?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            if self?.wanted == true { self?.refresh() }
        }.tolerant()
    }

    /// Only fetch prices while something shows them.
    private var wanted: Bool {
        let m = NotchModel.shared
        return Prefs.bool(Prefs.tickerActivity) || HomeLayout.shared.contains(.stocks) || WidgetLayout.shared.contains(.stock)
            || [AP.collapsedLeft, AP.collapsedMid, AP.collapsedRight].contains(.stock) || (m.expanded && m.tab == .live)
    }
    private var lastRefresh = Date.distantPast
    func refreshIfStale() { if Date().timeIntervalSince(lastRefresh) > 60 { refresh() } }

    func refresh() {
        lastRefresh = Date()
        let syms = Prefs.list(Prefs.watchlist)
        Task {
            var out: [Quote] = []
            await withTaskGroup(of: Quote?.self) { g in
                for s in syms { g.addTask { await Self.quote(s) } }
                for await q in g { if let q { out.append(q) } }
            }
            let ordered = syms.compactMap { s in out.first { $0.id == s.uppercased() } }
            await MainActor.run { self.quotes = ordered; self.lastUpdate = Date() }
        }
    }

    static func quote(_ symbol: String) async -> Quote? {
        let s = symbol.uppercased()
        guard let enc = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1d&interval=5m") else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = ((j["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = r["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double else { return nil }
        let prev = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
        let closes = ((((r["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first)?["close"] as? [Any])?
            .compactMap { $0 as? Double } ?? []
        let name = meta["shortName"] as? String ?? meta["longName"] as? String ?? s
        return Quote(id: s, name: name, price: price, previousClose: prev, points: closes, currency: meta["currency"] as? String ?? "USD")
    }
}
