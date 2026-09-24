import AppKit
import SwiftUI

/// Debug helper: ONYX_SNAPSHOT=/path renders every notch state to PNGs, then quits.
/// Uses a real offscreen NSHostingView + cacheDisplay so AppKit controls (Slider,
/// Menu, TextField, camera) render properly — unlike ImageRenderer, which watermarks them.
enum Snapshot {
    @MainActor static func shotView<V: View>(_ name: String, _ dir: String, size: CGSize, _ view: V) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
        }
        win.close()
    }

    @MainActor static func shot(_ name: String, _ dir: String) {
        let m = NotchModel.shared
        let size = m.geometry.windowSize
        let root = NotchRootView().environmentObject(m)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.85))
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { win.close(); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        win.close()
    }

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["ONYX_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let m = NotchModel.shared
            m.expanded = false; m.hud = nil; shot("collapsed", dir)
            // Deterministic idle-collapsed: forces activity .none so glances (battery/weather) show,
            // on a mid-gray bg so both the black pill and the white text are visible.
            let pillW = m.geometry.notchWidth + 160
            let idle = ZStack {
                NotchBackground(shape: NotchShape(top: 6, bottom: 10), expanded: false)
                    .frame(width: pillW, height: m.geometry.notchHeight)
                CollapsedView(activity: .none).environmentObject(m)
                    .frame(width: pillW, height: m.geometry.notchHeight)
            }
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
            shotView("coll-idle", dir, size: CGSize(width: 520, height: 90),
                     idle.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 8).background(Color(white: 0.3)))
            m.hud = .volume(0.6, muted: false); shot("hud-volume", dir)
            m.hud = .brightness(0.4); shot("hud-brightness", dir)
            m.hud = .charging(82, plugged: true); shot("hud-charging", dir)
            m.hud = nil
            FocusTimer.shared.begin(minutes: 25); shot("timer", dir); FocusTimer.shared.cancel()
            m.expanded = true
            for t in NotchTab.allCases { m.tab = t; shot("tab-\(t.rawValue)", dir) }
            m.tab = .home
            HomeLayout.shared.editing = true; shot("home-edit", dir); HomeLayout.shared.editing = false
            HomeLayout.shared.panels = [.weather, .clock, .stocks]; shot("home-swapped", dir)
            HomeLayout.shared.panels = [.music, .calendar]
            WidgetLayout.shared.editing = true; shot("tab-home-edit", dir); WidgetLayout.shared.editing = false
            shotView("settings", dir, size: CGSize(width: 760, height: 580), SettingsView())
            shotView("search-results", dir, size: CGSize(width: 228, height: 300),
                     VStack(spacing: 6) {
                         SettingsSearchField(text: .constant("volume")) {}
                         SettingsSearchResults(results: SettingsIndex.search("volume")) { _ in }
                     }.padding(8).frame(maxHeight: .infinity, alignment: .top).background(SidebarBackground()).environment(\.colorScheme, .dark))
            shotView("behavior", dir, size: CGSize(width: 500, height: 1500), BehaviorSettings().background(DetailBackground()).environment(\.colorScheme, .dark))
            shotView("privacy", dir, size: CGSize(width: 520, height: 560), LockSettings().background(DetailBackground()).environment(\.colorScheme, .dark))
            // Fun mode + bookshelf (settings restored afterwards).
            let d = UserDefaults.standard
            let oldFun = d.bool(forKey: Fun.enabled), oldTool = d.string(forKey: "toolsSelection"), oldPanels = HomeLayout.shared.panels
            d.set(true, forKey: Fun.enabled)
            m.expanded = true; m.tab = .home
            HomeLayout.shared.panels = [.fun, .music]; shot("fun-home", dir)
            FocusTimer.shared.begin(minutes: 10); FocusTimer.shared.endDate = Date().addingTimeInterval(360)
            m.tab = .tools; d.set("Timer", forKey: "toolsSelection"); shot("fun-bomb", dir)
            FocusTimer.shared.cancel()
            d.set("Fun", forKey: "toolsSelection"); shot("fun-tools", dir)
            m.tab = .shelf; shot("bookshelf", dir)
            if let sd = ProcessInfo.processInfo.environment["ONYX_SNAPSHOT_SHELFDIR"] {
                let old = ShelfStore.shared.items
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: sd)) ?? []).sorted().map { URL(fileURLWithPath: sd + "/" + $0) }
                ShelfStore.shared.items = files; shot("bookshelf-full", dir)
                HomeLayout.shared.panels = [.shelf, .fun]; m.tab = .home; shot("bookshelf-home", dir)
                ShelfStore.shared.items = old   // not saved: the user's shelf is untouched
            }
            shotView("fun-settings", dir, size: CGSize(width: 520, height: 1500), FunSettings().background(DetailBackground()).environment(\.colorScheme, .dark))
            HomeLayout.shared.panels = oldPanels
            d.set(oldFun, forKey: Fun.enabled)
            if let oldTool { d.set(oldTool, forKey: "toolsSelection") } else { d.removeObject(forKey: "toolsSelection") }
            exit(0)
        }
    }
}
