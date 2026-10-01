import AppKit
import SwiftUI

// MARK: - App Launcher: every app in a full-screen Liquid Glass grid, with pages, folders and instant search

struct LaunchApp: Hashable, Identifiable {
    let path: String
    let name: String
    var category = "Other"   // from the app's LSApplicationCategoryType, like "Productivity"
    var id: String { path }
}

/// The top level of the launcher: an app, or a folder of apps (in your order).
enum LaunchItem: Codable, Hashable, Identifiable {
    case app(String)                                    // the app's path
    case folder(id: String, name: String, apps: [String])
    var id: String { switch self { case .app(let p): p; case .folder(let id, _, _): id } }
}

@MainActor final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()
    @Published private(set) var apps: [String: LaunchApp] = [:]
    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var pinned: [String] = []   // always first, in this order
    @Published var byCategory = UserDefaults.standard.bool(forKey: "launcher.byCategory") {
        didSet { UserDefaults.standard.set(byCategory, forKey: "launcher.byCategory") }
    }
    private var icons: [String: NSImage] = [:]
    private var file: URL { Prefs.supportDir.appendingPathComponent("launcher.json") }
    private struct Saved: Codable { var items: [LaunchItem]; var hidden: [String]; var pinned: [String]? }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) { items = s.items; hidden = Set(s.hidden); pinned = s.pinned ?? [] }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(items: items, hidden: Array(hidden), pinned: pinned)) { try? d.write(to: file, options: .atomic) }
    }

    func icon(_ path: String) -> NSImage {
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons[path] = i
        return i
    }

    /// Finds installed apps; new ones go at the end, deleted ones disappear, your order and folders stay.
    func refresh() async {
        let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
        apps = Dictionary(found.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var kept: [LaunchItem] = items.compactMap { item in
            switch item {
            case .app(let p): guard apps[p] != nil, seen.insert(p).inserted else { return nil }; return item
            case .folder(let id, let name, let list):
                let l = list.filter { apps[$0] != nil && seen.insert($0).inserted }
                return l.isEmpty ? nil : .folder(id: id, name: name, apps: l)
            }
        }
        let new = found.filter { !seen.contains($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        kept += new.map { .app($0.path) }
        if kept != items { items = kept; save() }
    }

    nonisolated static func scan() -> [LaunchApp] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        var out: [LaunchApp] = []
        func add(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(n)
                if n.hasSuffix(".app") {
                    var name = fm.displayName(atPath: p)
                    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                    let type = NSDictionary(contentsOfFile: p + "/Contents/Info.plist")?["LSApplicationCategoryType"] as? String
                    out.append(LaunchApp(path: p, name: name, category: categoryName(type) ?? "Other"))
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { add(p, depth: depth - 1) }   // e.g. "Microsoft Office/"
                }
            }
        }
        add("/Applications", depth: 1)
        add("/System/Applications", depth: 1)
        add(home + "/Applications", depth: 1)
        // One entry per app, even when it's reachable from two places.
        var seen = Set<String>()
        return out.filter { seen.insert(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).inserted }
    }

    // MARK: Editing

    private func take(_ id: String) -> LaunchItem? {
        if let i = items.firstIndex(where: { $0.id == id }) { return items.remove(at: i) }
        for (i, it) in items.enumerated() {   // an app inside a folder
            if case .folder(let fid, let name, var list) = it, let j = list.firstIndex(of: id) {
                list.remove(at: j)
                items[i] = .folder(id: fid, name: name, apps: list)
                if list.isEmpty { items.remove(at: i) }
                return .app(id)
            }
        }
        return nil
    }

    /// Moves an app or folder next to another one (or to the end).
    func move(_ id: String, to target: String?, after: Bool = false) {
        guard id != target, let item = take(id) else { return }
        if let target, let i = items.firstIndex(where: { $0.id == target }) { items.insert(item, at: after ? i + 1 : i) } else { items.append(item) }
        save()
    }

    /// Drops an app onto another app (new folder) or onto a folder (adds it).
    func combine(_ id: String, onto target: String) {
        guard id != target, apps[id] != nil, items.contains(where: { $0.id == target }) else { return }
        guard let item = take(id), case .app(let path) = item, let i = items.firstIndex(where: { $0.id == target }) else { return }
        switch items[i] {
        case .app(let other):
            items[i] = .folder(id: UUID().uuidString, name: Self.folderName(for: [other, path], apps: apps), apps: [other, path])
        case .folder(let fid, let name, let list):
            items[i] = .folder(id: fid, name: name, apps: list + [path])
        }
        save()
    }

    func moveOutOfFolder(_ path: String) {
        guard let item = take(path) else { return }
        items.append(item); save()
    }

    func rename(folder id: String, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .folder(_, _, let list) = items[i] else { return }
        items[i] = .folder(id: id, name: name.isEmpty ? "Folder" : name, apps: list); save()
    }

    func hide(_ path: String) { hidden.insert(path); pinned.removeAll { $0 == path }; save() }
    func pin(_ path: String) { if !pinned.contains(path) { pinned.append(path); save() } }
    func unpin(_ path: String) { pinned.removeAll { $0 == path }; save() }
    func showHidden() { hidden = []; save() }
    func resetLayout() { items = []; save(); Task { await refresh() } }

    func open(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    /// Names a new folder after what's in it, the way Launchpad did ("Utilities", "Games"…), else "Folder".
    static func folderName(for paths: [String], apps: [String: LaunchApp]) -> String {
        let cats = paths.compactMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        guard let c = cats.first, cats.allSatisfy({ $0 == c }) else { return "Folder" }
        return categoryName(c) ?? "Folder"
    }

    /// "public.app-category.developer-tools" → "Developer".
    nonisolated static func categoryName(_ type: String?) -> String? {
        guard let type else { return nil }
        let names = ["games": "Games", "productivity": "Productivity", "utilities": "Utilities", "developer-tools": "Developer",
                     "graphics-design": "Design", "social-networking": "Social", "music": "Music", "video": "Video", "photography": "Photos",
                     "education": "Education", "business": "Business", "entertainment": "Entertainment", "finance": "Finance", "news": "News",
                     "reference": "Reference", "books": "Books", "travel": "Travel", "weather": "Weather", "lifestyle": "Lifestyle",
                     "sports": "Sports", "healthcare-fitness": "Health & Fitness", "medical": "Health & Fitness"]
        return names.first { type.hasSuffix($0.key) }?.value
    }

    // MARK: What's shown

    /// Your layout, with pinned apps pulled out of it (and out of folders) to the front.
    var visible: [LaunchItem] {
        let pins = pinned.filter { apps[$0] != nil && !hidden.contains($0) }
        return pins.map { .app($0) } + items.compactMap { item in
            switch item {
            case .app(let p): return hidden.contains(p) || pins.contains(p) ? nil : item
            case .folder(let id, let name, let list):
                let l = list.filter { !hidden.contains($0) && !pins.contains($0) }
                return l.isEmpty ? nil : .folder(id: id, name: name, apps: l)
            }
        }
    }

    /// By category: pinned apps, then each category A–Z (Other last), apps A–Z within it.
    var sections: [(name: String, apps: [LaunchApp])] {
        let pins = pinned.compactMap { apps[$0] }.filter { !hidden.contains($0.path) }
        let rest = apps.values.filter { !hidden.contains($0.path) && !pinned.contains($0.path) }
        let groups = Dictionary(grouping: rest, by: \.category).map { (name: $0.key, apps: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { ($0.name == "Other" ? 1 : 0, $0.name) < ($1.name == "Other" ? 1 : 0, $1.name) }
        return (pins.isEmpty ? [] : [(name: "Pinned", apps: pins)]) + groups
    }

    /// Search: names that start with what you typed first, then words that do, then anywhere in the name.
    func search(_ q: String) -> [LaunchApp] {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func rank(_ a: LaunchApp) -> Int? {
            let n = a.name.lowercased()
            if n.hasPrefix(q) { return 0 }
            if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            if n.contains(q) { return 2 }
            let initials = String(n.split(separator: " ").compactMap(\.first))
            return initials.hasPrefix(q) && q.count > 1 ? 3 : nil
        }
        return apps.values.filter { !hidden.contains($0.path) }
            .compactMap { a in rank(a).map { (a, $0) } }
            .sorted { (pinned.contains($0.0.path) ? 0 : 1, $0.1, $0.0.name.count, $0.0.name) < (pinned.contains($1.0.path) ? 0 : 1, $1.1, $1.0.name.count, $1.0.name) }
            .map(\.0)
    }
}

// MARK: - The full-screen panel

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Page changes from the mouse wheel and arrow keys.
@MainActor final class LauncherNav: ObservableObject {
    @Published var page = 0
    var pageCount = 1
    func step(_ d: Int) { page = min(max(page + d, 0), pageCount - 1) }
}

@MainActor final class AppLauncher {
    static let shared = AppLauncher()
    private var panel: LauncherPanel?
    private var monitor: Any?
    private var resign: Any?
    private var wheelSum: CGFloat = 0
    let nav = LauncherNav()
    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        NotchController.current?.collapse()
        let p = LauncherPanel(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)   // over the Dock and menu bar, under the notch
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.setFrame(screen.frame, display: false)
        nav.page = 0
        p.contentView = NSHostingView(rootView: LauncherView(nav: nav) { [weak self] in self?.close() }.motionAware())
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        Task { await LauncherStore.shared.refresh() }
        // A mouse wheel flips pages, like Launchpad (trackpads swipe the pages directly).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, !e.hasPreciseScrollingDeltas, !LauncherStore.shared.byCategory else { return e }   // by category, it scrolls
            wheelSum += e.scrollingDeltaY
            if abs(wheelSum) > 3 { nav.step(wheelSum > 0 ? -1 : 1); wheelSum = 0 }
            return nil
        }
        // Clicking another app or switching away closes it.
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }; resign = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        } completionHandler: { p.orderOut(nil) }
    }
}

// MARK: - Views

struct LauncherView: View {
    @ObservedObject var store = LauncherStore.shared
    @ObservedObject var nav: LauncherNav
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @State private var openFolder: String?
    @State private var appeared = false
    @State private var renaming = ""
    @State private var files: [URL] = []            // files whose names match the search
    @State private var fileSearch: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack {
                LauncherBackdrop()
                    .overlay(Color.black.opacity(0.22))
                    .contentShape(Rectangle())
                    .onTapGesture { if openFolder != nil { openFolder = nil } else { close() } }
                    .dropDestination(for: String.self) { ids, _ in ids.forEach { store.move($0, to: nil) }; return true }

                VStack(spacing: 0) {
                    HStack(spacing: 10) { searchField; arrange }.padding(.top, max(geo.safeAreaInsets.top, 40) + 18)
                    if !query.isEmpty { results(m) } else if store.byCategory { categories(m) } else { pages(m, width: geo.size.width) }
                }
                if let fid = openFolder, case .folder(_, let name, let list)? = store.visible.first(where: { $0.id == fid }) {
                    folderOverlay(fid, name: name, apps: list, m: m)
                }
            }
            .scaleEffect(appeared ? 1 : 1.06)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { appeared = true }
                DispatchQueue.main.async { searchFocused = true }   // once the panel is the key window, or it doesn't take
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onKeyPress(.escape) {
            if openFolder != nil { openFolder = nil } else if !query.isEmpty { query = "" } else { close() }
            return .handled
        }
    }

    /// Grid size for this screen: Launchpad-like 7×5 on big displays, fewer on small ones.
    struct Metrics {
        let cols: Int, rows: Int, icon: CGFloat, cell: CGSize
        init(size: CGSize) {
            cols = size.width >= 1500 ? 7 : size.width >= 1150 ? 6 : 5
            rows = size.height >= 900 ? 5 : 4
            icon = min(max(size.width / 18, 64), 108)
            cell = CGSize(width: min(size.width * 0.8 / CGFloat(cols), icon * 1.9), height: icon + 44)
        }
        var perPage: Int { cols * rows }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { launchSelected() }
                .onChange(of: query) { _, q in
                    selected = 0
                    fileSearch?.cancel()
                    fileSearch = Task {   // after a short pause in typing
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        let found = await LauncherActions.files(q)
                        if !Task.isCancelled { files = found }
                    }
                }
                .onKeyPress(.leftArrow) { if query.isEmpty { withAnimation { nav.step(-1) }; return .handled } else { selected = max(selected - 1, 0); return .handled } }
                .onKeyPress(.rightArrow) { if query.isEmpty { withAnimation { nav.step(1) }; return .handled } else { selected += 1; return .handled } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 300)
        .onyxGlass(.regular, in: .capsule)
    }

    /// Your own order (pages you arrange) or by category.
    private var arrange: some View {
        Picker("", selection: $store.byCategory) {
            Image(systemName: "square.grid.3x3").help("Your order").tag(false)
            Image(systemName: "list.bullet.below.rectangle").help("By category").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 86)
    }

    // MARK: By category

    private func categories(_ m: Metrics) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.cell.width), spacing: 0), count: m.cols), spacing: 22) {
                ForEach(store.sections, id: \.name) { section in
                    Section {
                        ForEach(section.apps) { app in
                            AppTile(app: app, icon: store.icon(app.path), size: m.icon, pinned: store.pinned.contains(app.path)) { store.open(app.path); close() }
                                .frame(width: m.cell.width, height: m.cell.height)
                                .contextMenu { appMenu(app.path, inFolder: false) }
                        }
                    } header: {
                        Text(section.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).padding(.leading, 12)
                    }
                }
            }
            .frame(width: CGFloat(m.cols) * m.cell.width)
            .padding(.top, 18).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Pages

    private func pages(_ m: Metrics, width: CGFloat) -> some View {
        let items = store.visible
        let chunks = stride(from: 0, to: max(items.count, 1), by: m.perPage).map { Array(items[$0..<min($0 + m.perPage, items.count)]) }
        nav.pageCount = chunks.count
        return VStack(spacing: 18) {
            ZStack {
                ForEach(chunks.indices, id: \.self) { i in
                    grid(chunks[i], m).offset(x: CGFloat(i - nav.page) * width)   // pages slide side to side
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.spring(response: 0.45, dampingFraction: 0.88), value: nav.page)
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -60 { nav.step(1) } else if v.translation.width > 60 { nav.step(-1) }
            })
            HStack(spacing: 10) {
                ForEach(chunks.indices, id: \.self) { i in
                    Circle().fill(i == nav.page ? Color.white : Color.white.opacity(0.35)).frame(width: 8, height: 8)
                        .padding(4).contentShape(Circle())
                        .onTapGesture { withAnimation { nav.page = i } }
                        .dropDestination(for: String.self) { ids, _ in   // drop on a dot: move it to the end of that page
                            let last = chunks[i].last?.id
                            ids.forEach { store.move($0, to: last, after: true) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .onyxGlass(.regular, in: .capsule)
            .opacity(chunks.count > 1 ? 1 : 0)
            .padding(.bottom, 44)
        }
    }

    private func grid(_ items: [LaunchItem], _ m: Metrics) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.cell.width), spacing: 0), count: m.cols), spacing: 22) {
            ForEach(items) { item in tile(item, m) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 36)
    }

    @ViewBuilder private func tile(_ item: LaunchItem, _ m: Metrics) -> some View {
        switch item {
        case .app(let path):
            if let app = store.apps[path] {
                AppTile(app: app, icon: store.icon(path), size: m.icon, pinned: store.pinned.contains(path)) { store.open(path); close() }
                    .frame(width: m.cell.width, height: m.cell.height)
                    .draggable(path) { Image(nsImage: store.icon(path)).resizable().frame(width: m.icon, height: m.icon) }
                    .modifier(DropOnTile(id: path, width: m.cell.width, store: store))
                    .contextMenu { appMenu(path, inFolder: false) }
            }
        case .folder(let id, let name, let list):
            FolderTile(name: name, icons: list.prefix(9).map { store.icon($0) }, size: m.icon) {
                renaming = name
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { openFolder = id }
            }
            .frame(width: m.cell.width, height: m.cell.height)
            .draggable(id) { FolderTile(name: "", icons: list.prefix(9).map { store.icon($0) }, size: m.icon) {} }
            .modifier(DropOnTile(id: id, width: m.cell.width, store: store))
        }
    }

    @ViewBuilder private func appMenu(_ path: String, inFolder: Bool) -> some View {
        Button("Open") { store.open(path); close() }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); close() }
        if store.pinned.contains(path) { Button("Unpin") { store.unpin(path) } } else { Button("Pin to Front") { store.pin(path) } }
        if inFolder { Button("Move Out of Folder") { store.moveOutOfFolder(path) } }
        Divider()
        Button("Hide from Launcher") { store.hide(path) }
        if !store.hidden.isEmpty { Button("Show Hidden Apps") { store.showHidden() } }
        Button("Reset Layout (A–Z)") { store.resetLayout() }
    }

    // MARK: Search results

    /// Actions (math, timers, definitions, questions) on top, then matching apps, then matching files.
    private func results(_ m: Metrics) -> some View {
        let actions = LauncherActions.parse(query, close: close)
        let found = Array(store.search(query).prefix(actions.isEmpty ? m.perPage : m.perPage - m.cols))
        let pick = min(selected, actions.count + found.count - 1)
        return ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in LauncherActionRow(action: a, highlighted: i == pick) }
                if !found.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.cell.width), spacing: 0), count: m.cols), spacing: 22) {
                        ForEach(Array(found.enumerated()), id: \.element.id) { i, app in
                            AppTile(app: app, icon: store.icon(app.path), size: m.icon, highlighted: actions.count + i == pick, pinned: store.pinned.contains(app.path)) {
                                store.open(app.path); close()
                            }
                            .frame(width: m.cell.width, height: m.cell.height)
                        }
                    }
                }
                if !files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).padding(.leading, 6)
                        ForEach(files, id: \.self) { u in fileRow(u) }
                    }
                    .frame(width: 560)
                }
                if actions.isEmpty && found.isEmpty && files.isEmpty {
                    Text("No apps or files match \"\(query)\"").font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 60)
                }
            }
            .padding(.top, 36).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func fileRow(_ u: URL) -> some View {
        Button { NSWorkspace.shared.open(u); close() } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(u.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]); close() } }
    }

    private func launchSelected() {
        let actions = LauncherActions.parse(query, close: close)
        if selected < actions.count { actions[selected].run(); return }
        let found = store.search(query)
        if !found.isEmpty { store.open(found[min(selected - actions.count, found.count - 1)].path); close() }
        else if let f = files.first { NSWorkspace.shared.open(f); close() }
    }

    // MARK: Folder

    private func folderOverlay(_ id: String, name: String, apps: [String], m: Metrics) -> some View {
        let cols = min(max(Int(ceil(sqrt(Double(apps.count)))), 3), 6)
        return ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { store.rename(folder: id, to: renaming); withAnimation { openFolder = nil } }
                .dropDestination(for: String.self) { ids, _ in ids.forEach { store.moveOutOfFolder($0) }; return true }   // drag out
            VStack(spacing: 18) {
                TextField("Folder", text: $renaming)
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
                    .onSubmit { store.rename(folder: id, to: renaming) }
                    .frame(maxWidth: 360)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.cell.width), spacing: 0), count: cols), spacing: 18) {
                    ForEach(apps, id: \.self) { path in
                        if let app = store.apps[path] {
                            AppTile(app: app, icon: store.icon(path), size: m.icon) { store.open(path); close() }
                                .frame(width: m.cell.width, height: m.cell.height)
                                .draggable(path) { Image(nsImage: store.icon(path)).resizable().frame(width: m.icon, height: m.icon) }
                                .contextMenu { appMenu(path, inFolder: true) }
                        }
                    }
                }
                Text("Drag an app outside to take it out of the folder.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(28)
            .onyxGlass(.regular, in: .rect(cornerRadius: 40))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }
}

/// Dropping on a tile: its middle makes (or adds to) a folder, its left or right edge moves the app beside it.
private struct DropOnTile: ViewModifier {
    let id: String, width: CGFloat
    let store: LauncherStore
    @State private var target = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(target ? 1.12 : 1)
            .animation(.spring(response: 0.25), value: target)
            .dropDestination(for: String.self) { ids, loc in
                for dragged in ids where dragged != id {
                    if loc.x < width * 0.28 { store.move(dragged, to: id) }
                    else if loc.x > width * 0.72 { store.move(dragged, to: id, after: true) }
                    else if store.apps[dragged] != nil { store.combine(dragged, onto: id) }
                    else { store.move(dragged, to: id) }   // folders don't go inside folders
                }
                return true
            } isTargeted: { target = $0 }
    }
}

struct AppTile: View {
    let app: LaunchApp
    let icon: NSImage
    let size: CGFloat
    var highlighted = false
    var pinned = false
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .overlay(alignment: .topTrailing) {
                        if pinned {
                            Image(systemName: "pin.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(5).background(.orange, in: Circle()).shadow(radius: 2).offset(x: 4, y: -4)
                        }
                    }
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            }
            .padding(6)
            .background { if highlighted { RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.18)) } }
            .scaleEffect(hover ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(app.name)
    }
}

struct FolderTile: View {
    let name: String
    let icons: [NSImage]
    let size: CGFloat
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(size * 0.26), spacing: size * 0.05), count: 3), spacing: size * 0.05) {
                    ForEach(icons.indices, id: \.self) { i in Image(nsImage: icons[i]).resizable().frame(width: size * 0.26, height: size * 0.26) }
                }
                .frame(width: size, height: size)
                .onyxGlass(.regular, in: .rect(cornerRadius: size * 0.24))
                if !name.isEmpty {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                }
            }
            .padding(6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The blurred desktop behind the launcher.
struct LauncherBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
