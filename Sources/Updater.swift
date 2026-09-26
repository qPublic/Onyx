import AppKit
import SwiftUI
import Security

// MARK: - Auto-update: new GitHub releases download in the background and install the next time Onyx starts

final class Updater: ObservableObject {
    static let shared = Updater()
    static let autoKey = "autoUpdate"

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        case ready(String)          // downloaded and verified; installs when Onyx quits or next starts
        case failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var releasePage: URL?

    private let feed = URL(string: "https://api.github.com/repos/qPublic/Onyx/releases/latest")!
    private var dir: URL { Prefs.supportDir.appendingPathComponent("Update", isDirectory: true) }
    private var staged: URL { dir.appendingPathComponent("Onyx.app", isDirectory: true) }
    private var timer: Timer?
    private var installing = false
    private let session = URLSession(configuration: .ephemeral)

    // Debug: ONYX_UPDATE_CURRENT=1.3.0 pretends to be that version; ONYX_UPDATE_DEST=<path> installs there instead.
    private static let env = ProcessInfo.processInfo.environment
    static var current: String {
        env["ONYX_UPDATE_CURRENT"] ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
    private var destination: URL { Self.env["ONYX_UPDATE_DEST"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL }

    /// Called first thing at launch. If an update was downloaded last time, swap it in and reopen; returns true when quitting for that.
    func installPendingAtLaunch() -> Bool {
        UserDefaults.standard.register(defaults: [Self.autoKey: true])
        guard let v = stagedVersion() else { return false }
        let d = UserDefaults.standard
        // Two tries per version, so a failing install can never relaunch in a loop.
        let tries = d.string(forKey: "update.tryVersion") == v ? d.integer(forKey: "update.tryCount") : 0
        guard Self.newer(v, than: Self.current), tries < 2, cantInstall == nil, verify(staged, version: v) else {
            try? FileManager.default.removeItem(at: dir)
            return false
        }
        install(relaunch: true)
        return true
    }

    func start() {
        announceIfUpdated()
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }.tolerant()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.autoCheck() }
    }

    private func autoCheck() { if Prefs.bool(Self.autoKey) { check() } }

    /// Looks for a newer release and, if there is one, downloads and verifies it in the background.
    func check(user: Bool = false) {
        switch state {
        case .checking, .downloading: return
        case .ready(let v): if user { flash("Onyx \(v) ready", "arrow.down.circle.fill", .blue) }; return
        default: break
        }
        if let why = cantInstall { state = .failed(why); return }
        state = .checking
        Task {
            let result: State
            do { result = try await fetch(user: user) } catch { result = .failed((error as? Failure)?.message ?? "Couldn't reach GitHub. Try again later.") }
            await MainActor.run {
                state = result
                switch result {
                case .ready(let v): flash("Onyx \(v) ready", "arrow.down.circle.fill", .blue)
                case .upToDate where user: flash("Up to date", "checkmark.circle.fill", .green)
                case .failed where user: flash("Update failed", "exclamationmark.triangle.fill", .orange)
                default: break
                }
            }
        }
    }

    /// Quits and installs now (Settings › Restart Now, or the menu bar item).
    func restartNow() {
        guard case .ready = state else { return }
        install(relaunch: true)
        NSApp.terminate(nil)
    }

    /// Onyx is quitting: if an update is waiting, it's swapped in once we've exited.
    func installOnQuit() {
        if case .ready = state { install(relaunch: false) }
    }

    // MARK: Download

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let size: Int; let browser_download_url: String }
        let tag_name: String; let html_url: String; let assets: [Asset]
    }
    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    private func fetch(user: Bool) async throws -> State {
        var req = URLRequest(url: feed, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Onyx/\(Self.current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub didn't answer. Try again later.") }
        let rel = try JSONDecoder().decode(Release.self, from: data)
        let v = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        await MainActor.run { releasePage = URL(string: rel.html_url) }
        guard Self.newer(v, than: Self.current) else { return .upToDate }
        if stagedVersion() == v { return .ready(v) }

        // Only an installer attached to the release on github.com, over HTTPS.
        guard let asset = rel.assets.first(where: { $0.name == "Onyx-\(v).dmg" }) ?? rel.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              asset.size < 300_000_000 else { throw Failure("Onyx \(v) has no installer attached yet") }
        await MainActor.run { state = .downloading(v) }
        let (tmp, dresp) = try await session.download(for: URLRequest(url: url, timeoutInterval: 120))
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (dresp as? HTTPURLResponse)?.statusCode == 200, dresp.url?.scheme == "https",
              let host = dresp.url?.host, host == "github.com" || host.hasSuffix(".githubusercontent.com")
        else { throw Failure("The download of Onyx \(v) failed") }
        try await stage(dmg: tmp, version: v)
        return .ready(v)
    }

    /// Copies Onyx.app out of the downloaded disk image into Application Support/Onyx/Update, then verifies it.
    private func stage(dmg: URL, version v: String) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let image = dir.appendingPathComponent("Onyx.dmg"), mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try fm.moveItem(at: dmg, to: image)
        let a = await Shell.read("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard a.status == 0 else { try? fm.removeItem(at: dir); throw Failure("Couldn't open the Onyx \(v) installer") }
        let c = await Shell.read("/usr/bin/ditto", ["--noqtn", mount.appendingPathComponent("Onyx.app").path, staged.path])
        _ = await Shell.read("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? fm.removeItem(at: image); try? fm.removeItem(at: mount)
        let ok = await Task.detached { [staged] in c.status == 0 && self.verify(staged, version: v) }.value
        guard ok else { try? fm.removeItem(at: dir); throw Failure("Onyx \(v) isn't signed like this copy, so it wasn't installed") }
    }

    // MARK: Verify and install

    /// The new app must be Onyx, newer than this one, and meet this copy's designated requirement, i.e. be signed
    /// with the same certificate. That's also what macOS checks to keep Accessibility and Screen Recording access.
    private func verify(_ app: URL, version v: String) -> Bool {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == v, Self.newer(v, than: Self.current),
              let req = Self.requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// This copy's designated requirement, but only when it's signed with a certificate (ad-hoc builds can't update).
    private static let requirement: SecRequirement? = {
        var me: SecCode?, code: SecStaticCode?, info: CFDictionary?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certs.isEmpty,
              SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess else { return nil }
        return req
    }()

    private var cantInstall: String? {
        let path = destination.path
        if Self.requirement == nil { return "This build isn't signed, so it can't update itself" }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return "Move Onyx to Applications to get updates" }
        if !FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) { return "Onyx can't write to its folder, so it can't update itself" }
        return nil
    }

    private func stagedVersion() -> String? {
        (NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
    }

    /// A tiny shell helper outlives Onyx: it waits for us to exit, swaps the new app in (putting the old one back if
    /// anything fails), removes the download and optionally reopens Onyx.
    private func install(relaunch: Bool) {
        guard !installing, let v = stagedVersion() else { return }
        installing = true
        let d = UserDefaults.standard
        d.set(d.string(forKey: "update.tryVersion") == v ? d.integer(forKey: "update.tryCount") + 1 : 1, forKey: "update.tryCount")
        d.set(v, forKey: "update.tryVersion")
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        new="$3.new"; old="$3.old"
        rm -rf "$new" "$old"
        /usr/bin/ditto --noqtn "$2/Onyx.app" "$new" || { rm -rf "$new"; exit 1; }
        mv "$3" "$old" || { rm -rf "$new"; exit 1; }
        if mv "$new" "$3"; then rm -rf "$old" "$2"; else mv "$old" "$3"; fi
        [ "$4" = 1 ] && /usr/bin/open "$3"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "onyx-update", String(getpid()), dir.path, destination.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { installing = false }
    }

    /// After an update, say so once in the notch.
    private func announceIfUpdated() {
        guard Self.env["ONYX_UPDATE_CURRENT"] == nil else { return }
        let d = UserDefaults.standard, v = Self.current
        if let last = d.string(forKey: "update.lastRun"), Self.newer(v, than: last) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.flash("Updated to \(v)", "checkmark.seal.fill", .green) }
        }
        d.set(v, forKey: "update.lastRun")
    }

    private func flash(_ text: String, _ icon: String, _ tint: Color) {
        NotchModel.shared.flash(.message(icon: icon, text: text, tint: tint), for: 4)
    }

    /// "1.10.0" is newer than "1.9.2"; missing parts count as 0.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - Settings › Behavior › Updates

struct UpdateSettings: View {
    @AppStorage(Updater.autoKey) var auto = true
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Update automatically", isOn: $auto)
                Text("Onyx checks GitHub for new versions, downloads them in the background, and installs them the next time Onyx starts. Updates are only installed if they're signed with the same certificate as this copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                status
                Spacer()
                if let page = updater.releasePage { Link("What's new", destination: page).font(.caption) }
                if case .ready = updater.state {
                    Button("Restart Now") { updater.restartNow() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") { updater.check(user: true) }.disabled(busy)
                }
            }
        } header: { Text("Updates") }
    }

    private var busy: Bool {
        switch updater.state { case .checking, .downloading: true; default: false }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle: Text("Onyx \(Updater.current)").foregroundStyle(.secondary)
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .downloading(let v): HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading Onyx \(v)…") }
        case .upToDate: Label("Onyx \(Updater.current) is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .ready(let v): Label("Onyx \(v) installs next time Onyx starts", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
