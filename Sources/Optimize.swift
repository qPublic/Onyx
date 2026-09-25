import AppKit
import SwiftUI
import CoreServices

// MARK: - Optimization (OnyX-style): clean, maintain, tweak, startup, storage
//
// Rules: scan before changing anything, cleaning moves to the Trash (recoverable), admin tasks use
// macOS's own password prompt (Onyx never sees it), and nothing here weakens security.

enum Opt {
    static let page = "opt.page"
    static let lowDiskAlert = "opt.lowDiskAlert"
    static let autoClean = "opt.autoClean"
    static let lastClean = "opt.lastClean"            // Date
    static let lastCleanBytes = "opt.lastCleanBytes"  // Int64
    static let lastAutoClean = "opt.lastAutoClean"
    static let tweaked = "opt.tweaked"                // ["domain|key"] Onyx changed, for Reset all
    static let autoQuit = "opt.autoQuit"
    static let autoQuitMinutes = "opt.autoQuitMinutes"
    static let autoQuitKeep = "opt.autoQuitKeep"      // bundle IDs never auto-quit
    static let defaults: [String: Any] = [lowDiskAlert: true, autoClean: false, autoQuit: false, autoQuitMinutes: 10.0,
                                          autoQuitKeep: ["com.spotify.client", "com.apple.Music"]]
}

// MARK: Shell

enum Shell {
    /// ONYX_OPTIMIZE_DRYRUN=1 (or the self-test) logs every change instead of making it.
    static var dryRun: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ONYX_OPTIMIZE_DRYRUN"] != nil || env["ONYX_OPTIMIZE_TEST"] != nil
    }
    static var logFile: URL { Prefs.supportDir.appendingPathComponent("optimize-dryrun.log") }

    static func log(_ line: String) {
        let s = line + "\n"
        if let h = try? FileHandle(forWritingTo: logFile) { h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close() }
        else { try? s.write(to: logFile, atomically: true, encoding: .utf8) }
    }

    /// Read-only command: always runs. Off the main thread.
    static func read(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// A command that changes something (dry-run aware).
    static func run(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        if dryRun { log("run: \(path) \(args.joined(separator: " "))"); return (0, "(dry run)") }
        return await read(path, args)
    }

    /// Runs a shell command as administrator. macOS shows its own password window; Onyx never sees
    /// or stores the password. Cancelling returns status 1 with "User canceled".
    static func runAdmin(_ command: String) async -> (status: Int32, output: String) {
        if dryRun { log("admin: \(command)"); return (0, "(dry run)") }
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await read("/usr/bin/osascript", ["-e", "do shell script \"\(esc)\" with administrator privileges"])
    }

    /// Moves a file or folder to the Trash (recoverable).
    static func trash(_ u: URL) -> Bool {
        if dryRun { log("trash: \(u.path)"); return true }
        return (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil
    }

    static func emptyTrash() async -> Bool {
        await run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]).status == 0
    }
}

// MARK: System stats

enum Sys {
    static func disk() -> (free: Int64, total: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }

    /// Memory used the way Activity Monitor counts it (app + wired + compressed), and pressure (1 normal, 2 warn, 4 critical).
    static func memory() -> (used: UInt64, total: UInt64, pressure: Int) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var level: Int32 = 0; var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard kr == KERN_SUCCESS else { return (0, total, Int(level)) }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return ((app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page, total, Int(level))
    }

    /// Space a file or folder takes on disk.
    static func size(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        let key: URLResourceKey = .totalFileAllocatedSizeKey
        if !isDir.boolValue { return Int64((try? u.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [key], options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0) }
        return total
    }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

// MARK: - Clean

final class CleanModel: ObservableObject {
    static let shared = CleanModel()
    struct Category: Identifiable {
        let id: String, title: String, detail: String, icon: String
        var items: [(url: URL, bytes: Int64)] = []
        var selected: Bool
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }
    @Published var categories: [Category] = []
    @Published var busy = false
    @Published var result: String?

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let definitions: [(id: String, title: String, detail: String, icon: String, dir: String, selected: Bool)] = [
        ("caches", "App caches", "Temporary files apps rebuild when needed (browsers, Spotify, Slack…)", "shippingbox", "Library/Caches", true),
        ("logs", "Logs & crash reports", "Old diagnostic files apps have written", "doc.text", "Library/Logs", true),
        ("xcode", "Xcode build files", "DerivedData: Xcode rebuilds it on the next build", "hammer", "Library/Developer/Xcode/DerivedData", false),
        ("simulator", "Simulator caches", "iOS Simulator caches", "iphone", "Library/Developer/CoreSimulator/Caches", false),
    ]

    /// Apple's own caches (iCloud, downloads in progress, Maps, Wallet…) and Onyx's are left alone.
    private static let appleCaches: Set<String> = ["CloudKit", "GeoServices", "PassKit", "Animoji", "GameKit", "askpermissiond",
                                                   "FamilyCircle", "familycircled", "SiriTTS", "Metadata", "icloudmailagent", "storeassetd"]
    private static func skip(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("com.apple.") || appleCaches.contains(name) || name.hasPrefix("local.onyx")
    }

    var selectedBytes: Int64 { categories.filter(\.selected).reduce(0) { $0 + $1.bytes } }

    @MainActor func scan() async {
        busy = true; defer { busy = false }
        let previous = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.selected) })
        categories = await Task.detached { () -> [Category] in
            Self.definitions.compactMap { d in
                let dir = Self.home.appendingPathComponent(d.dir)
                guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
                let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                let items = kids.filter { !Self.skip($0.lastPathComponent) }.map { ($0, Sys.size($0)) }.filter { $0.1 > 0 }
                return Category(id: d.id, title: d.title, detail: d.detail, icon: d.icon, items: items, selected: previous[d.id] ?? d.selected)
            }
        }.value
    }

    /// Moves the selected categories to the Trash. Returns bytes moved.
    @MainActor @discardableResult func clean(onlyDefaults: Bool = false) async -> Int64 {
        busy = true; defer { busy = false }
        let defaultsOn = Set(Self.definitions.filter(\.selected).map(\.id))
        let chosen = categories.filter { onlyDefaults ? defaultsOn.contains($0.id) : $0.selected }
        let (moved, skipped) = await Task.detached { () -> (Int64, Int) in
            var moved: Int64 = 0, skipped = 0
            for c in chosen { for i in c.items { if Shell.trash(i.url) { moved += i.bytes } else { skipped += 1 } } }
            return (moved, skipped)
        }.value
        if !Shell.dryRun {
            UserDefaults.standard.set(Date(), forKey: Opt.lastClean)
            UserDefaults.standard.set(moved, forKey: Opt.lastCleanBytes)
        }
        result = "Moved \(Sys.bytes(moved)) to the Trash." + (skipped > 0 ? " \(skipped) item(s) were in use and skipped." : "")
            + " Empty the Trash to get the space back."
        await scan()
        return moved
    }

    @MainActor func quickOptimize() async {
        await scan()
        await clean(onlyDefaults: true)
    }
}

/// "Empty Trash…" with a confirmation (the one permanent delete, only on the user's click).
struct EmptyTrashButton: View {
    @State private var confirm = false
    @State private var done = false
    var body: some View {
        Button(done ? "Trash emptied" : "Empty Trash…") { confirm = true }
            .disabled(done)
            .alert("Empty the Trash?", isPresented: $confirm) {
                Button("Empty Trash", role: .destructive) { Task { done = await Shell.emptyTrash() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Everything in the Trash will be permanently deleted. macOS may ask to let Onyx control Finder.") }
    }
}

// MARK: - Maintain

struct MaintTask: Identifiable {
    let id: String, title: String, detail: String, icon: String
    let admin: Bool
    let command: String
}

final class MaintenanceModel: ObservableObject {
    static let shared = MaintenanceModel()
    @Published var running: String?
    @Published var results: [String: Bool] = [:]
    @Published var output: String?

    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let tasks: [MaintTask] = [
        MaintTask(id: "dns", title: "Flush DNS cache", detail: "Fixes websites that won't load after a network or DNS change.", icon: "network", admin: true,
                  command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        MaintTask(id: "purge", title: "Free up memory", detail: "Clears memory apps aren't using. Things may feel slower for a moment while caches refill.", icon: "memorychip", admin: true,
                  command: "purge"),
        MaintTask(id: "launchservices", title: "Rebuild the \"Open With\" menu", detail: "Removes duplicate or missing apps from Open With and fixes wrong default apps. Takes a minute.", icon: "list.bullet.rectangle", admin: false,
                  command: "\(lsregister) -gc -r -f -all local,system,user"),
        MaintTask(id: "spotlight", title: "Rebuild Spotlight index", detail: "Fixes Spotlight missing files. Re-indexing runs in the background and can take a while.", icon: "magnifyingglass", admin: true,
                  command: "mdutil -E /"),
        MaintTask(id: "quicklook", title: "Reset Quick Look", detail: "Fixes missing or wrong file previews and thumbnails.", icon: "eye", admin: false,
                  command: "qlmanage -r; qlmanage -r cache"),
        MaintTask(id: "fonts", title: "Clear font caches", detail: "Fixes garbled or missing fonts. Restart your Mac afterwards.", icon: "textformat", admin: false,
                  command: "atsutil databases -removeUser"),
        MaintTask(id: "finder", title: "Restart Finder", detail: "Fixes a stuck or slow Finder. Its windows reopen.", icon: "folder", admin: false,
                  command: "killall Finder"),
        MaintTask(id: "dock", title: "Restart Dock", detail: "Fixes a stuck Dock, Mission Control or Launchpad.", icon: "dock.rectangle", admin: false,
                  command: "killall Dock"),
        MaintTask(id: "menubar", title: "Restart menu bar", detail: "Fixes menu bar icons or Control Center acting up.", icon: "menubar.rectangle", admin: false,
                  command: "killall SystemUIServer ControlCenter"),
        MaintTask(id: "verify", title: "Check startup disk", detail: "Read-only check for disk errors, like Disk Utility's First Aid without repairing. Takes a few minutes.", icon: "internaldrive", admin: true,
                  command: "diskutil verifyVolume /"),
    ]

    func lastRun(_ t: MaintTask) -> Date? { UserDefaults.standard.object(forKey: "opt.last.\(t.id)") as? Date }

    @MainActor func run(_ t: MaintTask) async {
        running = t.id; defer { running = nil }
        let r = t.admin ? await Shell.runAdmin(t.command) : await Shell.run("/bin/sh", ["-c", t.command])
        if t.admin && r.output.contains("User canceled") { return }   // closed the password window: nothing happened
        results[t.id] = r.status == 0
        if !Shell.dryRun { UserDefaults.standard.set(Date(), forKey: "opt.last.\(t.id)") }
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        output = "\(t.title): " + (r.status == 0 ? "done" : "failed (\(r.status))") + (text.isEmpty ? "" : "\n\(text.suffix(1500))")
    }
}

// MARK: - Tweaks (hidden macOS settings via `defaults`)

/// One option of a choice tweak (nil value = the macOS default).
struct Choice {
    let label: String, value: Any?
    init(_ label: String, _ value: Any?) { self.label = label; self.value = value }
}

struct Tweak: Identifiable {
    enum Kind { case toggle(Any), choice([Choice]), folder }
    let group: String, title: String, domain: String, key: String, kind: Kind
    var note: String? = nil
    var restart: String? = nil          // process to restart for it to apply
    var id: String { "\(domain)|\(key)" }
}

final class TweaksModel: ObservableObject {
    static let shared = TweaksModel()
    @Published var version = 0                      // bumped after each change so rows re-read
    @Published var pendingRestart: Set<String> = []

    private static let nextApps = "Applies to apps you open next."
    private static let logout = "Log out and back in to apply."
    static let all: [Tweak] = [
        Tweak(group: "Finder", title: "Show hidden files", domain: "com.apple.finder", key: "AppleShowAllFiles", kind: .toggle(true as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "Show all file extensions", domain: "NSGlobalDomain", key: "AppleShowAllExtensions", kind: .toggle(true as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "Show path bar", domain: "com.apple.finder", key: "ShowPathbar", kind: .toggle(true as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "Show status bar", domain: "com.apple.finder", key: "ShowStatusBar", kind: .toggle(true as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "Keep folders on top", domain: "com.apple.finder", key: "_FXSortFoldersFirst", kind: .toggle(true as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "Don't warn when changing a file extension", domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", kind: .toggle(false as Bool), restart: "Finder"),
        Tweak(group: "Finder", title: "No .DS_Store files on network drives", domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", kind: .toggle(true as Bool), note: logout),
        Tweak(group: "Finder", title: "No .DS_Store files on USB drives", domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", kind: .toggle(true as Bool), note: logout),

        Tweak(group: "Dock", title: "Show a hidden Dock instantly", domain: "com.apple.dock", key: "autohide-delay", kind: .toggle(0.0 as Double),
              note: "Removes the pause before an auto-hidden Dock slides in.", restart: "Dock"),
        Tweak(group: "Dock", title: "Dock slide animation", domain: "com.apple.dock", key: "autohide-time-modifier",
              kind: .choice([Choice("Default", nil), Choice("Fast", 0.25 as Double), Choice("Instant", 0.0 as Double)]), restart: "Dock"),
        Tweak(group: "Dock", title: "Hide recent apps", domain: "com.apple.dock", key: "show-recents", kind: .toggle(false as Bool), restart: "Dock"),
        Tweak(group: "Dock", title: "Dim icons of hidden apps", domain: "com.apple.dock", key: "showhidden", kind: .toggle(true as Bool), restart: "Dock"),
        Tweak(group: "Dock", title: "Minimize effect", domain: "com.apple.dock", key: "mineffect", kind: .choice([Choice("Genie (default)", nil), Choice("Scale", "scale" as String)]), restart: "Dock"),
        Tweak(group: "Dock", title: "Faster Mission Control animation", domain: "com.apple.dock", key: "expose-animation-duration", kind: .toggle(0.1 as Double), restart: "Dock"),

        Tweak(group: "Screenshots", title: "Format", domain: "com.apple.screencapture", key: "type",
              kind: .choice([Choice("PNG (default)", nil), Choice("JPG", "jpg" as String), Choice("HEIC", "heic" as String)]), restart: "SystemUIServer"),
        Tweak(group: "Screenshots", title: "Save to", domain: "com.apple.screencapture", key: "location", kind: .folder, restart: "SystemUIServer"),
        Tweak(group: "Screenshots", title: "No shadow on window screenshots", domain: "com.apple.screencapture", key: "disable-shadow", kind: .toggle(true as Bool), restart: "SystemUIServer"),
        Tweak(group: "Screenshots", title: "Leave the date out of file names", domain: "com.apple.screencapture", key: "include-date", kind: .toggle(false as Bool), restart: "SystemUIServer"),

        Tweak(group: "Speed", title: "Turn off window opening animations", domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", kind: .toggle(false as Bool), note: nextApps),
        Tweak(group: "Speed", title: "Faster window resizing", domain: "NSGlobalDomain", key: "NSWindowResizeTime", kind: .toggle(0.001 as Double), note: nextApps),
        Tweak(group: "Speed", title: "Key repeat speed", domain: "NSGlobalDomain", key: "KeyRepeat", kind: .choice([Choice("Default", nil), Choice("Fast", 2 as Int), Choice("Fastest", 1 as Int)]), note: logout),
        Tweak(group: "Speed", title: "Delay before keys repeat", domain: "NSGlobalDomain", key: "InitialKeyRepeat", kind: .choice([Choice("Default", nil), Choice("Short", 15 as Int), Choice("Shortest", 10 as Int)]), note: logout),
        Tweak(group: "Speed", title: "Hold a key to repeat it (no accent menu)", domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", kind: .toggle(false as Bool), note: nextApps),

        Tweak(group: "Save & print dialogs", title: "Always show the full save dialog", domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", kind: .toggle(true as Bool), note: nextApps),
        Tweak(group: "Save & print dialogs", title: "Always show the full print dialog", domain: "NSGlobalDomain", key: "PMPrintingExpandedStateForPrint", kind: .toggle(true as Bool), note: nextApps),
        Tweak(group: "Save & print dialogs", title: "Save new documents to your Mac, not iCloud", domain: "NSGlobalDomain", key: "NSDocumentSaveNewDocumentsToCloud", kind: .toggle(false as Bool), note: nextApps),
    ]
    static var groups: [String] { all.map(\.group).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    // Reading
    private static func cfDomain(_ d: String) -> CFString { d == "NSGlobalDomain" ? kCFPreferencesAnyApplication : d as CFString }
    func value(_ t: Tweak) -> Any? {
        CFPreferencesAppSynchronize(Self.cfDomain(t.domain))
        return CFPreferencesCopyAppValue(t.key as CFString, Self.cfDomain(t.domain))
    }
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (a as AnyObject).isEqual(b as AnyObject)
    }
    func isOn(_ t: Tweak) -> Bool {
        guard case .toggle(let on) = t.kind else { return false }
        return Self.same(value(t), on)
    }
    /// Index of the current option; -1 when set to something else ("Custom").
    func choice(_ t: Tweak) -> Int {
        guard case .choice(let opts) = t.kind else { return 0 }
        let v = value(t)
        return opts.firstIndex { Self.same($0.value, v) } ?? (v == nil ? 0 : -1)
    }

    // Writing
    private static func typeArgs(_ v: Any) -> [String] {
        switch v {
        case let b as Bool: return ["-bool", b ? "true" : "false"]
        case let i as Int: return ["-int", "\(i)"]
        case let d as Double: return ["-float", "\(d)"]
        case let s as String: return ["-string", s]
        default: return []
        }
    }

    @MainActor func write(_ t: Tweak, _ v: Any?) async {
        if let v { _ = await Shell.run("/usr/bin/defaults", ["write", t.domain, t.key] + Self.typeArgs(v)) }
        else { _ = await Shell.run("/usr/bin/defaults", ["delete", t.domain, t.key]) }
        var touched = Set(UserDefaults.standard.stringArray(forKey: Opt.tweaked) ?? [])
        touched.insert(t.id)
        UserDefaults.standard.set(Array(touched), forKey: Opt.tweaked)
        if let r = t.restart { pendingRestart.insert(r) }
        version += 1
    }

    @MainActor func set(_ t: Tweak, on: Bool) async {
        guard case .toggle(let v) = t.kind else { return }
        await write(t, on ? v : nil)   // off = back to the macOS default
    }

    @MainActor func choose(_ t: Tweak, _ i: Int) async {
        guard case .choice(let opts) = t.kind, opts.indices.contains(i) else { return }
        await write(t, opts[i].value)
    }

    @MainActor func restartPending() async {
        for p in pendingRestart { _ = await Shell.run("/usr/bin/killall", [p]) }
        pendingRestart = []
    }

    /// Puts back macOS defaults for everything Onyx changed (and nothing else).
    @MainActor func resetAll() async {
        let touched = Set(UserDefaults.standard.stringArray(forKey: Opt.tweaked) ?? [])
        for t in Self.all where touched.contains(t.id) { await write(t, nil) }
        UserDefaults.standard.removeObject(forKey: Opt.tweaked)
    }
}

// MARK: - Startup & background

struct BackgroundItem: Identifiable {
    enum Scope: String { case user = "You", allUsers = "All users", system = "System" }
    let url: URL, label: String, owner: String, scope: Scope
    var disabled: Bool
    var id: String { url.path }
}

struct AppUsage: Identifiable {
    let path: String, name: String
    var cpu: Double, memKB: Int
    var id: String { path }
}

final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    @Published var items: [BackgroundItem] = []
    @Published var apps: [AppUsage] = []

    static var disabledDir: URL {
        let u = Prefs.supportDir.appendingPathComponent("Disabled Agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")

    @MainActor func refresh() async {
        items = await Task.detached { () -> [BackgroundItem] in
            let dirs: [(URL, BackgroundItem.Scope, Bool)] = [
                (Self.userDir, .user, false), (Self.disabledDir, .user, true),
                (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers, false),
                (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system, false),
            ]
            return dirs.flatMap { dir, scope, disabled in
                ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "plist" }
                    .map { Self.item($0, scope: scope, disabled: disabled) }
            }.sorted { $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending }
        }.value
        await refreshApps()
    }

    private static func item(_ u: URL, scope: BackgroundItem.Scope, disabled: Bool) -> BackgroundItem {
        let plist = (try? Data(contentsOf: u)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let label = plist["Label"] as? String ?? u.deletingPathExtension().lastPathComponent
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
        // "…/Google Chrome.app/…" → "Google Chrome"; otherwise "com.google.keystone.agent" → "Google"
        let app = program.components(separatedBy: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        let parts = label.split(separator: ".")
        let owner = app ?? (parts.count > 1 ? parts[1].capitalized : label)
        return BackgroundItem(url: u, label: label, owner: owner, scope: scope, disabled: disabled)
    }

    /// Turn a user agent off (unload it and move it into Onyx's Disabled Agents folder) or back on.
    @MainActor func setEnabled(_ item: BackgroundItem, _ on: Bool) async {
        guard item.scope == .user else { return }
        let uid = "gui/\(getuid())"
        if on {
            let dest = Self.userDir.appendingPathComponent(item.url.lastPathComponent)
            if Shell.dryRun { Shell.log("move: \(item.url.path) → \(dest.path)") } else { try? FileManager.default.moveItem(at: item.url, to: dest) }
            _ = await Shell.run("/bin/launchctl", ["bootstrap", uid, dest.path])
        } else {
            _ = await Shell.run("/bin/launchctl", ["bootout", uid, item.url.path])
            let dest = Self.disabledDir.appendingPathComponent(item.url.lastPathComponent)
            if Shell.dryRun { Shell.log("move: \(item.url.path) → \(dest.path)") } else { try? FileManager.default.moveItem(at: item.url, to: dest) }
        }
        await refresh()
    }

    /// CPU and memory per app, counting its helper processes (grouped by the first ".app" in their path).
    @MainActor func refreshApps() async {
        let out = await Shell.read("/bin/ps", ["-Ao", "pcpu=,comm="]).output
        var byApp: [String: AppUsage] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard f.count == 2, let cpu = Double(f[0]), let path = AppMemory.appPath(String(f[1])) else { continue }
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            byApp[path, default: AppUsage(path: path, name: name, cpu: 0, memKB: 0)].cpu += cpu
        }
        // Memory the way Activity Monitor counts it (not RSS, which double-counts shared memory).
        for (path, bytes) in await Task.detached { AppMemory.byApp() }.value {
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            byApp[path, default: AppUsage(path: path, name: name, cpu: 0, memKB: 0)].memKB = Int(bytes / 1024)
        }
        let mine = Bundle.main.bundlePath
        apps = byApp.values.filter { $0.path != mine && !$0.path.hasPrefix("/System/Library/CoreServices/Finder.app") }
            .filter { a in NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == a.path && $0.activationPolicy == .regular } }
    }

    func quit(_ a: AppUsage) {
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == a.path {
            if Shell.dryRun { Shell.log("quit: \(a.name)") } else { app.terminate() }   // polite quit, never force
        }
    }
}

// MARK: - Storage

struct FoundFile: Identifiable {
    let url: URL, bytes: Int64, date: Date?
    var id: String { url.path }
}

final class StorageModel: ObservableObject {
    static let shared = StorageModel()
    @Published var large: [FoundFile] = []
    @Published var forgotten: [FoundFile] = []
    @Published var busy = false
    @Published var scanned = false

    @MainActor func scan() async {
        busy = true; defer { busy = false; scanned = true }
        let home = NSHomeDirectory()
        let out = await Shell.read("/usr/bin/mdfind", ["-onlyin", home, "kMDItemFSSize > 500000000"]).output
        large = await Task.detached {
            out.split(separator: "\n").map(String.init)
                .filter { !$0.contains("/Library/") && !$0.contains("/.Trash/") }
                .map { p in let u = URL(fileURLWithPath: p); return FoundFile(url: u, bytes: Sys.size(u), date: nil) }
                .sorted { $0.bytes > $1.bytes }.prefix(40).map { $0 }
        }.value
        forgotten = await Task.detached { () -> [FoundFile] in
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let cutoff = Date().addingTimeInterval(-90 * 86400)
            let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
            let kids = (try? FileManager.default.contentsOfDirectory(at: dl, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return kids.compactMap { u in
                let rv = try? u.resourceValues(forKeys: Set(keys))
                let used = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                guard let last = used ?? rv?.addedToDirectoryDate ?? rv?.contentModificationDate, last < cutoff else { return nil }
                return FoundFile(url: u, bytes: Sys.size(u), date: last)
            }.sorted { $0.bytes > $1.bytes }
        }.value
    }

    @MainActor func trash(_ f: FoundFile) {
        guard Shell.trash(f.url) else { return }
        large.removeAll { $0.id == f.id }; forgotten.removeAll { $0.id == f.id }
    }
}

// MARK: - Automatic: low-disk alert + weekly clean

final class OptimizeService {
    static let shared = OptimizeService()
    private var timer: Timer?
    private var lastAlert = Date.distantPast

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }   // not during launch
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.check() }.tolerant()
    }

    private func check() {
        let free = Sys.disk().free
        if Prefs.bool(Opt.lowDiskAlert), free > 0, free < 10_000_000_000, Date().timeIntervalSince(lastAlert) > 6 * 3600 {
            lastAlert = Date()
            NotchModel.shared.flash(.message(icon: "externaldrive.fill.badge.exclamationmark", text: "Low disk: \(Sys.bytes(free)) left", tint: .orange), for: 5)
        }
        let last = UserDefaults.standard.object(forKey: Opt.lastAutoClean) as? Date ?? .distantPast
        if Prefs.bool(Opt.autoClean), Date().timeIntervalSince(last) > 7 * 86400 {
            UserDefaults.standard.set(Date(), forKey: Opt.lastAutoClean)
            Task { @MainActor in
                await CleanModel.shared.scan()
                let moved = await CleanModel.shared.clean(onlyDefaults: true)
                if moved > 0 { NotchModel.shared.flash(.message(icon: "sparkles", text: "Cleaned \(Sys.bytes(moved)) (in Trash)", tint: .green), for: 4) }
            }
        }
    }
}

// MARK: - Per-app memory (Activity Monitor's "Memory": physical footprint, helpers included)

enum AppMemory {
    /// "/Applications/Google Chrome.app/…/Google Chrome Helper.app/…" → "/Applications/Google Chrome.app"
    static func appPath(_ exe: String) -> String? {
        guard let r = exe.range(of: ".app/") else { return nil }
        return String(exe[..<r.lowerBound]) + ".app"
    }

    /// Bytes per app bundle path, summing each app's helper processes.
    static func byApp() -> [String: UInt64] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        var out: [String: UInt64] = [:]
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let app = appPath(String(cString: buf)) else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            if ok { out[app, default: 0] += info.ri_phys_footprint }
        }
        return out
    }
}

// MARK: - Auto-quit apps with no windows

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows") private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

/// Quits regular apps that have had no windows for a while (like closing the last window on Windows).
/// Never touches Finder, Onyx, the app you're using, apps on the keep list, or the music app while it plays.
final class AutoQuit {
    static let shared = AutoQuit()
    static let alwaysKeep: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "local.onyx.notch"]
    private var since: [pid_t: Date] = [:]
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }.tolerant()
    }

    /// Apps that have at least one real window: minimized and on other desktops count; the invisible
    /// helper windows apps keep around (which belong to no desktop) don't.
    static func appsWithWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let cid = CGSMainConnectionID()
        var pids = Set<pid_t>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, !pids.contains(pid),
                  let wid = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) >= 60, (b["Height"] ?? 0) >= 40 else { continue }
            let spaces = (CGSCopySpacesForWindows(cid, 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber]) ?? []
            if !spaces.isEmpty { pids.insert(pid) }
        }
        return pids
    }

    /// Second opinion from Accessibility. Any doubt (no permission, timeout) counts as "has windows".
    private static func axHasWindows(_ pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v) == .success else { return true }
        return ((v as? [AnyObject])?.count ?? 1) > 0
    }

    private func tick() {
        guard Prefs.bool(Opt.autoQuit), !NotchModel.shared.animating else { if !Prefs.bool(Opt.autoQuit) { since = [:] }; return }
        let delay = max(1, Prefs.double(Opt.autoQuitMinutes)) * 60
        let keep = Set(UserDefaults.standard.stringArray(forKey: Opt.autoQuitKeep) ?? []).union(Self.alwaysKeep)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let playing = MediaController.shared.isPlaying ? MediaController.shared.source?.rawValue : nil
        let windowed = Self.appsWithWindows()
        var alive = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.isFinishedLaunching {
            let pid = app.processIdentifier
            alive.insert(pid)
            // Reset the clock whenever it has a window, is in front, is protected, or is playing music.
            guard let id = app.bundleIdentifier, !keep.contains(id), id != playing, pid != front,
                  !windowed.contains(pid), !Self.axHasWindows(pid) else { since[pid] = nil; continue }
            let start = since[pid] ?? Date()
            since[pid] = start
            guard Date().timeIntervalSince(start) >= delay else { continue }
            since[pid] = nil
            let name = app.localizedName ?? id
            if Shell.dryRun { Shell.log("autoquit: \(name)") }
            else if app.terminate() {   // a normal Quit, never a force quit
                NotchModel.shared.flash(.message(icon: "xmark.app", text: "Quit \(name)", tint: .secondary), for: 2.5)
            }
        }
        since = since.filter { alive.contains($0.key) }
    }
}

// MARK: - Settings UI

enum OptimizePage: String, CaseIterable, Identifiable {
    case overview, clean, maintain, tweaks, startup, storage
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The Optimization window's content.
struct OptimizeWindowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: SettingsSection.optimize.icon, colors: SettingsSection.optimize.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Optimization").font(.system(size: 17, weight: .bold))
                    Text("Clean, maintain and tweak your Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
            OptimizeSettings()
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(DetailBackground())
    }
}

struct OptimizeSettings: View {
    @AppStorage(Opt.page) private var page = OptimizePage.overview.rawValue
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(OptimizePage.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 8)
            switch OptimizePage(rawValue: page) ?? .overview {
            case .overview: OptOverview()
            case .clean: OptClean()
            case .maintain: OptMaintain()
            case .tweaks: OptTweaks()
            case .startup: OptStartup()
            case .storage: OptStorage()
            }
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

private struct UsageRing: View {
    let fraction: Double, title: String, value: String, detail: String, tint: Color
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 7)
                Circle().trim(from: 0, to: max(0.01, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(value).font(.system(size: 11.5)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OptOverview: View {
    @ObservedObject var clean = CleanModel.shared
    @AppStorage(Opt.lowDiskAlert) private var lowDisk = true
    @AppStorage(Opt.autoClean) private var autoClean = false
    @State private var disk = Sys.disk()
    @State private var mem = Sys.memory()
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 28) {
                    let used = Double(disk.total - disk.free) / Double(max(disk.total, 1))
                    UsageRing(fraction: used, title: "Disk", value: "\(Sys.bytes(disk.free)) free",
                              detail: "of \(Sys.bytes(disk.total))", tint: used > 0.9 ? .red : .blue)
                    UsageRing(fraction: Double(mem.used) / Double(max(mem.total, 1)), title: "Memory",
                              value: "\(Sys.bytes(Int64(mem.used))) used", detail: mem.pressure >= 4 ? "Pressure: high" : mem.pressure == 2 ? "Pressure: medium" : "Pressure: normal",
                              tint: mem.pressure >= 4 ? .red : mem.pressure == 2 ? .orange : .green)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                LabeledContent("Last restart") { Text(Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime), format: .relative(presentation: .named)) }
                if let d = UserDefaults.standard.object(forKey: Opt.lastClean) as? Date {
                    LabeledContent("Last clean") {
                        Text("\(Sys.bytes(Int64(UserDefaults.standard.integer(forKey: Opt.lastCleanBytes)))) · \(d.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
            Section("Quick Optimize") {
                HStack {
                    Button("Quick Optimize") { Task { await clean.quickOptimize() } }
                        .buttonStyle(.borderedProminent).disabled(clean.busy)
                    if clean.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    EmptyTrashButton()
                }
                if let r = clean.result { Text(r).font(.callout) }
                Caption("Moves app caches and old logs to the Trash. Nothing else is touched. For more control, use Clean.")
            }
            Section("Automatic") {
                Toggle("Warn me in the notch when disk space is low", isOn: $lowDisk)
                Caption("When less than 10 GB is free, at most every 6 hours.")
                Toggle("Clean caches and logs every week", isOn: $autoClean)
                Caption("Moves them to the Trash once a week and tells you how much in the notch.")
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in disk = Sys.disk(); mem = Sys.memory() }
    }
}

struct OptClean: View {
    @ObservedObject var m = CleanModel.shared
    var body: some View {
        Form {
            Section {
                HStack {
                    Button(m.categories.isEmpty ? "Scan" : "Scan again") { Task { await m.scan() } }.disabled(m.busy)
                    if m.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if !m.categories.isEmpty { Text("Selected: \(Sys.bytes(m.selectedBytes))").monospacedDigit().foregroundStyle(.secondary) }
                }
                Caption("Cleaning moves files to the Trash, so you can put anything back. Empty the Trash to get the space.")
            }
            if !m.categories.isEmpty {
                Section("Found") {
                    ForEach($m.categories) { $c in
                        Toggle(isOn: $c.selected) {
                            HStack(spacing: 10) {
                                Image(systemName: c.icon).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title)
                                    Caption(c.detail)
                                }
                                Spacer()
                                Text(Sys.bytes(c.bytes)).monospacedDigit()
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Move selected to Trash") { Task { await m.clean() } }
                            .buttonStyle(.borderedProminent).disabled(m.busy || m.selectedBytes == 0)
                        Spacer()
                        EmptyTrashButton()
                    }
                    if let r = m.result { Text(r).font(.callout) }
                }
            }
            Section { Caption("Apple's own caches and folders macOS protects (Mail, Messages, Safari) are skipped.") }
        }
        .formStyle(.grouped)
    }
}

struct OptMaintain: View {
    @ObservedObject var m = MaintenanceModel.shared
    var body: some View {
        Form {
            Section { Caption("Fixes for common Mac hiccups. Tasks with a 🔒 ask for your Mac password in a macOS window. Onyx never sees it.") }
            Section {
                ForEach(MaintenanceModel.tasks) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(t.title)
                                if t.admin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Caption(t.detail)
                            if let d = m.lastRun(t) {
                                Text("Last run \(d.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if let ok = m.results[t.id] {
                            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
                        }
                        if m.running == t.id { ProgressView().controlSize(.small) }
                        else { Button("Run") { Task { await m.run(t) } }.disabled(m.running != nil) }
                    }
                }
            }
            if let out = m.output {
                Section("Result") {
                    ScrollView { Text(out).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 110)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct OptTweaks: View {
    @ObservedObject var m = TweaksModel.shared
    @State private var confirmReset = false
    var body: some View {
        Form {
            if !m.pendingRestart.isEmpty {
                Section {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("Restart \(m.pendingRestart.sorted().map { $0 == "SystemUIServer" ? "the menu bar" : $0 }.joined(separator: ", ")) to apply your changes.")
                        Spacer()
                        Button("Restart now") { Task { await m.restartPending() } }
                    }
                }
            }
            ForEach(TweaksModel.groups, id: \.self) { g in
                Section(g) {
                    ForEach(TweaksModel.all.filter { $0.group == g }) { t in TweakRow(tweak: t) }
                }
            }
            Section {
                HStack {
                    Caption("Reset only undoes changes made here.")
                    Spacer()
                    Button("Reset all tweaks…", role: .destructive) { confirmReset = true }
                }
                Caption("Onyx never changes security settings: Gatekeeper, the firewall, SIP and privacy permissions are off-limits.")
            }
        }
        .formStyle(.grouped)
        .alert("Reset all tweaks?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Task { await m.resetAll() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Everything you changed on this page goes back to the macOS default.") }
    }
}

private struct TweakRow: View {
    let tweak: Tweak
    @ObservedObject var m = TweaksModel.shared

    var body: some View {
        let _ = m.version   // re-read after changes
        VStack(alignment: .leading, spacing: 2) {
            switch tweak.kind {
            case .toggle:
                Toggle(tweak.title, isOn: Binding(get: { m.isOn(tweak) }, set: { on in Task { await m.set(tweak, on: on) } }))
            case .choice(let opts):
                Picker(tweak.title, selection: Binding(get: { m.choice(tweak) }, set: { i in Task { await m.choose(tweak, i) } })) {
                    if m.choice(tweak) == -1 { Text("Custom").tag(-1) }
                    ForEach(opts.indices, id: \.self) { Text(opts[$0].label).tag($0) }
                }
            case .folder:
                LabeledContent(tweak.title) {
                    HStack {
                        Text((m.value(tweak) as? String).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Desktop (default)")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if m.value(tweak) != nil { Button("Default") { Task { await m.write(tweak, nil) } } }
                    }
                }
            }
            if let n = tweak.note { Caption(n) }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Save Screenshots Here"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { Task { await m.write(tweak, u.path) } }
    }
}

struct OptStartup: View {
    @ObservedObject var m = StartupModel.shared
    @State private var byMemory = false
    @AppStorage(Opt.autoQuit) private var autoQuit = false
    @AppStorage(Opt.autoQuitMinutes) private var autoQuitMinutes = 10.0
    @State private var keep = UserDefaults.standard.stringArray(forKey: Opt.autoQuitKeep) ?? []

    var body: some View {
        Form {
            Section("Quit apps with no windows") {
                Toggle("Quit apps after their last window is closed", isOn: $autoQuit)
                if autoQuit {
                    Picker("After", selection: $autoQuitMinutes) {
                        ForEach([1.0, 2, 5, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) minute\($0 == 1 ? "" : "s")").tag($0) }
                    }
                    LabeledContent("Never quit") {
                        HStack(spacing: 6) {
                            ForEach(keep, id: \.self) { id in
                                HStack(spacing: 3) {
                                    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 14, height: 14)
                                    }
                                    Text(Self.appName(id)).lineLimit(1)
                                    Button { keep.removeAll { $0 == id }; saveKeep() } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            Menu {
                                let running = NSWorkspace.shared.runningApplications
                                    .filter { $0.activationPolicy == .regular }
                                    .compactMap(\.bundleIdentifier)
                                    .filter { !keep.contains($0) && !AutoQuit.alwaysKeep.contains($0) }
                                ForEach(Array(Set(running)).sorted { Self.appName($0) < Self.appName($1) }, id: \.self) { id in
                                    Button(Self.appName(id)) { keep.append(id); saveKeep() }
                                }
                            } label: { Image(systemName: "plus.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
                Caption("Once an app has had no windows for this long, Onyx quits it normally, just like pressing ⌘Q. Minimized windows and windows on other desktops count as open. Finder, the app you're using and music that's playing are never quit.")
            }
            Section("Using the most right now") {
                Picker("", selection: $byMemory) { Text("CPU").tag(false); Text("Memory").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                let top = m.apps.sorted { byMemory ? $0.memKB > $1.memKB : $0.cpu > $1.cpu }.prefix(5)
                ForEach(Array(top)) { a in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 18, height: 18)
                        Text(a.name).lineLimit(1)
                        Spacer()
                        Text(byMemory ? Sys.bytes(Int64(a.memKB) * 1024) : String(format: "%.0f%% CPU", a.cpu)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Quit") { m.quit(a); Task { try? await Task.sleep(for: .seconds(1)); await m.refreshApps() } }
                    }
                }
                HStack { Spacer(); Button("Refresh") { Task { await m.refreshApps() } } }
            }
            Section("Background items") {
                if m.items.isEmpty { Caption("Nothing found.") }
                ForEach(m.items) { i in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.owner)
                            Text(i.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(i.scope.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.plain).help("Show in Finder")
                        if i.scope == .user {
                            Toggle("", isOn: Binding(get: { !i.disabled }, set: { on in Task { await m.setEnabled(i, on) } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                    }
                }
                Caption("Turning off one of your items moves it to Onyx's Disabled Agents folder, so you can turn it back on anytime. Items for all users or the system are view-only.")
                HStack {
                    Caption("Apps that open when you log in are in System Settings.")
                    Spacer()
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await m.refresh() }
    }

    private func saveKeep() { UserDefaults.standard.set(keep, forKey: Opt.autoQuitKeep) }
    static func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { $0.deletingPathExtension().lastPathComponent } ?? id
    }
}

struct OptStorage: View {
    @ObservedObject var m = StorageModel.shared
    var body: some View {
        Form {
            Section {
                HStack {
                    Button(m.scanned ? "Scan again" : "Find big and forgotten files") { Task { await m.scan() } }.disabled(m.busy)
                    if m.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Caption("Nothing is removed unless you click its trash button, and that moves it to the Trash.")
            }
            if m.scanned {
                Section("Large files (over 500 MB)") {
                    if m.large.isEmpty { Caption("None found in your home folder.") }
                    ForEach(m.large) { FileRow(file: $0) }
                }
                Section("Downloads you haven't opened in 90+ days") {
                    if m.forgotten.isEmpty { Caption("None, nice and tidy.") }
                    ForEach(m.forgotten) { FileRow(file: $0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FileRow: View {
    let file: FoundFile
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(((file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                     + (file.date.map { " · last used \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Sys.bytes(file.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).help("Show in Finder")
            Button { StorageModel.shared.trash(file) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red).help("Move to Trash")
        }
    }
}

// MARK: - Self-test (dry run): ONYX_OPTIMIZE_TEST=1 logs what every action would do, then quits.

enum OptimizeSelfTest {
    @MainActor static func run() async {
        try? FileManager.default.removeItem(at: Shell.logFile)
        Shell.log("== Onyx optimize self-test (dry run) \(Date())")
        let d = Sys.disk(), mem = Sys.memory()
        Shell.log("disk free \(Sys.bytes(d.free)) of \(Sys.bytes(d.total)); memory used \(Sys.bytes(Int64(mem.used))) of \(Sys.bytes(Int64(mem.total))), pressure \(mem.pressure)")
        let c = CleanModel.shared
        await c.scan()
        for cat in c.categories { Shell.log("clean category \(cat.id): \(cat.items.count) items, \(Sys.bytes(cat.bytes)), selected \(cat.selected)") }
        await c.clean()
        Shell.log("clean result: \(c.result ?? "-")")
        _ = await Shell.emptyTrash()
        for t in MaintenanceModel.tasks { await MaintenanceModel.shared.run(t) }
        let tw = TweaksModel.shared
        for t in TweaksModel.all {
            switch t.kind {
            case .toggle: Shell.log("tweak \(t.id) currently \(tw.isOn(t) ? "on" : "off") (value \(tw.value(t).map { "\($0)" } ?? "unset"))")
                await tw.set(t, on: true); await tw.set(t, on: false)
            case .choice(let o): Shell.log("tweak \(t.id) choice \(tw.choice(t)) (value \(tw.value(t).map { "\($0)" } ?? "unset"))")
                for i in o.indices { await tw.choose(t, i) }
            case .folder: Shell.log("tweak \(t.id) folder \(tw.value(t).map { "\($0)" } ?? "unset")")
            }
        }
        await tw.restartPending()
        await tw.resetAll()
        let s = StartupModel.shared
        await s.refresh()
        for i in s.items { Shell.log("startup \(i.scope.rawValue): \(i.owner) — \(i.label)\(i.disabled ? " (disabled)" : "")") }
        if let u = s.items.first(where: { $0.scope == .user }) { await s.setEnabled(u, false) }
        for a in s.apps.sorted(by: { $0.cpu > $1.cpu }).prefix(5) { Shell.log("app \(a.name): \(a.cpu)% cpu, \(a.memKB / 1024) MB") }
        let st = StorageModel.shared
        await st.scan()
        for f in st.large.prefix(5) { Shell.log("large \(Sys.bytes(f.bytes)) \(f.url.path)") }
        Shell.log("forgotten downloads: \(st.forgotten.count), \(Sys.bytes(st.forgotten.reduce(0) { $0 + $1.bytes }))")
        for (path, b) in AppMemory.byApp().sorted(by: { $0.value > $1.value }).prefix(6) {
            Shell.log("memory \((path as NSString).lastPathComponent): \(Sys.bytes(Int64(b)))")
        }
        let windowed = AutoQuit.appsWithWindows()
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            Shell.log("auto-quit check \(a.localizedName ?? "?"): \(windowed.contains(a.processIdentifier) ? "has windows" : "no windows")")
        }
        Shell.log("== done")
        NSApp.terminate(nil)
    }
}
