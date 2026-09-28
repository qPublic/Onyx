import AppKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - Two-way sync between Onyx notes and an "Onyx" folder in Apple Notes (Apple events, via osascript)

/// A synced note's twin in Apple Notes, and what both sides looked like at the last sync.
struct AppleLink: Codable, Hashable {
    var id: String
    var onyxHash: String
    var appleHash: String
    var folder: String
    var rich = false     // has formatting, pictures or tables Onyx can't show, so it's read-only in Onyx
}

/// A note in the Apple Notes "Onyx" folder, as the fetch script reports it.
struct AppleNote: Decodable, Equatable {
    var id: String
    var folder: String   // "" = the "Onyx" folder itself (Onyx's "Notes" folder), else its subfolder
    var text: String
    var html: String
    var attachments: Int
    var locked: Bool
    var rich: Bool { attachments > 0 || NotesSync.hasFormatting(html) }
}

final class NotesSync: ObservableObject {
    static let shared = NotesSync()
    static let key = "notes.appleSync"
    static var folderName: String { ProcessInfo.processInfo.environment["ONYX_NOTESYNC_FOLDER"] ?? "Onyx" }

    enum Status: Equatable {
        case off, syncing
        case synced(Date)
        case failed(String)
        case needsPermission
        case paused(String)   // a safety stop: the Apple Notes side looks wiped, so nothing was deleted
    }
    @Published private(set) var status: Status = .off

    var enabled: Bool { Prefs.bool(Self.key) }
    private var timer: Timer?
    private var running = false, again = false, applying = false
    private var editWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    private var lastRun = Date.distantPast
    private var paused: Bool { if case .paused = status { return true }; return false }

    // Notes deleted in Onyx, waiting to be deleted in Apple Notes: Apple id → its text fingerprint at the last sync.
    private var pendingDeletes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "notes.appleDeletes") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "notes.appleDeletes") }
    }

    func start() {
        // Your edits sync a few seconds after you stop typing.
        NotesStore.shared.$notes.dropFirst().sink { [weak self] _ in self?.noteChanged() }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }.tolerant()
        if enabled { status = .synced(.distantPast); DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.syncNow() } }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if on { syncNow() } else { status = .off }
    }

    /// Every 30s while Notes is open (that's when edits from your other devices arrive); every 15 min otherwise.
    private func tick() {
        guard enabled, !paused else { return }
        let notesOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
        if notesOpen || Date().timeIntervalSince(lastRun) > 15 * 60 { syncNow() }
    }

    private func noteChanged() {
        guard enabled, !applying, !paused else { return }
        editWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncNow() }
        editWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// An Onyx note was deleted: its Apple Notes twin goes to Apple Notes' Recently Deleted on the next sync.
    func noteDeleted(_ link: AppleLink) {
        pendingDeletes[link.id] = link.appleHash
    }

    /// After a safety stop: forget every link and upload the Onyx notes again (nothing is deleted anywhere).
    func relinkAll() {
        for n in NotesStore.shared.notes where n.apple != nil { NotesStore.shared.update(n.id) { $0.apple = nil } }
        pendingDeletes = [:]
        status = .synced(.distantPast)
        syncNow()
    }

    func syncNow() {
        guard enabled else { status = .off; return }
        if running { again = true; return }
        running = true
        lastRun = Date()
        if !paused { status = .syncing }
        let snapshot = NotesStore.shared.notes, deletes = pendingDeletes
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result = await self.run(snapshot, deletes)
            await MainActor.run { self.finish(result, snapshot: snapshot) }
        }
    }

    // MARK: One sync

    private enum Result {
        case done(Plan, [OpResult])
        case failed(String)
        case needsPermission
        case paused(String)
    }
    struct OpResult: Decodable { var ok: Bool; var id: String?; var text: String?; var error: String? }

    private func run(_ onyx: [Note], _ deletes: [String: String]) async -> Result {
        guard await Self.launchNotesHidden() else { return .failed("Couldn't open Apple Notes") }
        let fetched = await Self.script(Self.fetchJS, [Self.folderName])
        if let r = Self.problem(fetched) { return r }
        guard let data = fetched.output.data(using: .utf8),
              let apple = try? JSONDecoder().decode(Fetched.self, from: data) else { return .failed("Apple Notes gave an unexpected answer") }
        let plan = Self.plan(onyx: onyx, apple: apple.exists ? apple.notes : nil, deletes: deletes)
        if let why = plan.pause { return .paused(why) }
        guard !plan.ops.isEmpty else { return .done(plan, []) }
        // The changes go through a file, so long notes never hit the command-line length limit.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? JSONEncoder().encode(plan.ops).write(to: file)) != nil else { return .failed("Couldn't prepare the changes") }
        let applied = await Self.script(Self.applyJS, [Self.folderName, file.path])
        if let r = Self.problem(applied) { return r }
        guard let d = applied.output.data(using: .utf8), let results = try? JSONDecoder().decode([OpResult].self, from: d),
              results.count == plan.ops.count else { return .failed("Apple Notes gave an unexpected answer") }
        return .done(plan, results)
    }

    private struct Fetched: Decodable { var exists: Bool; var notes: [AppleNote] }

    private static func problem(_ r: (status: Int32, output: String)) -> Result? {
        guard r.status != 0 else { return nil }
        if r.output.contains("-1743") || r.output.contains("Not authorized") { return .needsPermission }
        return .failed("Apple Notes didn't respond. Try again in a moment.")
    }

    /// Applies what happened in Apple Notes to Onyx, on the main thread. Anything you typed while the sync ran wins
    /// over what came from Apple Notes this round; the next sync sorts it out.
    private func finish(_ result: Result, snapshot: [Note]) {
        running = false
        switch result {
        case .failed(let why): status = .failed(why)
        case .needsPermission: status = .needsPermission
        case .paused(let why): status = .paused(why)
        case .done(let plan, let results):
            applying = true
            let store = NotesStore.shared
            let before = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func untouched(_ id: UUID) -> Bool { store.notes.first { $0.id == id }?.body == before[id]?.body }

            for (op, r) in zip(plan.ops, results) {
                switch op {
                case .create(let onyxID, let folder, _, let body):
                    guard r.ok, let id = r.id else { continue }
                    store.update(onyxID) { $0.apple = AppleLink(id: id, onyxHash: Self.hash(body), appleHash: Self.hash(Self.clean(r.text ?? "")), folder: folder) }
                case .update(let appleID, let onyxID, _, let body):
                    guard r.ok else { continue }
                    store.update(onyxID) { n in
                        guard n.apple?.id == appleID else { return }
                        n.apple?.onyxHash = Self.hash(body)
                        n.apple?.appleHash = Self.hash(Self.clean(r.text ?? ""))
                    }
                case .move(let appleID, let onyxID, let folder):
                    guard r.ok else { continue }
                    store.update(onyxID) { n in if n.apple?.id == appleID { n.apple?.folder = folder } }
                case .delete(let appleID):
                    // Done, or already gone: either way it's no longer pending.
                    if r.ok || (r.error ?? "").contains("-1728") { pendingDeletes[appleID] = nil }
                }
            }
            for id in plan.dropDeletes { pendingDeletes[id] = nil }
            for (onyxID, a) in plan.links {
                guard let body = before[onyxID]?.body else { continue }
                store.update(onyxID) { $0.apple = AppleLink(id: a.id, onyxHash: Self.hash(body), appleHash: Self.hash(Self.clean(a.text)), folder: a.folder, rich: a.rich) }
            }
            var pulled = Set<UUID>()
            for (onyxID, a) in plan.pulls where untouched(onyxID) {
                pulled.insert(onyxID)
                store.update(onyxID) { n in
                    guard var link = n.apple else { return }
                    let text = Self.clean(a.text)
                    if n.body != text { n.body = text; n.updated = Date() }
                    if a.folder != before[onyxID]?.apple?.folder { n.folder = Self.onyxFolder(a.folder); link.folder = a.folder }
                    link.onyxHash = Self.hash(text); link.appleHash = Self.hash(text); link.rich = a.rich
                    n.apple = link
                }
            }
            for (onyxID, folder) in plan.refolders {
                store.update(onyxID) { n in n.folder = Self.onyxFolder(folder); n.apple?.folder = folder }
            }
            for onyxID in plan.conflicts where pulled.contains(onyxID) {
                // Both sides changed: Apple's version is in the note now, and Onyx's is kept as its own note (it uploads next time).
                if let old = before[onyxID] {
                    var copy = Note(body: old.body, folder: old.folder)
                    copy.updated = Date()
                    store.notes.insert(copy, at: 0)
                }
            }
            for onyxID in plan.unlinks { store.update(onyxID) { $0.apple = nil } }
            for a in plan.imports {
                let text = Self.clean(a.text)
                var n = Note(body: text, folder: Self.onyxFolder(a.folder))
                n.apple = AppleLink(id: a.id, onyxHash: Self.hash(text), appleHash: Self.hash(text), folder: a.folder, rich: a.rich)
                store.notes.insert(n, at: 0)
            }
            for onyxID in plan.removals where untouched(onyxID) {
                if let n = store.notes.first(where: { $0.id == onyxID }) { Self.backUp(n) }
                store.notes.removeAll { $0.id == onyxID }
            }
            applying = false
            status = .synced(Date())
        }
        if again { again = false; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.syncNow() } }
    }

    /// Notes removed because they were deleted in Apple Notes are also kept in notes-removed.json, just in case.
    private static func backUp(_ n: Note) {
        let file = Prefs.supportDir.appendingPathComponent("notes-removed.json")
        var all = (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: file))) ?? []
        all.append(n)
        if let d = try? JSONEncoder().encode(Array(all.suffix(200))) { try? d.write(to: file, options: .atomic) }
    }

    // MARK: Planning (pure, so it can be tested without Apple Notes)

    enum Op: Encodable {
        case create(onyx: UUID, folder: String, html: String, body: String)
        case update(id: String, onyx: UUID, html: String, body: String)
        case move(id: String, onyx: UUID, folder: String)
        case delete(id: String)

        private enum K: String, CodingKey { case op, id, folder, html }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: K.self)
            switch self {
            case .create(_, let f, let h, _): try c.encode("create", forKey: .op); try c.encode(f, forKey: .folder); try c.encode(h, forKey: .html)
            case .update(let id, _, let h, _): try c.encode("update", forKey: .op); try c.encode(id, forKey: .id); try c.encode(h, forKey: .html)
            case .move(let id, _, let f): try c.encode("move", forKey: .op); try c.encode(id, forKey: .id); try c.encode(f, forKey: .folder)
            case .delete(let id): try c.encode("delete", forKey: .op); try c.encode(id, forKey: .id)
            }
        }
    }

    struct Plan {
        var ops: [Op] = []
        var pulls: [(UUID, AppleNote)] = []
        var links: [(UUID, AppleNote)] = []
        var imports: [AppleNote] = []
        var refolders: [(UUID, String)] = []
        var unlinks: [UUID] = []
        var removals: [UUID] = []
        var conflicts: [UUID] = []
        var dropDeletes: [String] = []
        var pause: String?
    }

    /// Decides what to do. `apple` is nil when the Apple Notes "Onyx" folder doesn't exist.
    static func plan(onyx: [Note], apple: [AppleNote]?, deletes: [String: String]) -> Plan {
        var p = Plan()
        let appleByID = Dictionary((apple ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let linked = onyx.filter { $0.apple != nil }
        let missing = linked.filter { appleByID[$0.apple!.id] == nil }

        // Safety stop: if the folder vanished or most synced notes disappeared at once, delete nothing.
        if !linked.isEmpty && (apple == nil || (missing.count >= 3 && missing.count * 2 > linked.count)) {
            p.pause = apple == nil
                ? "The \"\(folderName)\" folder is missing from Apple Notes, so syncing is paused and nothing was deleted."
                : "Most synced notes are missing from Apple Notes, so syncing is paused and nothing was deleted."
            return p
        }

        var claimed = Set(linked.compactMap { $0.apple?.id })
        for n in onyx {
            guard let link = n.apple else { continue }
            let onyxChanged = hash(n.body) != link.onyxHash
            guard let a = appleByID[link.id] else {
                // Deleted in Apple Notes. If you've edited it in Onyx since, keep it and upload it again instead.
                if onyxChanged { p.unlinks.append(n.id) } else { p.removals.append(n.id) }
                continue
            }
            if a.locked { continue }
            let appleChanged = hash(clean(a.text)) != link.appleHash
            var pulling = false
            if a.rich || link.rich {
                // Read-only in Onyx: Apple Notes' version always wins.
                if appleChanged || onyxChanged || a.rich != link.rich { p.pulls.append((n.id, a)); pulling = true }
            } else {
                switch (onyxChanged, appleChanged) {
                case (true, false): p.ops.append(.update(id: a.id, onyx: n.id, html: html(n.body), body: n.body))
                case (false, true): p.pulls.append((n.id, a)); pulling = true
                case (true, true):
                    if clean(n.body) == clean(a.text) { p.links.append((n.id, a)) }
                    else { p.pulls.append((n.id, a)); p.conflicts.append(n.id); pulling = true }
                case (false, false): break
                }
            }
            // Moved to another folder: whichever side moved wins (Apple Notes if both did).
            if a.folder != link.folder {
                if !pulling { p.refolders.append((n.id, a.folder)) }
            } else if appleFolder(n.folder) != link.folder {
                p.ops.append(.move(id: a.id, onyx: n.id, folder: appleFolder(n.folder)))
            }
        }

        // Deleted in Onyx → delete in Apple Notes, unless it was edited there since (then it comes back as a new note).
        for (id, h) in deletes {
            if let a = appleByID[id] {
                if hash(clean(a.text)) == h, !a.locked { p.ops.append(.delete(id: id)); claimed.insert(id) } else { p.dropDeletes.append(id) }
            } else {
                p.dropDeletes.append(id)
            }
        }

        // New on the Onyx side: link to an identical unlinked Apple note (e.g. after reinstalling), else create it.
        var unclaimed = (apple ?? []).filter { !claimed.contains($0.id) && !$0.locked }
        for n in onyx where n.apple == nil {
            guard !n.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }   // don't upload a blank new note
            if let i = unclaimed.firstIndex(where: { clean($0.text) == clean(n.body) }) {
                p.links.append((n.id, unclaimed[i])); unclaimed.remove(at: i)
            } else {
                p.ops.append(.create(onyx: n.id, folder: appleFolder(n.folder), html: html(n.body), body: n.body))
            }
        }
        // New on the Apple Notes side (e.g. written on your iPhone). Blank ones wait until they have some text.
        p.imports = unclaimed.filter { !clean($0.text).isEmpty }
        return p
    }

    // MARK: Text

    static func onyxFolder(_ apple: String) -> String { apple.isEmpty ? "Notes" : apple }
    static func appleFolder(_ onyx: String) -> String { onyx == "Notes" ? "" : onyx }

    /// Apple Notes' plain text, tidied so it compares cleanly with Onyx's (line breaks, non-breaking spaces, trailing space).
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return t
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Onyx text → the simple HTML Apple Notes stores: one <div> per line.
    static func html(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            if line.isEmpty { return "<div><br></div>" }
            var l = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            l = l.replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;").replacingOccurrences(of: "  ", with: "&nbsp; ")
            if l.hasPrefix(" ") { l = "&nbsp;" + l.dropFirst() }
            return "<div>" + l + "</div>"
        }.joined()
    }

    /// Anything beyond plain lines (lists, checklists, tables, links, bold…) means the note was formatted in Apple Notes.
    static func hasFormatting(_ html: String) -> Bool {
        let tags = html.matches(of: #/<\s*/?\s*([a-zA-Z0-9]+)/#).map { $0.1.lowercased() }
        let plain: Set<String> = ["div", "br", "span", "p", "body", "html", "head", "meta", "h1"]
        return tags.contains { !plain.contains($0) }
    }

    // MARK: Apple Notes access

    fileprivate static func launchNotesHidden() async -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false; cfg.hides = true; cfg.addsToRecentItems = false
        guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)) != nil else { return false }
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    fileprivate static func script(_ js: String, _ args: [String]) async -> (status: Int32, output: String) {
        await Shell.read("/usr/bin/osascript", ["-l", "JavaScript", "-e", js] + args)
    }

    /// Lists every note in the "Onyx" folder and its subfolders (one level), as JSON.
    static let fetchJS = """
    function run(argv) {
      const Notes = Application('Notes');
      const roots = Notes.defaultAccount().folders.whose({name: argv[0]});
      if (roots.length === 0) return JSON.stringify({exists: false, notes: []});
      const root = roots[0], out = [];
      const grab = (folder, label) => {
        const notes = folder.notes, count = notes.length;
        if (count === 0) return;
        const ids = notes.id(), locked = notes.passwordProtected();
        for (let i = 0; i < count; i++) {
          if (locked[i]) { out.push({id: ids[i], folder: label, text: '', html: '', attachments: 0, locked: true}); continue; }
          const n = notes.byId(ids[i]);
          out.push({id: ids[i], folder: label, text: n.plaintext(), html: n.body(), attachments: n.attachments.length, locked: false});
        }
      };
      grab(root, '');
      const subs = root.folders, names = subs.name();
      for (let i = 0; i < names.length; i++) grab(subs.byName(names[i]), names[i]);
      return JSON.stringify({exists: true, notes: out});
    }
    """

    /// Creates, updates, moves and deletes notes from a JSON list of changes, creating folders as needed.
    static let applyJS = """
    ObjC.import('Foundation');
    function run(argv) {
      const Notes = Application('Notes'), acct = Notes.defaultAccount(), name = argv[0];
      const ops = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[1], $.NSUTF8StringEncoding, null).js);
      const findRoot = () => { const r = acct.folders.whose({name: name}); return r.length ? r[0] : null; };
      let root = findRoot();
      if (!root) { acct.folders.push(Notes.Folder({name: name})); root = findRoot(); }
      const folderFor = (label) => {
        if (!label) return root;
        const f = root.folders.whose({name: label});
        if (f.length) return f[0];
        root.folders.push(Notes.Folder({name: label}));
        return root.folders.whose({name: label})[0];
      };
      return JSON.stringify(ops.map(op => {
        try {
          if (op.op === 'create') {
            const f = folderFor(op.folder), n = Notes.Note({body: op.html});
            f.notes.push(n);
            return {ok: true, id: n.id(), text: n.plaintext()};
          }
          const n = Notes.notes.byId(op.id);
          if (op.op === 'update') { n.body = op.html; return {ok: true, id: op.id, text: n.plaintext()}; }
          if (op.op === 'move') { Notes.move(n, {to: folderFor(op.folder)}); return {ok: true, id: op.id}; }
          if (op.op === 'delete') { Notes.delete(n); return {ok: true, id: op.id}; }
          return {ok: false, error: 'unknown change'};
        } catch (e) { return {ok: false, error: String(e)}; }
      }));
    }
    """
}

extension NotesSync {
    /// Shows a note in Apple Notes.
    static func open(_ id: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
        Task.detached { _ = await script("function run(argv) { const N = Application('Notes'); N.activate(); N.notes.byId(argv[0]).show(); }", [id]) }
    }

    var statusText: String {
        switch status {
        case .off: "Off"
        case .syncing: "Syncing…"
        case .synced(let d): d == .distantPast ? "Waiting to sync" : "Synced \(d.formatted(.relative(presentation: .named)))"
        case .failed(let why): why
        case .needsPermission: "Onyx needs permission to control Notes"
        case .paused(let why): why
        }
    }
}

/// The little sync indicator next to the Notes folder menu.
struct NotesSyncBadge: View {
    let status: NotesSync.Status
    var body: some View {
        Group {
            switch status {
            case .syncing: ProgressView().controlSize(.mini)
            case .failed, .needsPermission, .paused: Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
            default: Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .help("Apple Notes: " + NotesSync.shared.statusText)
    }
}

/// Settings › Widgets & Tabs › Notes.
struct NotesSyncSettings: View {
    @AppStorage(NotesSync.key) private var on = false
    @ObservedObject var sync = NotesSync.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sync with Apple Notes", isOn: Binding(get: { on }, set: { sync.setEnabled($0) }))
                Text("Keeps your Onyx notes in an \"\(NotesSync.folderName)\" folder in Apple Notes, so they're on your iPhone and iPad too, and edits on either side show up on the other. Your other Apple notes aren't touched. Notes with checklists, pictures or other formatting are read-only in Onyx.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if on {
                HStack(spacing: 8) {
                    Text(sync.statusText).font(.caption)
                        .foregroundStyle({ if case .synced = sync.status { return Color.secondary }; if case .syncing = sync.status { return Color.secondary }; return Color.orange }())
                    Spacer()
                    switch sync.status {
                    case .needsPermission:
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    case .paused:
                        Button("Upload Onyx Notes Again") { sync.relinkAll() }
                    default:
                        Button("Sync Now") { sync.syncNow() }.disabled(sync.status == .syncing)
                    }
                }
            }
        } header: { Text("Notes") }
    }
}

// MARK: - Self-test (debug): ONYX_NOTESYNC_SELFTEST=<file> checks the sync decisions offline, then quits.

enum NotesSyncSelfTest {
    static func run(_ path: String) {
        typealias S = NotesSync
        var out: [String] = [], fails = 0
        func check(_ name: String, _ ok: Bool) { out.append((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func linked(_ body: String, _ id: String, folder: String = "Notes", appleText: String? = nil, rich: Bool = false) -> Note {
            var n = Note(body: body, folder: folder)
            n.apple = AppleLink(id: id, onyxHash: S.hash(body), appleHash: S.hash(S.clean(appleText ?? body)), folder: S.appleFolder(folder), rich: rich)
            return n
        }
        func apple(_ id: String, _ text: String, folder: String = "", html: String? = nil, attachments: Int = 0, locked: Bool = false) -> AppleNote {
            AppleNote(id: id, folder: folder, text: text, html: html ?? S.html(text), attachments: attachments, locked: locked)
        }
        func ops(_ p: S.Plan) -> [String] {
            p.ops.map { op -> String in
                switch op {
                case .create(_, let f, _, let b): "create[\(f)]:\(b.prefix(12))"
                case .update(let id, _, _, _): "update:\(id)"
                case .move(let id, _, let f): "move:\(id)->\(f)"
                case .delete(let id): "delete:\(id)"
                }
            }
        }

        // 1. First sync: folder missing, blank notes wait.
        var p = S.plan(onyx: [Note(body: "Groceries\nmilk"), Note(body: "  \n"), Note(body: "Essay", folder: "School")], apple: nil, deletes: [:])
        check("first sync creates non-blank notes in the right folders", ops(p) == ["create[]:Groceries\nmi", "create[School]:Essay"] && p.pause == nil)

        // 2–6. Edits.
        let a = linked("Title\nold", "A")
        p = S.plan(onyx: [a], apple: [apple("A", "Title\nold")], deletes: [:])
        check("nothing changed → nothing to do", p.ops.isEmpty && p.pulls.isEmpty && p.imports.isEmpty)
        var e = a; e.body = "Title\nnew"
        p = S.plan(onyx: [e], apple: [apple("A", "Title\nold")], deletes: [:])
        check("edited in Onyx → update Apple", ops(p) == ["update:A"] && p.pulls.isEmpty)
        p = S.plan(onyx: [a], apple: [apple("A", "Title\nfrom phone")], deletes: [:])
        check("edited in Apple Notes → pull", p.ops.isEmpty && p.pulls.map(\.0) == [a.id])
        p = S.plan(onyx: [e], apple: [apple("A", "Title\nfrom phone")], deletes: [:])
        check("edited on both sides → pull + keep Onyx copy", p.pulls.map(\.0) == [e.id] && p.conflicts == [e.id] && p.ops.isEmpty)
        p = S.plan(onyx: [e], apple: [apple("A", "Title\nnew\u{00A0}\r\n")], deletes: [:])
        check("same edit on both sides → just relink", p.links.map(\.0) == [e.id] && p.conflicts.isEmpty && p.ops.isEmpty)

        // 7–8. Deleted in Apple Notes, and the safety stop.
        let b = linked("B", "B"), c = linked("C", "C"), d = linked("D", "D")
        p = S.plan(onyx: [a, b, c, d], apple: [apple("A", "Title\nold"), apple("B", "B"), apple("C", "C")], deletes: [:])
        check("deleted in Apple Notes → removed from Onyx", p.removals == [d.id] && p.pause == nil)
        var d2 = d; d2.body = "D edited"
        p = S.plan(onyx: [a, b, c, d2], apple: [apple("A", "Title\nold"), apple("B", "B"), apple("C", "C")], deletes: [:])
        check("deleted in Apple Notes but edited in Onyx → unlink and re-upload", p.unlinks == [d2.id] && p.removals.isEmpty)
        p = S.plan(onyx: [a, b, c, d], apple: [apple("A", "Title\nold")], deletes: [:])
        check("most notes missing at once → pause, delete nothing", p.pause != nil && p.removals.isEmpty && p.ops.isEmpty)
        p = S.plan(onyx: [a, b], apple: nil, deletes: [:])
        check("folder missing with synced notes → pause", p.pause != nil && p.ops.isEmpty)

        // 9. Deleted in Onyx.
        p = S.plan(onyx: [], apple: [apple("X", "Gone")], deletes: ["X": S.hash("Gone")])
        check("deleted in Onyx → delete in Apple Notes", ops(p) == ["delete:X"] && p.imports.isEmpty)
        p = S.plan(onyx: [], apple: [apple("X", "Gone but edited on phone")], deletes: ["X": S.hash("Gone")])
        check("deleted in Onyx but edited on phone → kept and re-imported", p.ops.isEmpty && p.dropDeletes == ["X"] && p.imports.map(\.id) == ["X"])

        // 10. New in Apple Notes.
        p = S.plan(onyx: [], apple: [apple("N", "From iPhone", folder: "School"), apple("E", "")], deletes: [:])
        check("new in Apple Notes → import (blank ones wait)", p.imports.map(\.id) == ["N"])

        // 11. Folder moves.
        var m = a; m.folder = "School"
        p = S.plan(onyx: [m], apple: [apple("A", "Title\nold")], deletes: [:])
        check("moved in Onyx → move in Apple Notes", ops(p) == ["move:A->School"])
        p = S.plan(onyx: [a], apple: [apple("A", "Title\nold", folder: "Work")], deletes: [:])
        check("moved in Apple Notes → move in Onyx", p.refolders.map(\.1) == ["Work"] && p.ops.isEmpty)

        // 12. Formatted notes are read-only in Onyx.
        let r = linked("List\n• one", "R", rich: true)
        var r2 = r; r2.body = "List\n• one\nedited in onyx"
        p = S.plan(onyx: [r2], apple: [apple("R", "List\n• one", html: "<div>List</div><ul><li>one</li></ul>")], deletes: [:])
        check("formatted note never overwritten from Onyx", p.ops.isEmpty && p.pulls.map(\.0) == [r2.id])
        p = S.plan(onyx: [a], apple: [apple("A", "Title\nold", html: "<div>Title</div><div><b>old</b></div>")], deletes: [:])
        check("formatting added on the phone → becomes read-only (pulled)", p.pulls.map(\.0) == [a.id] && p.ops.isEmpty)

        // 13–14. Duplicates and locked notes.
        p = S.plan(onyx: [Note(body: "Same text")], apple: [apple("S", "Same text")], deletes: [:])
        check("identical unlinked notes → linked, not duplicated", p.links.count == 1 && p.ops.isEmpty && p.imports.isEmpty)
        p = S.plan(onyx: [a], apple: [apple("A", "", locked: true), apple("L", "", locked: true)], deletes: [:])
        check("locked notes are left alone", p.ops.isEmpty && p.pulls.isEmpty && p.imports.isEmpty && p.removals.isEmpty)

        // 15–16. Text helpers.
        check("html escapes and keeps blank lines", S.html("a<b>&\n\nc") == "<div>a&lt;b&gt;&amp;</div><div><br></div><div>c</div>")
        check("plain Onyx HTML isn't 'formatted'", !S.hasFormatting(S.html("x\n\ny")) && !S.hasFormatting("<div><span style=\"x\">t</span><br></div>"))
        check("lists, checklists, tables, links, bold are 'formatted'", ["<ul><li>x</li></ul>", "<table></table>", "<a href=\"x\">l</a>", "<b>x</b>", "<img src=\"x\">"].allSatisfy(S.hasFormatting))
        check("clean normalizes line endings and spaces", S.clean("a\r\nb\u{2028}c\u{00A0}d  \n\n") == "a\nb\nc d")

        out.append(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Live test (debug): ONYX_NOTESYNC_LIVETEST=<file> with ONYX_NOTES_FILE and ONYX_NOTESYNC_FOLDER set to test values.
// Round-trips notes through a throwaway Apple Notes folder, logs each step, then deletes that folder and quits.

enum NotesSyncLiveTest {
    @MainActor static func run(_ path: String) async {
        typealias S = NotesSync
        let folder = S.folderName, store = NotesStore.shared, sync = S.shared
        var log: [String] = [], fails = 0
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool) { note((ok ? "PASS " : "FAIL ") + name); if !ok { fails += 1 } }
        func settle() async {
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<120 { if sync.status != .syncing { break }; try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<60 { if sync.status != .syncing { break }; try? await Task.sleep(for: .milliseconds(500)) }
        }
        func apple() async -> [AppleNote] {
            let r = await S.script(S.fetchJS, [folder])
            struct F: Decodable { var exists: Bool; var notes: [AppleNote] }
            return (try? JSONDecoder().decode(F.self, from: Data(r.output.utf8)))?.notes ?? []
        }
        func applyOps(_ json: String) async -> String {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-livetest.json")
            try? json.write(to: f, atomically: true, encoding: .utf8)
            return await S.script(S.applyJS, [folder, f.path]).output
        }
        guard folder != "Onyx", ProcessInfo.processInfo.environment["ONYX_NOTES_FILE"] != nil, sync.enabled else {
            note("Refusing to run: set ONYX_NOTES_FILE, a test ONYX_NOTESYNC_FOLDER and -notes.appleSync YES."); exit(1)
        }
        store.notes = [Note(body: "Onyx sync test\nhello from Onyx"), Note(body: "School test\n  indented & <escaped>", folder: "School")]
        sync.syncNow()   // launched with -notes.appleSync YES, so your real setting is never written
        await settle()
        note("status after first sync: \(sync.statusText)")
        if sync.status == .needsPermission { note("No permission to control Notes."); exit(1) }

        var a = await apple()
        check("both notes created in Apple Notes", a.count == 2)
        check("folders mapped (root + School)", Set(a.map(\.folder)) == ["", "School"])
        check("text round-trips exactly", Set(a.map { S.clean($0.text) }) == Set(store.notes.map(\.body)))
        check("our own notes don't count as formatted", a.allSatisfy { !$0.rich })
        note("HTML Apple Notes stored: " + (a.first?.html ?? "").prefix(300))
        check("Onyx notes linked", store.notes.allSatisfy { $0.apple != nil })

        // Edit in Onyx → Apple.
        let first = store.notes.first { $0.folder == "Notes" }!.id
        store.update(first) { $0.body = "Onyx sync test\nedited in Onyx" }
        sync.syncNow(); await settle()
        a = await apple()
        check("Onyx edit reached Apple Notes", a.contains { S.clean($0.text) == "Onyx sync test\nedited in Onyx" })

        // Edit in Apple Notes → Onyx.
        let appleID = store.notes.first { $0.id == first }!.apple!.id
        _ = await applyOps("[{\"op\":\"update\",\"id\":\"\(appleID)\",\"html\":\"<div>Onyx sync test</div><div>edited on the phone</div>\"}]")
        sync.syncNow(); await settle()
        check("Apple Notes edit reached Onyx", store.notes.first { $0.id == first }?.body == "Onyx sync test\nedited on the phone")

        // New in Apple Notes → Onyx.
        _ = await applyOps("[{\"op\":\"create\",\"folder\":\"School\",\"html\":\"<div>Made on iPhone</div><div>imported?</div>\"}]")
        sync.syncNow(); await settle()
        check("new Apple note imported into the School folder", store.notes.contains { $0.body == "Made on iPhone\nimported?" && $0.folder == "School" })

        // Move in Onyx → Apple.
        store.update(first) { $0.folder = "Work" }
        sync.syncNow(); await settle()
        a = await apple()
        check("folder move reached Apple Notes", a.contains { $0.id == appleID && $0.folder == "Work" })

        // Delete in Onyx → Apple.
        store.delete(first)
        sync.syncNow(); await settle()
        a = await apple()
        check("Onyx delete reached Apple Notes", !a.contains { $0.id == appleID })
        check("nothing unexpected left", a.count == 2 && store.notes.count == 2)
        note("final status: \(sync.statusText)")

        // Clean up: the whole test folder goes to Apple Notes' Recently Deleted.
        let js = "function run(argv) { const N = Application('Notes'); const r = N.defaultAccount().folders.whose({name: argv[0]}); if (r.length) N.delete(r[0]); return 'ok'; }"
        let cleaned = await S.script(js, [folder])
        note("cleanup: \(cleaned.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        UserDefaults.standard.removeObject(forKey: "notes.appleDeletes")
        note(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
        exit(0)
    }
}
