import AppKit
import SwiftUI
import FoundationModels

// MARK: - Notes: multiple notes with folders, pinning and search (Apple Notes-style)

struct Flashcard: Codable, Hashable, Identifiable {
    var id = UUID()
    var q: String
    var a: String
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var body = ""
    var folder = "Notes"
    var pinned = false
    var created = Date()
    var updated = Date()
    var cards: [Flashcard] = []

    var title: String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "New Note"
    }
    var preview: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst().first.map { String($0.prefix(80)) } ?? "No additional text"
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published var notes: [Note] = [] { didSet { scheduleSave() } }
    private var saveWork: DispatchWorkItem?
    private var file: URL { Prefs.supportDir.appendingPathComponent("notes.json") }

    init() {
        if let d = try? Data(contentsOf: file), let n = try? JSONDecoder().decode([Note].self, from: d) {
            notes = n
        } else {
            // First run of multi-notes: bring the old single quick note over.
            let old = Prefs.string(Prefs.notes)
            notes = old.isEmpty ? [] : [Note(body: old)]
        }
    }

    var folders: [String] { Array(Set(notes.map(\.folder) + ["Notes"])).sorted() }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let d = try? JSONEncoder().encode(self.notes) else { return }
            try? d.write(to: self.file, options: .atomic)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    @discardableResult
    func add(in folder: String) -> Note {
        let n = Note(folder: folder == "All" ? "Notes" : folder)
        notes.insert(n, at: 0)
        return n
    }
    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
    }
    func delete(_ id: UUID) { notes.removeAll { $0.id == id } }

    /// Pinned first, then most recently edited; filtered by folder and search text.
    func list(folder: String, search: String) -> [Note] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return notes
            .filter { folder == "All" || $0.folder == folder }
            .filter { q.isEmpty || $0.body.lowercased().contains(q) || $0.folder.lowercased().contains(q) }
            .sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }
}

struct NotesView: View {
    @ObservedObject var store = NotesStore.shared
    @AppStorage("notes.selected") private var selectedRaw = ""
    @AppStorage("notes.folder") private var folder = "All"
    @State private var search = ""
    @State private var studying = false
    @State private var newFolder = ""
    @State private var askFolder = false

    private var selected: UUID? { UUID(uuidString: selectedRaw) }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 440
            HStack(spacing: 8) {
                if !narrow || selected == nil { sidebar.frame(width: narrow ? geo.size.width : 168) }
                if !narrow || selected != nil { detail(narrow: narrow) }
            }
        }
        .onAppear { NotchController.current?.panel.makeKey() }
        .alert("New Folder", isPresented: $askFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") {
                let f = newFolder.trimmingCharacters(in: .whitespaces)
                if !f.isEmpty { folder = f; let n = store.add(in: f); selectedRaw = n.id.uuidString }
                newFolder = ""
            }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                Button { let n = store.add(in: folder); selectedRaw = n.id.uuidString; search = "" } label: {
                    Image(systemName: "square.and.pencil")
                }.buttonStyle(.plain).help("New note")
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            Menu {
                Button { folder = "All" } label: { Label("All Notes", systemImage: folder == "All" ? "checkmark" : "tray.full") }
                ForEach(store.folders, id: \.self) { f in
                    Button { folder = f } label: { Label(f, systemImage: folder == f ? "checkmark" : "folder") }
                }
                Divider()
                Button("New Folder…") { askFolder = true }
            } label: {
                Label(folder == "All" ? "All Notes" : folder, systemImage: "folder").font(.system(size: 10.5, weight: .semibold))
            }
            .menuStyle(.borderlessButton).fixedSize().frame(maxWidth: .infinity, alignment: .leading)

            let items = store.list(folder: folder, search: search)
            if items.isEmpty {
                Text(search.isEmpty ? "No notes yet" : "No matches").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { n in row(n) }
                    }
                }
            }
        }
    }

    private func row(_ n: Note) -> some View {
        let sel = n.id == selected
        return Button { selectedRaw = n.id.uuidString; studying = false } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if n.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                    Text(n.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if !n.cards.isEmpty { Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 8)).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    Text(n.updated, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    Text(n.preview).lineLimit(1)
                }
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(sel ? AP.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(n.pinned ? "Unpin" : "Pin") { store.update(n.id) { $0.pinned.toggle() } }
            Menu("Move to") {
                ForEach(store.folders, id: \.self) { f in Button(f) { store.update(n.id) { $0.folder = f } } }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(n.id); if sel { selectedRaw = "" } }
        }
    }

    // MARK: Detail (editor / flashcards)

    @ViewBuilder private func detail(narrow: Bool) -> some View {
        if let id = selected, let note = store.notes.first(where: { $0.id == id }) {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    if narrow {
                        Button { selectedRaw = ""; studying = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    }
                    Label(note.folder, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.update(id) { $0.pinned.toggle() } } label: {
                        Image(systemName: note.pinned ? "pin.fill" : "pin").foregroundStyle(note.pinned ? .orange : .secondary)
                    }.buttonStyle(.plain).help(note.pinned ? "Unpin" : "Pin")
                    FlashcardButton(note: note, studying: $studying)
                    Button { store.delete(id); selectedRaw = "" } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete note")
                }
                .font(.system(size: 11))
                if studying && !note.cards.isEmpty {
                    FlashcardStudyView(cards: note.cards) { studying = false }
                } else {
                    TextEditor(text: Binding(
                        get: { store.notes.first(where: { $0.id == id })?.body ?? "" },
                        set: { v in store.update(id) { $0.body = v; $0.updated = Date() } }))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if note.body.isEmpty {
                                Text("Start typing — the first line is the title").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Select a note or make a new one").font(.caption).foregroundStyle(.secondary)
                Button("New Note") { let n = store.add(in: folder); selectedRaw = n.id.uuidString }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Flashcards

/// "Convert to flashcards" / "Study" for a note.
struct FlashcardButton: View {
    let note: Note
    @Binding var studying: Bool
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
                Text("Making cards…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if note.cards.isEmpty {
                Button { generate() } label: { Label("Flashcards", systemImage: "sparkles.rectangle.stack") }
                    .buttonStyle(.plain).help("Convert this note to flashcards")
                    .disabled(note.body.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
            } else {
                Button { studying.toggle() } label: {
                    Label(studying ? "Edit" : "Study (\(note.cards.count))", systemImage: studying ? "pencil" : "rectangle.on.rectangle.angled")
                }.buttonStyle(.plain)
                Button { generate() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Make new cards from the note")
            }
        }
        .foregroundStyle(AP.accentColor)
        .popover(isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Text(error ?? "").font(.caption).padding(10).frame(width: 240)
        }
    }

    private func generate() {
        busy = true
        let text = note.body, id = note.id
        Task { @MainActor in
            defer { busy = false }
            do {
                let cards = try await FlashcardMaker.make(from: text)
                if cards.isEmpty { error = "Couldn't find anything to turn into cards. Try adding more detail."; return }
                NotesStore.shared.update(id) { $0.cards = cards }
                studying = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum FlashcardMaker {
    static var lastRaw = ""   // last model reply (for debugging)
    /// On-device Apple Intelligence when available; otherwise a simple "term: definition" parser.
    static func make(from text: String) async throws -> [Flashcard] {
        if Assistant.shared.unavailableReason == nil {
            let s = LanguageModelSession(instructions: """
                You turn study notes into flashcards. Write 6 to 12 cards covering the most important facts. \
                Output ONLY lines in exactly this format, one card per line, nothing else:
                Q: <short question> || A: <short answer>
                """)
            let r = try await s.respond(to: "Notes:\n\"\"\"\n\(text.prefix(3500))\n\"\"\"")
            lastRaw = r.content
            let cards = parse(r.content)
            if !cards.isEmpty { return cards }
        }
        return heuristic(text)
    }

    static func parse(_ out: String) -> [Flashcard] {
        var cards: [Flashcard] = []
        var pendingQ: String?
        func strip(_ s: Substring, _ prefixes: [String]) -> String? {
            var t = s.trimmingCharacters(in: .whitespaces)
            while let f = t.first, "0123456789.)-*• ".contains(f) { t.removeFirst() }   // "1. Q:" / "- Q:"
            for p in prefixes where t.lowercased().hasPrefix(p) { return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
            return nil
        }
        for line in out.split(separator: "\n") where !line.contains("||") {
            if let q = strip(line, ["q:", "question:"]) { pendingQ = q }
            else if let a = strip(line, ["a:", "answer:"]), let q = pendingQ, !q.isEmpty, !a.isEmpty {
                cards.append(Flashcard(q: q, a: a)); pendingQ = nil
            }
        }
        return cards + out.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let sep = l.range(of: "||") else { return nil }
            var q = String(l[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            var a = String(l[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            for p in ["Q:", "q:", "- Q:", "* Q:"] where q.hasPrefix(p) { q = String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
            for p in ["A:", "a:"] where a.hasPrefix(p) { a = String(a.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
            return q.isEmpty || a.isEmpty ? nil : Flashcard(q: q, a: a)
        }
    }

    /// Offline fallback: "Term: definition" / "Term - definition" lines become cards.
    static func heuristic(_ text: String) -> [Flashcard] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t"))
            for sep in [": ", " - ", " – ", " — ", " = "] {
                if let r = l.range(of: sep) {
                    let t = String(l[..<r.lowerBound]), d = String(l[r.upperBound...])
                    if t.count >= 2, t.count <= 60, d.count >= 2 { return Flashcard(q: "What is \(t)?", a: d) }
                }
            }
            return nil
        }
    }
}

struct FlashcardStudyView: View {
    let cards: [Flashcard]
    var done: () -> Void
    @State private var order: [Int] = []
    @State private var i = 0
    @State private var flipped = false

    var body: some View {
        let deck = order.isEmpty ? Array(cards.indices) : order
        let card = cards[deck[min(i, deck.count - 1)]]
        VStack(spacing: 6) {
            ZStack {
                face(card.q, label: "QUESTION", tint: AP.accentColor).opacity(flipped ? 0 : 1)
                face(card.a, label: "ANSWER", tint: .green).opacity(flipped ? 1 : 0)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: flipped)
            .onTapGesture { flipped.toggle() }
            HStack(spacing: 14) {
                Button { step(-1, deck.count) } label: { Image(systemName: "chevron.left") }.disabled(i == 0)
                Text("\(i + 1) / \(deck.count)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                Button { step(1, deck.count) } label: { Image(systemName: "chevron.right") }.disabled(i >= deck.count - 1)
                Button { order = Array(cards.indices).shuffled(); i = 0; flipped = false } label: { Image(systemName: "shuffle") }.help("Shuffle")
                Button("Done", action: done).font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
        }
    }

    private func step(_ d: Int, _ n: Int) {
        flipped = false
        i = max(0, min(n - 1, i + d))
    }

    private func face(_ text: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.4), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            Text("tap to flip").font(.system(size: 8)).foregroundStyle(.secondary).padding(6)
        }
    }
}
