import AppKit
import SwiftUI
import SystemConfiguration
import CoreWLAN
import Network

// MARK: - Proton VPN: its status in the notch, connect and disconnect from Onyx, a warning when it drops, and (if you
// like) connecting on Wi-Fi you haven't trusted. It uses macOS's own controls for the ProtonVPN connection that the
// Proton VPN app sets up, so Proton VPN picks the server, as it would if you pressed Connect there.

@MainActor final class ProtonVPN: ObservableObject {
    static let shared = ProtonVPN()
    nonisolated static let autoKey = "vpn.autoConnect", trustedKey = "vpn.trusted", warnKey = "vpn.warnDrop"
    static let bundleID = "ch.protonvpn.mac"

    enum Status: Equatable { case missing, noConnection, off, connecting, on, disconnecting }
    @Published private(set) var status: Status = .missing
    @Published private(set) var place: String?       // "Zürich, Switzerland"
    @Published private(set) var ip: String?
    @Published private(set) var wifi: String?        // the Wi-Fi you're on (macOS shares it once Onyx may use Location)
    @Published private(set) var problem: String?
    @Published private(set) var since: Date?

    private var conn: SCNetworkConnection?
    private var mine = false                         // Onyx asked for the change that's under way
    private var lastWiFi: String?
    private let path = NWPathMonitor()

    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil }
    var on: Bool { status == .on }
    var usable: Bool { ![.missing, .noConnection].contains(status) }

    func start() {
        Task { await find() }
        path.pathUpdateHandler = { _ in Task { @MainActor in ProtonVPN.shared.networkChanged() } }
        path.start(queue: .main)
    }

    /// The ProtonVPN connection in macOS's network settings (made the first time Proton VPN connects).
    func find() async {
        let r = await Shell.read("/usr/sbin/scutil", ["--nc", "list"])
        guard let (id, _) = Self.service(r.output) else { status = installed ? .noConnection : .missing; return }
        attach(id)
    }

    /// From `scutil --nc list`: `* (Connected)  2915…F6F VPN (ch.protonvpn.mac) "ProtonVPN"  [VPN:ch.protonvpn.mac]`.
    nonisolated static func service(_ list: String) -> (id: String, name: String)? {
        for line in list.split(separator: "\n") where line.contains(bundleID) {
            guard let id = line.split(separator: " ").first(where: { $0.count == 36 && $0.filter { $0 == "-" }.count == 4 }) else { continue }
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            return (String(id), quoted.count >= 3 ? String(quoted[1]) : "ProtonVPN")
        }
        return nil
    }

    private func attach(_ id: String) {
        var ctx = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let c = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, { _, _, info in
            guard let info else { return }
            let me = Unmanaged<ProtonVPN>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in me.update() }
        }, &ctx) else { status = .noConnection; return }
        SCNetworkConnectionScheduleWithRunLoop(c, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        conn = c
        status = .off
        update()
    }

    /// macOS tells Onyx the moment the connection changes; no checking on a timer.
    private func update() {
        guard let conn else { return }
        let new: Status
        switch SCNetworkConnectionGetStatus(conn) {
        case .connected: new = .on
        case .connecting: new = .connecting
        case .disconnecting: new = .disconnecting
        default: new = .off
        }
        let old = status
        guard new != old else { return }
        status = new
        switch new {
        case .on:
            since = Date(); problem = nil
            Task { await locate() }
        case .off:
            let was = since
            since = nil; place = nil; ip = nil
            if old == .on || old == .disconnecting, !mine, let was, Date().timeIntervalSince(was) > 20, Prefs.bool(Self.warnKey) {
                NotchModel.shared.flash(.message(icon: "exclamationmark.shield.fill", text: "Proton VPN disconnected", tint: .orange), for: 5)
            }
        default: break
        }
        if new == .on || new == .off { mine = false }
    }

    /// Where the internet sees you now (through the VPN).
    private func locate() async {
        guard let u = URL(string: "https://ipwho.is/"), let (d, _) = try? await URLSession.shared.data(from: u),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], status == .on else { return }
        ip = j["ip"] as? String
        let p = [j["city"] as? String, j["country"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        place = p.isEmpty ? nil : p
    }

    func connect() {
        guard let conn else { openApp(); return }
        mine = true; problem = nil
        guard SCNetworkConnectionStart(conn, nil, false) else {
            mine = false; problem = "Proton VPN didn't start from Onyx, so Onyx opened it. Press Connect there."; openApp(); return
        }
        // Nothing after 10 seconds: hand over to Proton VPN.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.status == .off, self.mine else { return }
            self.mine = false
            self.problem = "Proton VPN didn't connect from Onyx, so Onyx opened it. Press Connect there."
            self.openApp()
        }
    }

    func disconnect() {
        guard let conn else { return }
        mine = true
        if !SCNetworkConnectionStop(conn, true) { mine = false; openApp() }
    }

    func toggle() { [.on, .connecting].contains(status) ? disconnect() : connect() }

    func openApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) { NSWorkspace.shared.open(app) }
        else if let u = URL(string: "https://protonvpn.com/download") { NSWorkspace.shared.open(u) }
    }

    // MARK: Wi-Fi you haven't trusted

    static var trusted: [String] { UserDefaults.standard.stringArray(forKey: trustedKey) ?? [] }
    func trust(_ name: String, _ yes: Bool) {
        var t = Self.trusted.filter { $0 != name }
        if yes { t.append(name) }
        UserDefaults.standard.set(t, forKey: Self.trustedKey)
        objectWillChange.send()
    }

    private func networkChanged() {
        let name = CWWiFiClient.shared().interface()?.ssid()
        wifi = name
        guard name != lastWiFi else { return }
        lastWiFi = name
        guard Prefs.bool(Self.autoKey), let name, !Self.trusted.contains(name), status == .off else { return }
        NotchModel.shared.flash(.message(icon: "lock.shield.fill", text: "New Wi-Fi: connecting Proton VPN", tint: .green), for: 3)
        connect()
    }
}

// MARK: - Notch widgets

struct VPNWidget: View {
    @ObservedObject var vpn = ProtonVPN.shared
    var body: some View {
        Pill {
            HStack(spacing: 4) {
                Image(systemName: VPNWidget.icon(vpn.status)).foregroundStyle(VPNWidget.tint(vpn.status))
                if vpn.on, let p = vpn.place?.split(separator: ",").last { Text(p.trimmingCharacters(in: .whitespaces)).lineLimit(1) }
            }
        }
        .onTapGesture { vpn.usable ? vpn.toggle() : vpn.openApp() }
        .help(VPNWidget.label(vpn))
    }

    static func icon(_ s: ProtonVPN.Status) -> String {
        switch s { case .on: "lock.shield.fill"; case .connecting, .disconnecting: "shield.lefthalf.filled"; default: "shield.slash" }
    }
    static func tint(_ s: ProtonVPN.Status) -> Color {
        switch s { case .on: .green; case .connecting, .disconnecting: .yellow; default: .secondary }
    }
    static func label(_ v: ProtonVPN) -> String {
        switch v.status {
        case .missing: "Proton VPN isn't installed"
        case .noConnection: "Connect once in Proton VPN first"
        case .off: "Proton VPN: not connected. Click to connect."
        case .connecting: "Proton VPN: connecting…"
        case .disconnecting: "Proton VPN: disconnecting…"
        case .on: "Proton VPN: connected\(v.place.map { " · \($0)" } ?? ""). Click to disconnect."
        }
    }
}

struct CGVPN: View {
    @ObservedObject var vpn = ProtonVPN.shared
    var body: some View { Image(systemName: VPNWidget.icon(vpn.status)).foregroundStyle(VPNWidget.tint(vpn.status)) }
}

// MARK: - Settings › Privacy › Proton VPN

struct ProtonVPNSection: View {
    @ObservedObject var vpn = ProtonVPN.shared
    @AppStorage(ProtonVPN.warnKey) private var warn = true
    @AppStorage(ProtonVPN.autoKey) private var auto = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: VPNWidget.icon(vpn.status)).foregroundStyle(VPNWidget.tint(vpn.status)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if vpn.on, let ip = vpn.ip { Text("\(vpn.place ?? "") · \(ip)").font(.caption).foregroundStyle(.secondary) }
                    if let p = vpn.problem { Text(p).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                if vpn.usable {
                    Button(vpn.on || vpn.status == .connecting ? "Disconnect" : "Connect") { vpn.toggle() }
                        .disabled(vpn.status == .disconnecting)
                }
                Button(vpn.installed ? "Open Proton VPN" : "Get Proton VPN") { vpn.openApp() }
            }
            if vpn.usable {
                Toggle("Warn me in the notch if it disconnects", isOn: $warn)
                Toggle("Connect on Wi-Fi I haven't trusted", isOn: $auto)
                if auto {
                    if let w = vpn.wifi {
                        HStack {
                            Text("This Wi-Fi: \(w)")
                            Spacer()
                            let trusted = ProtonVPN.trusted.contains(w)
                            Button(trusted ? "Don't Trust" : "Trust This Network") { vpn.trust(w, !trusted) }.controlSize(.small)
                        }
                    } else {
                        Text("Onyx needs Location to see which Wi-Fi you're on (macOS keeps network names behind it). Turn it on in System Settings › Privacy & Security › Location Services.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(ProtonVPN.trusted, id: \.self) { name in
                        HStack {
                            Image(systemName: "wifi").foregroundStyle(.secondary)
                            Text(name)
                            Spacer()
                            Button { vpn.trust(name, false) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        } header: { Text("Proton VPN") } footer: {
            Text("Onyx uses macOS's own controls for the ProtonVPN connection, so Proton VPN picks the server just as if you pressed Connect there. Choose servers, Secure Core and the kill switch in Proton VPN. Add the VPN shield to the notch in Edit Tabs & Widgets, or type “vpn” in the launcher.")
        }
        .task { if vpn.status == .missing || vpn.status == .noConnection { await vpn.find() } }
    }

    private var title: String {
        switch vpn.status {
        case .missing: "Proton VPN isn't installed"
        case .noConnection: "Connect once in Proton VPN, then Onyx can control it"
        case .off: "Not connected"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .on: "Connected"
        }
    }
}
