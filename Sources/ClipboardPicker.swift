import AppKit
import SwiftUI

// MARK: - Clipboard picker: a shortcut (⌃⌥V) opens your clipboard history over any app; pick one and it's pasted there

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // takes typing without making Onyx the active app, so the paste goes back
}

@MainActor final class ClipboardPicker {
    static let shared = ClipboardPicker()
    private var panel: PickerPanel?
    private var resign: Any?

    func toggle() { panel == nil ? open() : close() }

    func open() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 520, height: 430)
        let p = PickerPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: ClipboardPickerView(close: { [weak self] in self?.close() }, paste: { [weak self] c in self?.paste(c) }))
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1))
        panel = p
        p.makeKeyAndOrderFront(nil)
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let resign { NotificationCenter.default.removeObserver(resign) }; resign = nil
        panel?.orderOut(nil); panel = nil
    }

    /// Puts it on the clipboard and pastes it into the app you were in (⌘V, which needs Accessibility; without it,
    /// it's just copied).
    func paste(_ c: ClipboardHistory.Clip) {
        ClipboardHistory.shared.copy(c)
        close()
        guard AXIsProcessTrusted() else {
            NotchModel.shared.flash(.message(icon: "doc.on.clipboard", text: "Copied. Press ⌘V to paste", tint: .cyan), for: 2)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // V
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}

struct ClipboardPickerView: View {
    let close: () -> Void
    let paste: (ClipboardHistory.Clip) -> Void
    @ObservedObject var clip = ClipboardHistory.shared
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var items: [ClipboardHistory.Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = clip.clips.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }
        return Array((found.filter(\.pinned) + found.filter { !$0.pinned }).prefix(80))   // pinned snippets first
    }

    var body: some View {
        let list = items
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your clipboard", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { if selected < list.count { paste(list[selected]) } }
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text("↩ paste · ⎋ close").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if list.isEmpty {
                Text(clip.clips.isEmpty ? "Nothing copied yet." : "No clips match \"\(query)\".").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                row(c, selected: i == selected).id(c.id)
                                    .onTapGesture { paste(c) }
                                    .onHover { if $0 { selected = i } }
                                    .contextMenu {
                                        Button(c.pinned ? "Unpin" : "Pin as a snippet") { clip.togglePin(c) }
                                        Button("Copy without pasting") { clip.copy(c); close() }
                                        Button("Delete", role: .destructive) { clip.delete(c) }
                                    }
                            }
                        }
                    }
                    .onChange(of: selected) { _, i in if i < list.count { proxy.scrollTo(list[i].id) } }
                }
            }
        }
        .padding(12)
        .frame(width: 520, height: 430)
        .onyxGlass(.regular, in: .rect(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func row(_ c: ClipboardHistory.Clip, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.pinned ? "pin.fill" : "doc.on.clipboard").font(.system(size: 10)).foregroundStyle(c.pinned ? .yellow : .secondary).frame(width: 14)
            Text(c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 8)
            Text(c.app.map { "\($0) · " } ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                + Text(c.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
