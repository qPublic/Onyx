import AppKit
import SwiftUI

// MARK: - Settings backup & sync: export/import a file, or keep your Macs in sync through iCloud Drive

final class SettingsSync: ObservableObject {
    static let shared = SettingsSync()
    static let key = "settings.iCloudSync"

    enum Status: Equatable { case off, synced(Date), noICloud, failed(String) }
    @Published private(set) var status: Status = .off
    /// Turning sync on when iCloud Drive already has another Mac's settings: which ones win is your call.
    @Published var conflict: Snapshot?

    struct Snapshot: Equatable {
        var machineID: String, machine: String, app: String, updated: Date
        var settings: NSDictionary
    }

    // Swappable for the self-test, so it never touches your real settings or iCloud Drive.
    var defaults = UserDefaults.standard
    var domain = Bundle.main.bundleIdentifier ?? "local.onyx.notch"
    var folder: URL = ProcessInfo.processInfo.environment["ONYX_SETTINGS_SYNC_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Onyx")
    var file: URL { folder.appendingPathComponent("Settings.plist") }
    /// This Mac's copy of the settings as of the last sync, so a pull can tell which side changed.
    var stateFile = Prefs.supportDir.appendingPathComponent("settings-synced.plist")

    private var timer: Timer?
    private var pushWork: DispatchWorkItem?
    private var applying = false
    private var localEdit = Date.distantPast
    private var lastSynced: NSDictionary? {
        get { NSDictionary(contentsOf: stateFile) }
        set { if let newValue { newValue.write(to: stateFile, atomically: true) } else { try? FileManager.default.removeItem(at: stateFile) } }
    }

    var enabled: Bool { defaults.bool(forKey: Self.key) }
    private var machineID: String {
        if let id = defaults.string(forKey: "settings.machineID") { return id }
        let id = UUID().uuidString; defaults.set(id, forKey: "settings.machineID"); return id
    }

    // MARK: What syncs

    /// Things that belong to this Mac (or aren't settings at all) never leave it: onboarding and permission state, the
    /// Shelf's files, notes, update and sync bookkeeping, which display to use. Passwords are in the Keychain, never here.
    static let localKeys: Set<String> = ["didOnboard", "didAskAX", "notes", "shelfItems", "toolsSelection", "ap.display", "ap.userHidden"]
    static let localPrefixes = ["notes.", "update.", "settings.", "rain.", "spotlight.", "opt.page", "opt.last", "NS", "Apple", "com.apple.", "AK", "WebKit"]
    static func syncable(_ k: String) -> Bool { !localKeys.contains(k) && !localPrefixes.contains { k.hasPrefix($0) } }

    func current() -> NSDictionary {
        let all = defaults.persistentDomain(forName: domain) ?? [:]
        return all.filter { Self.syncable($0.key) } as NSDictionary
    }

    /// Makes this Mac's settings match: keys missing from `s` go back to their defaults.
    func apply(_ s: NSDictionary) {
        applying = true
        let incoming = (s as? [String: Any] ?? [:]).filter { Self.syncable($0.key) }
        for k in (current() as? [String: Any] ?? [:]).keys where incoming[k] == nil { defaults.removeObject(forKey: k) }
        for (k, v) in incoming { defaults.set(v, forKey: k) }
        lastSynced = current()
        applying = false
        guard defaults == UserDefaults.standard else { return }
        // A few parts of Onyx read their settings once at launch.
        Shortcuts.reload()
        WidgetLayout.shared.reload()
        HomeLayout.shared.reload()
    }

    // MARK: Files

    func snapshotData() -> Data? {
        let d: NSDictionary = ["format": "Onyx Settings", "version": 1, "machineID": machineID, "machine": Host.current().localizedName ?? "Mac",
                               "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                               "updated": Date(), "updatedAt": Date().timeIntervalSince1970, "settings": current()]
        return try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    static func read(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              d["format"] as? String == "Onyx Settings", let s = d["settings"] as? NSDictionary else { return nil }
        return Snapshot(machineID: d["machineID"] as? String ?? "", machine: d["machine"] as? String ?? "another Mac",
                        app: d["app"] as? String ?? "",
                        updated: (d["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? d["updated"] as? Date ?? .distantPast, settings: s)
    }

    func exportFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Onyx Settings.plist"
        p.allowedContentTypes = [.propertyList]
        guard p.runModal() == .OK, let url = p.url, let data = snapshotData() else { return }
        do { try data.write(to: url, options: .atomic) } catch { alert("Couldn't save the settings", error.localizedDescription) }
    }

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.propertyList]
        guard p.runModal() == .OK, let url = p.url else { return }
        guard let snap = Self.read(url) else { alert("That isn't an Onyx settings file", "Choose a file made with Export Settings…."); return }
        let a = NSAlert()
        a.messageText = "Replace your Onyx settings?"
        a.informativeText = "These settings are from \(snap.machine), \(snap.updated.formatted(date: .abbreviated, time: .shortened)). Your notes, Shelf and permissions aren't affected."
        a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        apply(snap.settings)
        if enabled { pushNow() }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // MARK: iCloud Drive sync

    var iCloudDriveOn: Bool {
        ProcessInfo.processInfo.environment["ONYX_SETTINGS_SYNC_DIR"] != nil
            || FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }

    func start() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.localChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pull()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pull() }.tolerant()
        if enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.pull(first: true) } }
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.key)
        guard on else { status = .off; return }
        guard iCloudDriveOn else { status = .noICloud; return }
        pull(first: true)
    }

    /// Whichever side changed since the last sync wins (the newest if both did). The first sync on a Mac asks which
    /// settings to keep when iCloud Drive already has different ones from another Mac.
    func pull(first: Bool = false) {
        guard enabled else { return }
        guard iCloudDriveOn else { status = .noICloud; return }
        guard pushWork == nil else { return }   // your own change is about to be saved; don't overwrite it
        guard let snap = Self.read(file) else { pushNow(); return }
        let mine = current()
        if snap.settings.isEqual(mine) { lastSynced = mine; status = .synced(Date()); return }
        guard let base = lastSynced else {
            if snap.machineID != machineID { conflict = snap } else { pushNow() }
            return
        }
        let remoteChanged = !snap.settings.isEqual(base), localChanged = !mine.isEqual(base)
        if remoteChanged && (!localChanged || snap.updated > localEdit) {
            apply(snap.settings); status = .synced(Date())
        } else {
            pushNow()
        }
    }

    func resolve(useICloud: Bool) {
        guard let snap = conflict else { return }
        conflict = nil
        if useICloud { apply(snap.settings); status = .synced(Date()) } else { pushNow() }
    }

    private func localChanged() {
        guard enabled, !applying, conflict == nil else { return }
        localEdit = Date()
        pushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pushWork = nil; self?.pushIfChanged() }
        pushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func pushIfChanged() {
        let mine = current()
        if let last = lastSynced, mine.isEqual(last) { return }
        pushNow()
    }

    func pushNow() {
        guard enabled, iCloudDriveOn, let data = snapshotData() else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            lastSynced = current(); status = .synced(Date())
        } catch {
            status = .failed("Couldn't save to iCloud Drive: \(error.localizedDescription)")
        }
    }

    var statusText: String {
        switch status {
        case .off: "Off"
        case .synced(let d): "Synced \(d.formatted(.relative(presentation: .named)))"
        case .noICloud: "Turn on iCloud Drive in System Settings › your name › iCloud to sync."
        case .failed(let why): why
        }
    }
}

// MARK: - Settings › Behavior › Back up & sync

struct SettingsSyncSection: View {
    @ObservedObject var sync = SettingsSync.shared
    @AppStorage(SettingsSync.key) private var on = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sync settings between your Macs", isOn: Binding(get: { on }, set: { sync.setEnabled($0) }))
                Text("Keeps Onyx's settings the same on every Mac signed in to your iCloud account, through iCloud Drive. Notes, Shelf files and permissions stay on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if on { Text(sync.statusText).font(.caption).foregroundStyle(sync.status == .noICloud ? .orange : .secondary) }
            }
            HStack {
                Button("Export Settings…") { sync.exportFile() }
                Button("Import Settings…") { sync.importFile() }
            }
        } header: { Text("Back up & sync") }
        .confirmationDialog("iCloud Drive already has Onyx settings", isPresented: Binding(get: { sync.conflict != nil }, set: { if !$0 { sync.conflict = nil } })) {
            Button("Use the Settings from \(sync.conflict?.machine ?? "iCloud")") { sync.resolve(useICloud: true) }
            Button("Use This Mac's Settings") { sync.resolve(useICloud: false) }
            Button("Cancel", role: .cancel) { sync.conflict = nil; sync.setEnabled(false) }
        } message: {
            Text("They're from \(sync.conflict?.machine ?? "another Mac"), \(sync.conflict?.updated.formatted(date: .abbreviated, time: .shortened) ?? ""). Which settings should both Macs use?")
        }
    }
}
