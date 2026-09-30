import AppKit
import SwiftUI
import CoreServices

// MARK: - App Launcher actions: type math, "timer 10", "define word" or a question and get it right there; files too

struct LauncherAction: Identifiable {
    enum Kind { case calc, timer, define, ask, vpn }
    let kind: Kind
    let title: String
    let detail: String
    let run: @MainActor () -> Void
    var id: String { "\(kind)" }
    var icon: String {
        switch kind {
        case .calc: "equal.circle.fill"
        case .timer: "timer"
        case .define: "character.book.closed.fill"
        case .ask: "sparkles"
        case .vpn: "lock.shield.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .calc: .orange
        case .timer: .orange
        case .define: .brown
        case .ask: .purple
        case .vpn: .green
        }
    }
}

enum LauncherActions {
    /// What the query can do besides opening an app, most specific first.
    @MainActor static func parse(_ raw: String, close: @escaping @MainActor () -> Void) -> [LauncherAction] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        var out: [LauncherAction] = []

        if let m = timerMinutes(lower) {
            let label = m < 1 ? "\(Int(m * 60))-second" : m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))-minute" : "\(m)-minute"
            out.append(LauncherAction(kind: .timer, title: "Start a \(label) timer", detail: "Counts down in the notch") {
                FocusTimer.shared.begin(minutes: m); close()
            })
        }
        if let answer = Assistant.quickMath(q) {
            let result = answer.components(separatedBy: " = ").last ?? answer
            out.append(LauncherAction(kind: .calc, title: result, detail: "\(answer) · ↩ copies it") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
                NotchModel.shared.flash(.message(icon: "doc.on.doc", text: "Copied \(result)", tint: .orange), for: 1.8)
                close()
            })
        }
        // "vpn", "vpn on", "proton off", "connect vpn"…
        if ["vpn", "proton"].contains(where: { lower.split(separator: " ").contains(Substring($0)) }), ProtonVPN.shared.usable {
            let vpn = ProtonVPN.shared, off = lower.contains("off") || lower.contains("disconnect") || (!lower.contains("on") && !lower.contains("connect") && vpn.on)
            out.append(LauncherAction(kind: .vpn, title: off ? "Disconnect Proton VPN" : "Connect Proton VPN",
                                      detail: vpn.on ? "Connected\(vpn.place.map { " · \($0)" } ?? "")" : "Not connected") {
                off ? vpn.disconnect() : vpn.connect(); close()
            })
        }
        if let word = defineWord(lower), let def = definition(word) {
            out.append(LauncherAction(kind: .define, title: word, detail: def) {
                if let u = URL(string: "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)") { NSWorkspace.shared.open(u) }
                close()
            })
        }
        if let question = question(q) {
            out.append(LauncherAction(kind: .ask, title: "Ask Onyx AI", detail: question) {
                close()
                NotchController.current?.expand(tab: .ai, focus: true)
                Assistant.shared.send(question)
            })
        }
        return out
    }

    /// "timer 10", "10 min timer", "timer 90s", "set a timer for 1.5 hours" → minutes.
    static func timerMinutes(_ s: String) -> Double? {
        let patterns = [#"^(?:set (?:a )?)?timer(?: for)? (\d+(?:\.\d+)?) ?(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?)?$"#,
                        #"^(\d+(?:\.\d+)?) ?(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?)? timer$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let nr = Range(m.range(at: 1), in: s), let n = Double(s[nr]), n > 0 else { continue }
            let unit = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? "m"
            return unit.hasPrefix("s") ? n / 60 : unit.hasPrefix("h") ? n * 60 : n
        }
        return nil
    }

    static func defineWord(_ s: String) -> String? {
        for lead in ["define ", "definition of ", "meaning of ", "what does ", "def "] where s.hasPrefix(lead) {
            var w = String(s.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            if lead == "what does ", w.hasSuffix(" mean") { w = String(w.dropLast(5)) }
            return w.isEmpty || w.split(separator: " ").count > 3 ? nil : w
        }
        return nil
    }

    /// The first sense from the Mac's own dictionary.
    static func definition(_ word: String) -> String? {
        guard let d = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: (word as NSString).length))?.takeRetainedValue() as String? else { return nil }
        var flat = d.replacingOccurrences(of: "\n", with: " ")
        if flat.lowercased().hasPrefix(word.lowercased()) { flat = String(flat.dropFirst(word.count)).trimmingCharacters(in: .whitespaces) }   // it starts with the word itself
        return flat.count > 180 ? String(flat.prefix(180)) + "…" : flat
    }

    /// "ask …", "? …", or anything that reads like a question.
    static func question(_ q: String) -> String? {
        let lower = q.lowercased()
        for lead in ["ask ", "ai ", "? "] where lower.hasPrefix(lead) {
            let rest = String(q.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        let starts = ["what ", "how ", "why ", "who ", "when ", "where ", "which ", "can ", "should ", "is ", "are ", "do ", "does ", "explain ", "write "]
        return q.split(separator: " ").count >= 3 && (q.hasSuffix("?") || starts.contains(where: lower.hasPrefix)) ? q : nil
    }

    /// Files in your home folder whose names match, most recently used first (Spotlight's index).
    static func files(_ q: String) async -> [URL] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, !q.contains("'") else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemDisplayName == '*\(q)*'cd && kMDItemContentTypeTree != 'com.apple.application-bundle' && kMDItemContentType != 'public.folder'"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.contains("/Library/") && !$0.contains("/.") }
            let urls = paths.prefix(200).map { URL(fileURLWithPath: $0) }
            func used(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast }
            return Array(urls.sorted { used($0) > used($1) }.prefix(6))
        }.value
    }
}

/// An action row in the launcher's results.
struct LauncherActionRow: View {
    let action: LauncherAction
    var highlighted = false
    var body: some View {
        Button { action.run() } label: {
            HStack(spacing: 12) {
                Image(systemName: action.icon).font(.system(size: 20)).foregroundStyle(action.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: action.kind == .calc ? 20 : 14, weight: .semibold)).lineLimit(1)
                    Text(action.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
                Spacer(minLength: 0)
                if highlighted { Text("↩").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(width: 560)
            .background(highlighted ? Color.white.opacity(0.18) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
