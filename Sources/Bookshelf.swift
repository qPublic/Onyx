import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Shelf as a wooden bookshelf (Settings › Widgets & Tabs › File Shelf)

/// Each shelved file is a book; empty slots are faint outlines that fill in as files arrive.
struct BookshelfView: View {
    @ObservedObject var shelf = ShelfStore.shared
    var rowHeight: CGFloat = 70

    private static let gap: CGFloat = 2
    private static let ghostWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let inner = max(geo.size.width - 20, 40)
            let rows = Self.rows(for: shelf.items, width: inner)
            let fitRows = max(Int(geo.size.height / (rowHeight + 8)), 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(0..<max(fitRows, rows.count), id: \.self) { r in
                        shelfRow(r < rows.count ? rows[r] : [], width: inner)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .overlay {
                if shelf.items.isEmpty {
                    Text("Drop files onto the notch to fill the shelf")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.26, green: 0.16, blue: 0.1), Color(red: 0.17, green: 0.1, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.4, green: 0.26, blue: 0.15), lineWidth: 3))
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: shelf.items)
    }

    private func shelfRow(_ books: [URL], width: CGFloat) -> some View {
        let used = books.reduce(0) { $0 + Self.bookWidth($1) + Self.gap }
        let ghosts = max(0, Int((width - used) / (Self.ghostWidth + Self.gap)))
        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(books, id: \.self) { u in
                    BookView(url: u, width: Self.bookWidth(u), height: rowHeight * Self.heightFactor(u))
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                ForEach(0..<ghosts, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: Self.ghostWidth, height: rowHeight * (0.7 + 0.15 * Double((i * 7) % 3) / 2))
                }
                Spacer(minLength: 0)
            }
            .frame(height: rowHeight, alignment: .bottom)
            // The plank.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.2), Color(red: 0.36, green: 0.22, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 7)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
        }
    }

    // Stable per-file look (Swift's hashValue changes every launch, so hash the name ourselves).
    static func hash(_ u: URL) -> UInt64 {
        u.lastPathComponent.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) }
    }
    static func bookWidth(_ u: URL) -> CGFloat { 18 + CGFloat(hash(u) % 10) }
    static func heightFactor(_ u: URL) -> Double { 0.74 + Double((hash(u) / 10) % 20) / 100 }

    static func rows(for items: [URL], width: CGFloat) -> [[URL]] {
        var rows: [[URL]] = [[]], x: CGFloat = 0
        for u in items {
            let w = bookWidth(u) + gap
            if x + w > width, !(rows.last?.isEmpty ?? true) { rows.append([]); x = 0 }
            rows[rows.count - 1].append(u); x += w
        }
        return rows.last?.isEmpty == true && rows.count > 1 ? Array(rows.dropLast()) : rows
    }
}

struct BookView: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    @State private var hover = false

    private var color: Color {
        let t = UTType(filenameExtension: url.pathExtension.lowercased())
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let base: Color
        if isDir { base = Color(red: 0.45, green: 0.28, blue: 0.16) }
        else if let t {
            if t.conforms(to: .pdf) { base = Color(red: 0.7, green: 0.16, blue: 0.14) }
            else if t.conforms(to: .image) { base = Color(red: 0.1, green: 0.5, blue: 0.52) }
            else if t.conforms(to: .movie) { base = Color(red: 0.82, green: 0.45, blue: 0.1) }
            else if t.conforms(to: .audio) { base = Color(red: 0.45, green: 0.22, blue: 0.62) }
            else if t.conforms(to: .spreadsheet) { base = Color(red: 0.15, green: 0.5, blue: 0.25) }
            else if t.conforms(to: .presentation) { base = Color(red: 0.8, green: 0.55, blue: 0.1) }
            else if t.conforms(to: .sourceCode) { base = Color(red: 0.2, green: 0.3, blue: 0.36) }
            else if t.conforms(to: .archive) { base = Color(red: 0.4, green: 0.38, blue: 0.34) }
            else if t.conforms(to: .text) || t.conforms(to: .compositeContent) { base = Color(red: 0.13, green: 0.28, blue: 0.55) }
            else { base = Self.palette[Int(BookshelfView.hash(url) % UInt64(Self.palette.count))] }
        } else { base = Self.palette[Int(BookshelfView.hash(url) % UInt64(Self.palette.count))] }
        return base
    }
    private static let palette: [Color] = [
        Color(red: 0.55, green: 0.12, blue: 0.2), Color(red: 0.12, green: 0.35, blue: 0.3), Color(red: 0.3, green: 0.2, blue: 0.5),
        Color(red: 0.6, green: 0.4, blue: 0.12), Color(red: 0.2, green: 0.25, blue: 0.45),
    ]

    var body: some View {
        let title = url.deletingPathExtension().lastPathComponent
        let shade = 0.85 + Double(BookshelfView.hash(url) % 30) / 100
        // The spine sets the size; bands and the rotated title are overlays so they can't widen the book.
        RoundedRectangle(cornerRadius: 2.5)
            .fill(LinearGradient(colors: [color.opacity(1), color.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
            .brightness(shade - 1)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.18)).frame(width: 2) }   // rounded-spine highlight
            .overlay {
                VStack {
                    Rectangle().fill(Color(red: 0.85, green: 0.7, blue: 0.35).opacity(0.85)).frame(height: 1.5).padding(.top, 5)
                    Spacer()
                    Rectangle().fill(Color(red: 0.85, green: 0.7, blue: 0.35).opacity(0.85)).frame(height: 1.5).padding(.bottom, 5)
                }
                .padding(.horizontal, 2)
            }
            .overlay {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(width: max(height - 18, 10))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
            }
        .shadow(color: .black.opacity(0.35), radius: 1, x: 1)
        .offset(y: hover ? -6 : 0)                         // pulled halfway off the shelf on hover
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .help(url.lastPathComponent)
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { withAnimation { ShelfStore.shared.remove(url) } }   // removes from the shelf only; the file stays on disk
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { ShelfStore.airDrop([url]) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
            Divider()
            Button("Remove from Shelf") { ShelfStore.shared.remove(url) }
        }
    }
}
