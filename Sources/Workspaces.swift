import AppKit
import SwiftUI
import ApplicationServices

// MARK: - Window workspaces: save which apps are open and where their windows are ("School", "Coding"), then get it all
// back in one click. Uses Accessibility, like Snap layouts.

struct Workspace: Codable, Identifiable, Hashable {
    struct Win: Codable, Hashable { var title: String; var x, y, w, h: Double }   // screen points, top-left origin (as Accessibility uses)
    struct App: Codable, Hashable { var bundleID: String; var path: String; var name: String; var windows: [Win] }
    var id = UUID()
    var name: String
    var apps: [App]
    var saved = Date()
}

@MainActor final class Workspaces: ObservableObject {
    static let shared = Workspaces()
    @Published private(set) var list: [Workspace] = []
    @Published private(set) var restoring: String?
    private var file: URL { Prefs.supportDir.appendingPathComponent("workspaces.json") }

    init() {
        if let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode([Workspace].self, from: d) { list = l }
    }
    private func save() { if let d = try? JSONEncoder().encode(list) { try? d.write(to: file, options: .atomic) } }

    /// Every visible app (not Onyx) with its open, unminimized windows.
    func capture(name: String) -> Workspace? {
        guard AXIsProcessTrusted() else { return nil }
        var apps: [Workspace.App] = []
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && !a.isHidden && a.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard let id = a.bundleIdentifier, let url = a.bundleURL else { continue }
            let wins = Self.windows(a.processIdentifier).compactMap { w -> Workspace.Win? in
                guard let f = Self.frame(w) else { return nil }
                return Workspace.Win(title: Self.title(w), x: f.minX, y: f.minY, w: f.width, h: f.height)
            }
            if wins.isEmpty && id == "com.apple.finder" { continue }   // Finder with no windows is just the desktop
            apps.append(.init(bundleID: id, path: url.path, name: a.localizedName ?? id, windows: wins))
        }
        return apps.isEmpty ? nil : Workspace(name: name, apps: apps)
    }

    func saveCurrent(as name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let w = capture(name: n.isEmpty ? "Workspace \(list.count + 1)" : n) else { return false }
        if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(w.name) == .orderedSame }) { list[i] = w } else { list.append(w) }
        save()
        return true
    }

    func delete(_ w: Workspace) { list.removeAll { $0.id == w.id }; save() }

    /// Opens what isn't running, puts every window back where it was, and optionally hides everything else.
    func restore(_ w: Workspace, hideOthers: Bool) async {
        guard AXIsProcessTrusted() else { return }
        restoring = w.name
        defer { restoring = nil }
        for app in w.apps {
            var running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
            if running == nil {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
                running = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: cfg)
            }
            guard let r = running else { continue }
            r.unhide()
            // Wait (up to 8 s) for a newly opened app's windows to appear.
            var wins = Self.windows(r.processIdentifier)
            for _ in 0..<16 where wins.count < min(app.windows.count, 1) {
                try? await Task.sleep(for: .milliseconds(500))
                wins = Self.windows(r.processIdentifier)
            }
            var free = wins
            for saved in app.windows {
                // The same title first (a document or page), else the next window in order.
                let pick = free.firstIndex { Self.title($0) == saved.title && !saved.title.isEmpty } ?? (free.isEmpty ? nil : 0)
                guard let i = pick else { break }
                Self.setFrame(free[i], CGRect(x: saved.x, y: saved.y, width: saved.w, height: saved.h))
                free.remove(at: i)
            }
        }
        if hideOthers {
            let keep = Set(w.apps.map(\.bundleID))
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && !keep.contains(a.bundleIdentifier ?? "") && a.bundleIdentifier != Bundle.main.bundleIdentifier {
                a.hide()
            }
        }
        NotchModel.shared.flash(.message(icon: "rectangle.3.group.fill", text: "\(w.name) is ready", tint: .teal), for: 2.5)
    }

    // MARK: Accessibility helpers

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr.filter { w in
            var role: CFTypeRef?, min: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &min)
            // Not minimized, not a dialog or floating panel (some apps don't say what kind of window it is), and a real size.
            if (min as? Bool) == true { return false }
            if let sub = role as? String, sub != kAXStandardWindowSubrole as String { return false }
            return (frame(w)?.width ?? 0) > 120 && (frame(w)?.height ?? 0) > 80
        }
    }

    static func title(_ w: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v)
        return v as? String ?? ""
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success, let p, let s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var origin = r.origin, size = r.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)   // position, size, position: some apps clamp size to the old spot
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
    }
}

struct WorkspacesView: View {
    @ObservedObject var spaces = Workspaces.shared
    @State private var name = ""
    @State private var note: String?
    @AppStorage("workspaces.hideOthers") private var hideOthers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Name, like School or Coding", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 11)).onSubmit(saveNow)
                Button("Save windows", action: saveNow).controlSize(.small)
            }
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.orange) }
            if spaces.list.isEmpty {
                Text("Arrange the apps and windows you use for something, then save them here. One click puts them all back.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(spaces.list) { w in
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.3.group.fill").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(w.name).font(.system(size: 11.5, weight: .semibold))
                                Text(w.apps.map(\.name).joined(separator: ", ")).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if spaces.restoring == w.name { ProgressView().controlSize(.mini) }
                            Button("Open") { Task { await spaces.restore(w, hideOthers: hideOthers) } }.controlSize(.small).disabled(spaces.restoring != nil)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button("Update with the current windows") { _ = spaces.saveCurrent(as: w.name) }
                            Button("Delete", role: .destructive) { spaces.delete(w) }
                        }
                    }
                }
            }
            Toggle("Hide other apps when opening one", isOn: $hideOthers).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
        }
    }

    private func saveNow() {
        guard AXIsProcessTrusted() else { note = "Needs Accessibility (Settings › Privacy)."; return }
        note = spaces.saveCurrent(as: name) ? nil : "No open windows to save."
        name = ""
    }
}
