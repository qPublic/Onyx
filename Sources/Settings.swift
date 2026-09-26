import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, layout, behavior, widgets, live, optimize, fun, lock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .layout: "Size & Position"
        case .behavior: "Behavior"
        case .widgets: "Widgets & Tabs"
        case .live: "Live"
        case .optimize: "Optimization"
        case .fun: "Fun Mode"
        case .lock: "Privacy"
        }
    }
    var subtitle: String {
        switch self {
        case .appearance: "Style, color and depth"
        case .layout: "Dimensions and placement"
        case .behavior: "Opening, motion and system"
        case .widgets: "Boxes, header widgets and tabs"
        case .live: "Sports, markets and weather"
        case .optimize: "Clean, maintain and tweak"
        case .fun: "Goose, sounds and silliness"
        case .lock: "Permissions and AI"
        }
    }
    var icon: String {
        switch self {
        case .appearance: "paintbrush.fill"
        case .layout: "arrow.up.left.and.arrow.down.right"
        case .behavior: "hand.tap.fill"
        case .widgets: "square.grid.2x2.fill"
        case .live: "chart.line.uptrend.xyaxis"
        case .optimize: "gauge.with.dots.needle.67percent"
        case .fun: "party.popper.fill"
        case .lock: "hand.raised.fill"
        }
    }
    var tint: [Color] {
        switch self {
        case .appearance: [Color(hex: "FF5FA2"), Color(hex: "A24BFF")]
        case .layout: [Color(hex: "2E9BFF"), Color(hex: "0A63E6")]
        case .behavior: [Color(hex: "FF9F0A"), Color(hex: "FF6A00")]
        case .widgets: [Color(hex: "30D0C6"), Color(hex: "0AA6B8")]
        case .live: [Color(hex: "34C759"), Color(hex: "16A34A")]
        case .optimize: [Color(hex: "0A84FF"), Color(hex: "5E5CE6")]
        case .fun: [Color(hex: "FFD60A"), Color(hex: "FF375F")]
        case .lock: [Color(hex: "8E8E93"), Color(hex: "5B5B60")]
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .appearance
    @State private var query = ""
    @State private var found: SettingEntry?     // the setting a search jumped to (shown as a banner)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 3) {
                sidebarHeader
                SettingsSearchField(text: $query) { if let first = results.first { open(first) } }
                    .padding(.horizontal, 4).padding(.bottom, 6)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(SettingsSection.allCases.filter { $0 != .optimize }) { section in   // Optimization has its own window
                        SidebarRow(section: section, selected: selection == section) {
                            withAnimation(.smooth(duration: 0.28)) { selection = section; found = nil }
                        }
                    }
                } else {
                    SettingsSearchResults(results: results) { open($0) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 228)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SidebarBackground())

            Divider()

            ZStack(alignment: .top) {
                ForEach(SettingsSection.allCases) { section in
                    if section == selection {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 10) {
                                IconTile(symbol: section.icon, colors: section.tint)
                                Text(section.title).font(.system(size: 17, weight: .bold))
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
                            if let f = found, f.section == section {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkle.magnifyingglass")
                                    Text("\(f.title)").fontWeight(.semibold)
                                    Text("is under \(f.group)").foregroundStyle(.secondary)
                                    Spacer()
                                    Button { withAnimation { found = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                                .padding(.horizontal, 20).padding(.top, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            detail(section)
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.28), value: selection)
            .background(DetailBackground())
        }
        .frame(width: 760, height: 580)
    }

    private var results: [SettingEntry] { SettingsIndex.search(query) }

    private func open(_ e: SettingEntry) {
        // Optimization has its own window: open it on the page the setting is on.
        if e.section == .optimize {
            if let p = OptimizePage.allCases.first(where: { $0.title == e.group }) { UserDefaults.standard.set(p.rawValue, forKey: Opt.page) }
            query = ""
            (NSApp.delegate as? AppDelegate)?.openOptimization()
            return
        }
        withAnimation(.smooth(duration: 0.28)) { selection = e.section; found = e }
        query = ""
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "3A3A48"), Color(hex: "0B0B12")], startPoint: .top, endPoint: .bottom))
                Capsule().fill(.black).frame(width: 22, height: 7).overlay(alignment: .leading) {
                    Circle().fill(LinearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 5, height: 5).padding(.leading, 3)
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Onyx").font(.system(size: 15, weight: .bold))
                    Text("MacOS").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Everything free").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.clear)
    }

    @ViewBuilder private func detail(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance: AppearanceSettings()
        case .layout: LayoutSettings()
        case .behavior: BehaviorSettings()
        case .widgets: WidgetsSettings()
        case .live: LiveSettings()
        case .optimize: OptimizeSettings()
        case .fun: FunSettings()
        case .lock: LockSettings()
        }
    }
}

/// A polished, selectable sidebar row (System-Settings feel).
struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: section.icon, colors: section.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title).font(.system(size: 12.5, weight: .semibold))
                    Text(section.subtitle).font(.system(size: 9.5)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(AP.accentColor.opacity(0.9))
                                   : AnyShapeStyle(hover ? Color.primary.opacity(0.08) : Color.clear))
            }
            .foregroundStyle(selected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Translucent sidebar backing (vibrancy on-screen, solid fallback offscreen).
struct SidebarBackground: View {
    var body: some View {
        ZStack {
            Color(hex: "111119")
            VisualEffectSidebar()
        }
        .ignoresSafeArea()
    }
}

struct VisualEffectSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Detail-pane backing that matches the macOS grouped-form background.
struct DetailBackground: View {
    var body: some View { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
}

/// System-Settings-style rounded gradient icon tile.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: colors.first!.opacity(0.4), radius: 2, y: 1)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @ObservedObject var hw = NotchHardware.shared
    @AppStorage(AP.style) var style = NotchStyle.solid.rawValue
    @AppStorage(AP.glassVariant) var glassVariant = "regular"
    @AppStorage(AP.clearBlur) var clearBlur = true
    @AppStorage(AP.clearDropBelow) var clearDropBelow = false
    @AppStorage(AP.styleCollapsed) var styleCollapsed = false
    @AppStorage(AP.tintStrength) var tintStrength = 0.25
    @AppStorage(AP.shadow) var shadow = 0.5
    @AppStorage(AP.border) var border = false

    var body: some View {
        Form {
            Section("Style") {
                Picker("Notch material", selection: $style) {
                    ForEach(NotchStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if style == NotchStyle.glass.rawValue {
                    Picker("Glass", selection: $glassVariant) {
                        Text("Regular").tag("regular"); Text("Clear").tag("clear")
                    }
                    if glassVariant == "clear" {
                        Toggle("Blur what's behind it", isOn: $clearBlur)
                        Toggle("Open below the menu bar", isOn: $clearDropBelow)
                            .help("Keeps menu text out from under the glass edge so it doesn't warp. Off keeps the notch attached to the top of the screen.")
                        Text("Fully see-through glass that bends the background at its edges. Text switches between white and black to stay readable against what's behind it (uses Screen Recording).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if hw.builtIn {
                    Text("Your Mac has a built-in notch, so the closed notch stays black to blend in with it. This style shows when it opens.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Use this style even when collapsed", isOn: $styleCollapsed)
                        .help("Off keeps the idle notch solid black so it blends with a hardware notch.")
                }
            }
            Section("Colors") {
                ColorPicker("Accent", selection: hexColorBinding(AP.accent), supportsOpacity: false)
                if style == NotchStyle.solid.rawValue {
                    ColorPicker("Background", selection: hexColorBinding(AP.bgColor), supportsOpacity: false)
                } else {
                    ColorPicker("Tint", selection: hexColorBinding(AP.tint), supportsOpacity: false)
                    LabeledContent("Tint strength") { Slider(value: $tintStrength, in: 0...0.9) }
                }
            }
            Section("Depth") {
                LabeledContent("Shadow") { Slider(value: $shadow, in: 0...1) }
                Toggle("Show a subtle border", isOn: $border)
            }
            Section {
                Button("Reset appearance to defaults") { AP.reset() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Size & position

struct LayoutSettings: View {
    @ObservedObject var hw = NotchHardware.shared
    @AppStorage(AP.expW) var expW = 680.0
    @AppStorage(AP.expH) var expH = 270.0
    @AppStorage(AP.collW) var collW = 0.0
    @AppStorage(AP.collH) var collH = 0.0
    @AppStorage(AP.earScale) var earScale = 1.0
    @AppStorage(AP.placement) var placement = Placement.attached.rawValue
    @AppStorage(AP.topGap) var topGap = 8.0
    @AppStorage(AP.hOffset) var hOffset = 0.0
    @AppStorage(AP.display) var display = "auto"

    var body: some View {
        Form {
            Section("Expanded size") {
                slider("Width", $expW, 520...1000, "pt")
                slider("Height", $expH, 220...460, "pt")
                if hw.builtIn {
                    Text("On this Mac it's at least \(Int(NotchModel.shared.geometry.minOpenWidth))pt wide, so your tabs and buttons fit around the camera.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Collapsed size") {
                slider("Width adjust", $collW, -80...260, "pt")
                slider("Height adjust", $collH, -6...24, "pt")
                slider("Side widget room", $earScale, 0.6...1.8, "×")
                if hw.builtIn {
                    Text("It never gets smaller than your Mac's built-in notch.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Position") {
                Picker("Placement", selection: $placement) {
                    ForEach(Placement.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if placement == Placement.floating.rawValue {
                    slider("Gap from top", $topGap, 0...60, "pt")
                }
                if hw.builtIn {
                    Text("Onyx stays centered on your Mac's built-in notch, and opens around the camera.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    slider("Horizontal offset", $hOffset, -600...600, "pt")
                }
                Picker("Show on display", selection: $display) {
                    Text("Automatic (notch display)").tag("auto")
                    Text("Built-in display").tag("builtin")
                    Text("Primary display").tag("primary")
                    Text("Display under the mouse").tag("mouse")
                    ForEach(NSScreen.screens, id: \.self) { s in
                        Text(s.localizedName).tag(s.localizedName)
                    }
                }
            }
            Section { Button("Reset size & position") {
                for k in [AP.expW, AP.expH, AP.collW, AP.collH, AP.earScale, AP.topGap, AP.hOffset] { UserDefaults.standard.removeObject(forKey: k) }
                placement = Placement.attached.rawValue; display = "auto"
            } }
        }
        .formStyle(.grouped)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range)
                Text(unit == "×" ? String(format: "%.1f×", value.wrappedValue) : "\(Int(value.wrappedValue))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
    }
}

// MARK: - Behavior

struct BehaviorSettings: View {
    @AppStorage(AP.openOn) var openOn = OpenTrigger.hover.rawValue
    @AppStorage(AP.closeOnLeave) var closeOnLeave = true
    @AppStorage(AP.closeDelay) var closeDelay = 1.5
    @AppStorage(Prefs.hoverDelay) var hoverDelay = 0.12
    @AppStorage(AP.animation) var animation = AnimationStyle.bouncy.rawValue
    @AppStorage(AP.haptics) var haptics = true
    @AppStorage(AP.hideFullscreen) var hideFullscreen = true
    @AppStorage(AP.hideFromCapture) var hideFromCapture = true
    @AppStorage(AP.snapLayouts) var snapLayouts = true
    @AppStorage(AP.hudPopup) var hudPopup = true
    @AppStorage(AP.userHidden) var userHidden = false
    @AppStorage(AP.dodgeMenus) var dodgeMenus = true
    @AppStorage(AP.interceptVolume) var interceptVolume = true
    @AppStorage(AP.menuBarIcon) var menuBarIcon = true
    @State private var loginItem = LoginItem.enabled
    @State private var axTrusted = MenuBarDodger.shared.trusted

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open on", selection: $openOn) {
                    ForEach(OpenTrigger.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if openOn == OpenTrigger.hover.rawValue {
                    LabeledContent("Hover delay") {
                        Slider(value: $hoverDelay, in: 0...0.6) { Text("") } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("0.6s") }
                    }
                }
                Toggle("Close when the pointer leaves", isOn: $closeOnLeave)
                if closeOnLeave {
                    LabeledContent("Close delay") {
                        HStack {
                            Slider(value: $closeDelay, in: 0...3)
                            Text(closeDelay < 0.05 ? "Instant" : String(format: "%.2gs", closeDelay))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Motion") {
                Picker("Animation", selection: $animation) {
                    ForEach(AnimationStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Haptic feedback on open", isOn: $haptics)
            }
            Section("System") {
                Toggle("Hide while an app is fullscreen", isOn: $hideFullscreen)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Snap layouts", isOn: $snapLayouts)
                    Text("Drag a window up to the notch to pick a layout: halves, top/bottom, thirds, quarters and more. Needs Accessibility.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Hide from screen recordings & shares", isOn: $hideFromCapture)
                    Text("You still see the notch, but it's left out of screenshots, recordings, and screen sharing (Zoom, Meet, etc.).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep clear of app menus", isOn: $dodgeMenus)
                        .onChange(of: dodgeMenus) { _, on in if on { MenuBarDodger.shared.requestAccess() } }
                    HStack(spacing: 6) {
                        Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axTrusted ? .green : .orange)
                        Text(axTrusted ? "Accessibility granted" : "Accessibility needed")
                        Button("Open Settings") { MenuBarDodger.shared.openAccessibilityPane() }
                            .buttonStyle(.link)
                        Button("Re-check") { axTrusted = MenuBarDodger.shared.trusted }
                            .buttonStyle(.link)
                    }.font(.caption)
                    Text("Slides the notch aside only when the active app's menus (e.g. Chrome's Help) would reach it. On a Mac with a built-in notch, the side widgets fold away and live activities hang below the camera instead. If you weren't prompted, click Open Settings and enable Onyx in the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Replace the volume & brightness sliders", isOn: $interceptVolume)
                        .onChange(of: interceptVolume) { _, on in
                            if on { MenuBarDodger.shared.requestAccess() }
                            MediaKeys.shared.refresh()
                        }
                    Text("Shows Onyx's own volume and brightness HUD in the notch and hides the built-in macOS sliders. Also needs Accessibility.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Pop-out style", isOn: $hudPopup)
                    Text("The HUD drops down from the notch with a bigger bar. Off shows it compactly beside the notch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show menu bar icon", isOn: $menuBarIcon)
                Toggle("Open at login", isOn: $loginItem).onChange(of: loginItem) { _, v in LoginItem.set(v) }
            }
            UpdateSettings()
            Section {
                Toggle("Hide the notch completely", isOn: $userHidden)
                Text("Fully removes the notch from the screen — for tests, exams or presentations. Toggle it back anytime with its shortcut (below) or the menu bar icon. This is remembered until you turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Hide notch") }
            Section {
                ForEach(HotAction.allCases) { a in
                    LabeledContent(a.title) { ShortcutRecorder(action: a) }
                }
                LabeledContent("Close notch", value: "Esc")
                Button("Restore default shortcuts") { Shortcuts.reset() }
            } header: { Text("Shortcuts") } footer: {
                Text("Click a shortcut, then press the new keys (must include ⌘, ⌥ or ⌃). Esc cancels, ✕ clears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Widgets & tabs

struct WidgetsSettings: View {
    @ObservedObject var hw = NotchHardware.shared
    @ObservedObject var layout = WidgetLayout.shared
    @ObservedObject var home = HomeLayout.shared
    @AppStorage(AP.tabs) var tabs = ""
    @AppStorage(AP.defaultTab) var defaultTab = "last"
    @AppStorage(AP.homeAfterIdle) var homeAfterIdle = true
    @AppStorage(AP.homeAfterSeconds) var homeAfterSeconds = 5.0
    @AppStorage(AP.collLeft) var collLeft = "battery"
    @AppStorage(AP.collMid) var collMid = ""
    @AppStorage(AP.collRight) var collRight = "weather"
    @AppStorage(AP.bookshelf) var bookshelf = true
    @AppStorage(AP.shelfStays) var shelfStays = true
    @AppStorage(AP.musicCow) var musicCow = false
    @AppStorage(AP.cowBeat) var cowBeat = true

    var body: some View {
        Form {
            Section {
                Text("Live readouts shown on the collapsed pill. Timers and live scores briefly take over when active; everything else, including Now Playing, stays put where you place it.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Left side", selection: $collLeft) {
                    Text("None").tag("")
                    ForEach(NotchWidget.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
                }
                if !hw.builtIn {   // with a built-in notch, the center is behind the camera
                    Picker("Center", selection: $collMid) {
                        Text("None").tag("")
                        ForEach(NotchWidget.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
                    }
                }
                Picker("Right side", selection: $collRight) {
                    Text("None").tag("")
                    ForEach(NotchWidget.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
                }
            } header: { Text("Collapsed notch") }

            Section {
                Text("Drag to reorder. These appear in the top bar of the expanded notch.").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(layout.widgets) { w in
                        HStack {
                            Image(systemName: w.icon).frame(width: 22).foregroundStyle(.cyan)
                            Text(w.title)
                            Spacer()
                            Button { layout.toggle(w) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                        }
                    }
                    .onMove { layout.move(from: $0, to: $1) }
                }
                .frame(height: 150)
                Menu("Add widget") {
                    ForEach(NotchWidget.allCases) { w in
                        Button { layout.toggle(w) } label: { Label(w.title, systemImage: layout.contains(w) ? "checkmark" : w.icon) }
                    }
                }
            } header: { Text("Header widgets") }

            Section {
                Text("The big boxes on the Home tab. Reorder with the arrows.").font(.caption).foregroundStyle(.secondary)
                ForEach(home.panels) { p in
                    HStack {
                        Image(systemName: p.icon).frame(width: 22).foregroundStyle(.cyan)
                        Text(p.title)
                        Spacer()
                        Button { home.move(p, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(home.panels.first == p)
                        Button { home.move(p, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(home.panels.last == p)
                        Button { home.toggle(p) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain).disabled(home.panels.count <= 1)
                    }
                }
                Menu("Add box") {
                    ForEach(HomePanel.allCases) { p in
                        Button { home.toggle(p) } label: { Label(p.title, systemImage: home.contains(p) ? "checkmark" : p.icon) }
                    }
                }
                Toggle("Dancing cow under Now Playing", isOn: $musicCow)
                if musicCow {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Dance to the beat", isOn: $cowBeat)
                        Text("Matches the cow's steps to the song's tempo. The tempo is looked up by song title and artist on Deezer; songs it doesn't know get the normal dance.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Home boxes") }

            Section("File Shelf") {
                Toggle("Bookshelf look", isOn: $bookshelf)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep the Shelf open until you close it", isOn: $shelfStays)
                    Text("Clicking somewhere else or switching apps won't close it. Close it with the × button at the top right of the notch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Files you stash become books on a wooden shelf, filling in the empty slots as you add more.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Tabs") {
                let order = AP.enabledTabs + NotchTab.allCases.filter { !AP.enabledTabs.contains($0) }
                ForEach(order) { t in
                  HStack {
                    Toggle(isOn: Binding(
                        get: { Prefs.list(AP.tabs).contains(t.rawValue) || Prefs.string(AP.tabs).isEmpty },
                        set: { on in
                            var set = Prefs.list(AP.tabs).isEmpty ? NotchTab.allCases.map(\.rawValue) : Prefs.list(AP.tabs)
                            set.removeAll { $0 == t.rawValue }
                            if on { set.append(t.rawValue) }
                            tabs = set.joined(separator: ",")
                        })) {
                        Label(t.title, systemImage: t.icon)
                    }
                    if let i = AP.enabledTabs.firstIndex(of: t) {
                        Button { moveTab(i, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(i == 0)
                        Button { moveTab(i, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(i == AP.enabledTabs.count - 1)
                    }
                  }
                }
                Text("You can also edit tabs right in the notch: ⋯ › Edit Tabs & Widgets, then drag tabs to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default tab when opened", selection: $defaultTab) {
                    Text("Last used").tag("last")
                    ForEach(NotchTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if defaultTab == "last" {
                    Toggle("Go back to Home if it's been closed a while", isOn: $homeAfterIdle)
                    if homeAfterIdle {
                        LabeledContent("After") {
                            HStack {
                                Slider(value: $homeAfterSeconds, in: 1...60, step: 1)
                                Text("\(Int(homeAfterSeconds))s").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            }
                        }
                        Text("Reopen within this time and it stays on the tab you were using.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func moveTab(_ i: Int, by d: Int) {
        var t = AP.enabledTabs
        guard t.indices.contains(i + d) else { return }
        t.swapAt(i, i + d)
        AP.setTabs(t)
    }
}

// MARK: - Live (sports / markets / weather)

struct LiveSettings: View {
    @AppStorage(Prefs.favoriteTeams) var favoriteTeams = ""
    @AppStorage(Prefs.watchlist) var watchlist = ""
    @AppStorage(Prefs.weatherCity) var weatherCity = ""
    @AppStorage(Prefs.fahrenheit) var fahrenheit = true
    @AppStorage(Prefs.sportsActivity) var sportsActivity = true
    @AppStorage(Prefs.tickerActivity) var tickerActivity = false
    @AppStorage(Prefs.downloadActivity) var downloadActivity = true
    @AppStorage(Prefs.downloadToShelf) var downloadToShelf = true

    var body: some View {
        Form {
            CanvasSettingsSection()
            Section("Live activities in the notch") {
                Toggle("Live games for favorite teams", isOn: $sportsActivity)
                Toggle("Stock ticker", isOn: $tickerActivity)
                Toggle("Download progress", isOn: $downloadActivity)
                Toggle("Put finished downloads on the Shelf", isOn: $downloadToShelf)
                Text("Now Playing no longer takes over the notch — add it as a collapsed-notch widget in Widgets to keep it in a fixed spot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Leagues") {
                ForEach(League.all) { l in
                    Toggle(l.name, isOn: Binding(
                        get: { Prefs.list(Prefs.leagues).contains(l.id) },
                        set: { on in
                            var set = Prefs.list(Prefs.leagues).filter { $0 != l.id }
                            if on { set.append(l.id) }
                            UserDefaults.standard.set(set.joined(separator: ","), forKey: Prefs.leagues)
                            SportsService.shared.refreshAll()
                        }))
                }
            }
            Section {
                TextField("Favorite teams", text: $favoriteTeams, prompt: Text("GB, LAL, NYY"))
            } header: { Text("Favorite teams") } footer: { Text("Abbreviations, comma separated.") }
            Section {
                TextField("Symbols", text: $watchlist, prompt: Text("AAPL, NVDA, ^GSPC, BTC-USD"))
                    .onSubmit { MarketsService.shared.refresh() }
            } header: { Text("Markets watchlist") } footer: { Text("Stocks, indexes, ETFs, crypto. Press Return to refresh.") }
            Section("Weather") {
                TextField("City", text: $weatherCity, prompt: Text("Automatic")).onSubmit { Task { await WeatherService.shared.refresh() } }
                Toggle("Fahrenheit", isOn: $fahrenheit).onChange(of: fahrenheit) { _, _ in Task { await WeatherService.shared.refresh() } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy & Lock

struct LockSettings: View {
    @AppStorage(AIEffort.key) private var effort = AIEffort.medium.rawValue
    var body: some View {
        Form {
            Section("Permissions") {
                permission("Screen Recording", "Circle to Search, AI screen reading", "Privacy_ScreenCapture")
                permission("Calendars & Reminders", "Calendar widget & AI agent", "Privacy_Calendars")
                permission("Automation", "Spotify & Apple Music", "Privacy_Automation")
                permission("Camera", "Mirror", "Privacy_Camera")
                Button("Re-run setup…") { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
            }
            Section("AI") {
                LabeledContent("Model", value: "Apple on-device (free, private)")
                LabeledContent("Status", value: Assistant.shared.unavailableReason ?? "Ready")
                Picker("Effort", selection: $effort) {
                    ForEach(AIEffort.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text((AIEffort(rawValue: effort) ?? .medium).detail + " You can also change it in the AI tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func permission(_ name: String, _ why: String, _ anchor: String) -> some View {
        LabeledContent {
            Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!) }
        } label: {
            VStack(alignment: .leading) { Text(name); Text(why).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
