import AppKit
import SwiftUI
import Security

// MARK: - Keychain (the Canvas token is a password — it never goes in plain prefs)

enum Keychain {
    private static let service = "local.onyx.notch"

    static func set(_ value: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - Canvas LMS to-do (planner items that still need doing)

struct CanvasItem: Identifiable, Hashable {
    let id: String
    let title: String
    let course: String
    let due: Date?
    let type: String
    let url: URL?

    var overdue: Bool { (due ?? .distantFuture) < Date() }
    var icon: String {
        switch type {
        case "quiz": "checklist"
        case "discussion_topic": "bubble.left.and.bubble.right"
        case "wiki_page": "doc.text"
        case "calendar_event": "calendar"
        case "planner_note": "note.text"
        default: "doc.plaintext"
        }
    }
}

final class CanvasService: ObservableObject {
    static let shared = CanvasService()
    static let baseKey = "canvas.baseURL"
    private static let tokenAccount = "canvas.token"

    @Published private(set) var items: [CanvasItem] = []
    @Published private(set) var userName: String?
    @Published private(set) var status: String?
    @Published private(set) var loading = false
    @Published private(set) var lastUpdate: Date?
    private var timer: Timer?

    var baseURL: String { Prefs.string(Self.baseKey) }
    var connected: Bool { !baseURL.isEmpty && Keychain.get(Self.tokenAccount) != nil }
    /// Due within a week (plus anything overdue) — what the widget counts.
    var dueSoon: Int { items.filter { ($0.due ?? .distantFuture) < Date().addingTimeInterval(7 * 86400) }.count }

    func start() {
        if connected { Task { await refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            Task { await self.refresh() }
        }
    }

    /// "school.instructure.com" or a full URL → "https://school.instructure.com"
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let u = URL(string: t), let host = u.host else { return "" }
        return "https://\(host)"
    }

    private func request(_ path: String, base: String, token: String) async throws -> Data {
        guard let u = URL(string: base + path) else { throw CanvasError.badURL }
        var r = URLRequest(url: u)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw CanvasError.unauthorized }
        guard (200..<300).contains(code) else { throw CanvasError.http(code) }
        return d
    }

    enum CanvasError: LocalizedError {
        case badURL, unauthorized, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: "That school address doesn't look right."
            case .unauthorized: "Canvas rejected the token. Make a new one and paste it again."
            case .http(let c): "Canvas returned an error (\(c))."
            }
        }
    }

    /// Checks the token against Canvas before saving it.
    @MainActor
    func connect(url: String, token: String) async {
        let base = Self.normalize(url), tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { status = "Type your school's Canvas address first (the grey example text doesn't count)."; return }
        guard !tok.isEmpty else { status = "Paste your access token into the token field."; return }
        loading = true; defer { loading = false }
        do {
            let d = try await request("/api/v1/users/self/profile", base: base, token: tok)
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            UserDefaults.standard.set(base, forKey: Self.baseKey)
            Keychain.set(tok, account: Self.tokenAccount)
            userName = j?["name"] as? String
            status = nil
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor
    func disconnect() {
        Keychain.delete(Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.baseKey)
        items = []; userName = nil; status = nil; lastUpdate = nil
    }

    @MainActor
    func refresh() async {
        guard let tok = Keychain.get(Self.tokenAccount), !baseURL.isEmpty else { return }
        loading = true; defer { loading = false }
        let iso = ISO8601DateFormatter()
        let start = iso.string(from: Date().addingTimeInterval(-14 * 86400))
        let end = iso.string(from: Date().addingTimeInterval(28 * 86400))
        do {
            if userName == nil,
               let d = try? await request("/api/v1/users/self/profile", base: baseURL, token: tok),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { userName = j["name"] as? String }
            let d = try await request("/api/v1/planner/items?start_date=\(start)&end_date=\(end)&filter=incomplete_items&per_page=100",
                                      base: baseURL, token: tok)
            let arr = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
            let isoF = ISO8601DateFormatter()
            items = arr.compactMap { o in
                let p = o["plannable"] as? [String: Any] ?? [:]
                guard let title = (p["title"] as? String) ?? (p["name"] as? String) else { return nil }
                let dueStr = (p["due_at"] as? String) ?? (p["todo_date"] as? String) ?? (o["plannable_date"] as? String)
                let path = o["html_url"] as? String ?? ""
                return CanvasItem(id: "\(o["plannable_type"] ?? "")-\(o["plannable_id"] ?? UUID().uuidString)",
                                  title: title, course: o["context_name"] as? String ?? "",
                                  due: dueStr.flatMap { isoF.date(from: $0) }, type: o["plannable_type"] as? String ?? "",
                                  url: URL(string: path.hasPrefix("http") ? path : baseURL + path))
            }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            lastUpdate = Date(); status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Views

/// Stable color per course.
private func courseColor(_ name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .red]
    return palette[Int(name.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) } % UInt64(palette.count))]
}

private func dueText(_ d: Date?) -> String {
    guard let d else { return "No due date" }
    let cal = Calendar.current
    let time = d.formatted(date: .omitted, time: .shortened)
    if d < Date() { return "Overdue · " + d.formatted(.relative(presentation: .named)) }
    if cal.isDateInToday(d) { return "Today \(time)" }
    if cal.isDateInTomorrow(d) { return "Tomorrow \(time)" }
    return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " \(time)"
}

struct CanvasPanel: View {
    @ObservedObject var canvas = CanvasService.shared

    var body: some View {
        Card {
            if !canvas.connected {
                VStack(spacing: 7) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 24)).foregroundStyle(.red)
                    Text("Connect Canvas to see your to-do").font(.system(size: 12, weight: .medium))
                    HStack {
                        Button("Connect…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
                        Button("How to get a token") { CanvasGuide.show() }
                    }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Canvas To-Do", systemImage: "graduationcap.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if canvas.loading { ProgressView().controlSize(.mini) }
                        Button { Task { await canvas.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let s = canvas.status { Text(s).font(.caption).foregroundStyle(.orange) }
                    if canvas.items.isEmpty && canvas.status == nil {
                        Text(canvas.lastUpdate == nil ? "Loading…" : "All caught up 🎉").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 4) {
                                ForEach(canvas.items) { it in
                                    Button { if let u = it.url { NSWorkspace.shared.open(u) } } label: {
                                        HStack(spacing: 7) {
                                            RoundedRectangle(cornerRadius: 1.5).fill(courseColor(it.course)).frame(width: 3, height: 28)
                                            Image(systemName: it.icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(it.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                                Text("\(it.course) · \(dueText(it.due))").font(.system(size: 9.5))
                                                    .foregroundStyle(it.overdue ? Color.red : Color.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open in Canvas")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CanvasWidget: View {
    @ObservedObject var canvas = CanvasService.shared
    var body: some View {
        if canvas.connected {
            HStack(spacing: 4) {
                Image(systemName: "graduationcap.fill").foregroundStyle(.red)
                Text("\(canvas.dueSoon) due")
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
            .help("Canvas: due in the next 7 days")
        }
    }
}

struct CanvasGlance: View {
    @ObservedObject var canvas = CanvasService.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "graduationcap.fill")
            Text(canvas.connected ? "\(canvas.dueSoon)" : "–")
        }
        .foregroundStyle(canvas.items.contains(where: \.overdue) ? Color.red : Color.primary)
    }
}

/// Settings › Live › Canvas
struct CanvasSettingsSection: View {
    @ObservedObject var canvas = CanvasService.shared
    @State private var url = Prefs.string(CanvasService.baseKey)
    @State private var token = ""

    var body: some View {
        Section {
            if canvas.connected {
                LabeledContent("Connected") {
                    Text(canvas.userName.map { "\($0) · \(canvas.baseURL.replacingOccurrences(of: "https://", with: ""))" } ?? canvas.baseURL)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("To-do items") { Text("\(canvas.items.count) (\(canvas.dueSoon) due this week)").foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh now") { Task { await canvas.refresh() } }
                    Spacer()
                    Button("Disconnect", role: .destructive) { canvas.disconnect(); token = "" }
                }
            } else {
                TextField("School's Canvas address", text: $url, prompt: Text("e.g. myschool.instructure.com"))
                SecureField("Access token", text: $token, prompt: Text("Paste your token"))
                HStack {
                    Button("Connect") { Task { await canvas.connect(url: url, token: token); if canvas.connected { token = "" } } }
                        .disabled(canvas.loading)
                    if canvas.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("How do I get a token?") { CanvasGuide.show() }
                }
            }
            if let s = canvas.status { Text(s).font(.caption).foregroundStyle(.orange) }
            Text("Your token is stored in the macOS Keychain and only sent to your school's Canvas. Add the Canvas To-Do box on Home, or the Canvas widget.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Canvas") }
    }
}
