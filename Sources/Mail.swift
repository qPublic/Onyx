import AppKit
import Network

// MARK: - Email accounts Onyx reads to find events. Read-only: nothing is marked read, moved or changed.
// Passwords (app passwords) stay in the macOS Keychain.

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var address: String
    var host = ""
    var port = 993
    var username = ""
    var read = true                 // off: Onyx never opens this account
    var uidValidity: UInt32 = 0
    var lastUID: UInt32 = 0
    var lastChecked: Date?
    var lastError: String?
    var login: String { username.isEmpty ? address : username }
}

final class MailAccounts: ObservableObject {
    static let shared = MailAccounts()
    @Published private(set) var accounts: [MailAccount] = []
    private var file: URL { Prefs.supportDir.appendingPathComponent("mail-accounts.json") }

    init() { if let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([MailAccount].self, from: d) { accounts = a } }
    private func save() { if let d = try? JSONEncoder().encode(accounts) { try? d.write(to: file, options: .atomic) } }

    func add(_ a: MailAccount, password: String) {
        Keychain.set(password, account: "mail.pw." + a.id.uuidString)
        accounts.removeAll { $0.address.lowercased() == a.address.lowercased() }
        accounts.append(a); save()
    }
    func update(_ a: MailAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i] = a; save()
    }
    func remove(_ a: MailAccount) {
        Keychain.delete("mail.pw." + a.id.uuidString)
        accounts.removeAll { $0.id == a.id }; save()
    }
    static func password(_ a: MailAccount) -> String? {
        ProcessInfo.processInfo.environment["ONYX_MAIL_TEST_PASSWORD"] ?? Keychain.get("mail.pw." + a.id.uuidString)
    }

    /// Where a provider's mail lives. Unknown domains try imap.<domain>, then Google (schools and companies often use Gmail
    /// with their own domain), then Microsoft.
    static func servers(for address: String) -> [String] {
        let d = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch d {
        case "gmail.com", "googlemail.com": return ["imap.gmail.com"]
        case "icloud.com", "me.com", "mac.com": return ["imap.mail.me.com"]
        case "yahoo.com", "ymail.com", "rocketmail.com": return ["imap.mail.yahoo.com"]
        case "aol.com": return ["imap.aol.com"]
        case "outlook.com", "hotmail.com", "live.com", "msn.com": return ["outlook.office365.com"]
        case "fastmail.com", "fastmail.fm": return ["imap.fastmail.com"]
        case "zoho.com": return ["imap.zoho.com"]
        case "gmx.com", "gmx.net": return ["imap.gmx.com"]
        default: return ["imap." + d, "mail." + d, "imap.gmail.com", "outlook.office365.com"]
        }
    }

    /// Where to make an app password for this address (the normal password doesn't work for mail apps with 2-step sign-in).
    static func passwordHelp(for address: String) -> (label: String, url: URL)? {
        let d = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch d {
        case "icloud.com", "me.com", "mac.com": return ("Make an app-specific password", URL(string: "https://account.apple.com/account/manage")!)
        case "yahoo.com", "ymail.com", "rocketmail.com": return ("Make a Yahoo app password", URL(string: "https://login.yahoo.com/account/security")!)
        case "aol.com": return ("Make an AOL app password", URL(string: "https://login.aol.com/account/security")!)
        case "outlook.com", "hotmail.com", "live.com", "msn.com": return nil
        default: return ("Make a Google app password", URL(string: "https://myaccount.google.com/apppasswords")!)
        }
    }
    static func isMicrosoft(_ address: String) -> Bool {
        ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(address.split(separator: "@").last.map { $0.lowercased() } ?? "")
    }

    /// Signs in once to check the password (and find the server if none was given).
    static func signIn(address: String, password: String, host: String? = nil, port: Int = 993, username: String? = nil) async -> Result<MailAccount, Error> {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard a.contains("@") else { return .failure(IMAPClient.Failure(message: "Enter your whole email address.")) }
        let h = host?.trimmingCharacters(in: .whitespaces) ?? "", user = username?.trimmingCharacters(in: .whitespaces) ?? ""
        let hosts = h.isEmpty ? servers(for: a) : [h]
        var authError: Error?, lastError: Error?
        for h in hosts {
            let c = IMAPClient(host: h, port: port)
            do {
                try await c.open()
                do { try await c.login(user.isEmpty ? a : user, password) } catch { authError = authError ?? error; await c.logout(); continue }
                _ = try await c.examineInbox()
                await c.logout()
                return .success(MailAccount(address: a, host: h, port: port, username: user))
            } catch { lastError = error; c.cancel() }
        }
        if let authError { return .failure(IMAPClient.Failure(message: "The email or app password wasn't accepted (\(authError.localizedDescription)).")) }
        return .failure(lastError ?? IMAPClient.Failure(message: "Couldn't reach the mail server."))
    }

    /// New inbox messages since the last check (the last 3 days the first time), newest `limit` at most.
    static func fetchNew(_ a: inout MailAccount, password: String, limit: Int = 40) async throws -> [MailMessage] {
        let c = IMAPClient(host: a.host, port: a.port)
        do {
            try await c.open()
            try await c.login(a.login, password)
            let box = try await c.examineInbox()
            let fresh = box.validity != a.uidValidity || a.lastUID == 0
            var uids = try await c.search(fresh ? "SINCE " + IMAPClient.day(Date().addingTimeInterval(-3 * 86400)) : "UID \(a.lastUID + 1):*")
            if !fresh { uids = uids.filter { $0 > a.lastUID } }
            uids = Array(uids.sorted().suffix(limit))
            let raws = try await c.fetch(uids)
            await c.logout()
            a.uidValidity = box.validity
            a.lastUID = max(fresh ? 0 : a.lastUID, uids.max() ?? 0, box.next > 0 ? box.next - 1 : 0)
            return raws.map { var m = MailMessage(raw: $0.raw); m.account = a.address; m.key = "\(a.id.uuidString)/\(box.validity)/\($0.uid)"; return m }
        } catch { c.cancel(); throw error }
    }
}

// MARK: - A small read-only IMAP client: EXAMINE (never SELECT) and BODY.PEEK, so the mailbox is never changed.

final class IMAPClient {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Response { var text = ""; var literals: [Data] = [] }

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "onyx.imap")
    private var buffer = Data()
    private var tag = 0
    private var watchdog: DispatchWorkItem?

    init(host: String, port: Int) {
        // Plain TCP only to this Mac itself (the self-test's stand-in server); real servers always use TLS.
        let local = host == "127.0.0.1" || host == "localhost"
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993, using: local ? .tcp : .tls)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy"
        return f.string(from: d)
    }

    func open(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            func finish(_ r: Result<Void, Error>) { if !done { done = true; c.resume(with: r) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e), .waiting(let e): finish(.failure(e))   // waiting: no network, or no such server
                case .cancelled: finish(.failure(Failure(message: "Cancelled.")))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [conn] in
                if !done { conn.cancel() }
                finish(.failure(Failure(message: "The mail server didn't answer.")))
            }
        }
        let greeting = try await readOne()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else { throw Failure(message: "That isn't a mail server.") }
    }

    func cancel() { conn.cancel() }

    func login(_ user: String, _ password: String) async throws {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        try await run("LOGIN \(q(user)) \(q(password))")
    }

    func examineInbox() async throws -> (validity: UInt32, next: UInt32, exists: Int) {
        var v: UInt32 = 0, next: UInt32 = 0, n = 0
        for r in try await run("EXAMINE INBOX") {
            if let m = r.text.range(of: #"UIDVALIDITY \d+"#, options: .regularExpression) { v = UInt32(r.text[m].dropFirst(12)) ?? 0 }
            if let m = r.text.range(of: #"UIDNEXT \d+"#, options: .regularExpression) { next = UInt32(r.text[m].dropFirst(8)) ?? 0 }
            if r.text.hasSuffix(" EXISTS") { n = Int(r.text.split(separator: " ")[1]) ?? 0 }
        }
        return (v, next, n)
    }

    func search(_ criteria: String) async throws -> [UInt32] {
        try await run("UID SEARCH " + criteria).filter { $0.text.hasPrefix("* SEARCH") }
            .flatMap { $0.text.split(separator: " ").dropFirst(2).compactMap { UInt32($0) } }
    }

    /// The first `limit` bytes of each message: the text and any invitation, with big attachments cut off.
    func fetch(_ uids: [UInt32], limit: Int = 200_000) async throws -> [(uid: UInt32, raw: Data)] {
        guard !uids.isEmpty else { return [] }
        return try await run("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID BODY.PEEK[]<0.\(limit)>)").compactMap { r in
            guard r.text.contains(" FETCH "), let d = r.literals.first,
                  let m = r.text.range(of: #"UID \d+"#, options: .regularExpression), let uid = UInt32(r.text[m].dropFirst(4)) else { return nil }
            return (uid, d)
        }
    }

    func logout() async {
        _ = try? await run("LOGOUT")
        conn.cancel()
    }

    /// Sends one command and collects its untagged responses; throws with the server's words if it says NO or BAD.
    @discardableResult
    func run(_ command: String) async throws -> [Response] {
        tag += 1
        let t = "A\(tag)"
        try await send(t + " " + command + "\r\n")
        var out: [Response] = []
        while true {
            let r = try await readOne()
            if r.text.hasPrefix(t + " ") {
                let status = r.text.dropFirst(t.count + 1)
                if status.hasPrefix("OK") { return out }
                throw Failure(message: status.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? String(status))
            }
            if r.text.hasPrefix("* BYE") && !command.hasPrefix("LOGOUT") { throw Failure(message: "The mail server hung up.") }
            out.append(r)
        }
    }

    private func send(_ s: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }

    /// One whole response: a line, plus the {n}-byte literals inside it.
    private func readOne() async throws -> Response {
        var r = Response()
        while true {
            let s = String(decoding: try await readLine(), as: UTF8.self)
            r.text += s
            if let m = s.range(of: #"\{\d+\+?\}$"#, options: .regularExpression), let n = Int(s[m].filter(\.isNumber)) {
                r.literals.append(try await readBytes(n))
                continue
            }
            return r
        }
    }

    private func readLine() async throws -> Data {
        while true {
            if let i = buffer.firstRange(of: Data([13, 10])) {
                let line = Data(buffer[buffer.startIndex..<i.lowerBound])
                buffer = Data(buffer[i.upperBound...])
                return line
            }
            buffer.append(try await receive())
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { buffer.append(try await receive()) }
        let d = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return d
    }

    /// Gives up (closing the connection) if the server goes quiet for 30 s.
    private func receive() async throws -> Data {
        let dog = DispatchWorkItem { [conn] in conn.cancel() }
        watchdog?.cancel(); watchdog = dog
        queue.asyncAfter(deadline: .now() + 30, execute: dog)
        defer { dog.cancel() }
        return try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if let error { c.resume(throwing: error) }
                else if complete { c.resume(throwing: Failure(message: "The mail server closed the connection.")) }
                else { c.resume(returning: Data()) }
            }
        }
    }
}

// MARK: - One email, decoded enough to read: who sent it, when, the subject, the text and any calendar invitations

struct MailMessage {
    var key = ""              // account + mailbox + UID, to remember it was read
    var messageID = ""
    var account = ""
    var from = "", fromName = ""
    var subject = ""
    var date = Date()
    var text = ""
    var invites: [String] = []
    var bulk = false          // newsletters and promotions

    init() {}

    init(raw: Data) {
        let s = String(data: raw, encoding: .isoLatin1) ?? ""
        let (head, body) = Self.split(s)
        let h = Self.headers(head)
        messageID = (h["message-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        (fromName, from) = Self.address(Self.words(h["from"] ?? ""))
        subject = Self.words(h["subject"] ?? "")
        date = Self.date(h["date"] ?? "") ?? Date()
        bulk = h["list-unsubscribe"] != nil || ["bulk", "list", "junk"].contains((h["precedence"] ?? "").lowercased())
        var plain: [String] = [], html: [String] = []
        Self.walk(h, body, plain: &plain, html: &html, invites: &invites)
        text = Self.clean(plain.first ?? html.first.map(Self.stripHTML) ?? "")
    }

    // Headers and body. Work in Latin-1 (one character per byte) so 8-bit bodies survive until their charset is known.
    static func split(_ s: String) -> (String, String) {
        if let r = s.range(of: "\r\n\r\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        if let r = s.range(of: "\n\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return (s, "")
    }

    static func headers(_ head: String) -> [String: String] {
        var out: [String: String] = [:], lastKey: String?
        for line in head.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t", let k = lastKey { out[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue }
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].lowercased().trimmingCharacters(in: .whitespaces)
            if out[k] == nil { out[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
            lastKey = k
        }
        return out
    }

    /// "=?UTF-8?B?…?=" and "=?iso-8859-1?Q?…?=" words in headers (spaces between two of them don't count).
    static func words(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let pat = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        let ns = NSMutableString(string: s)
        let matches = pat.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return latin1ToUTF8(s) }
        for m in matches.reversed() {
            let cs = ns.substring(with: m.range(at: 1)), enc = ns.substring(with: m.range(at: 2)).lowercased(), txt = ns.substring(with: m.range(at: 3))
            let data = enc == "b" ? Data(base64Encoded: pad(txt)) : qp(txt.replacingOccurrences(of: "_", with: " "))
            ns.replaceCharacters(in: m.range, with: data.map { decode($0, charset: cs) } ?? txt)
        }
        return ns as String
    }

    static func pad(_ b: String) -> String { let t = b.filter { !$0.isWhitespace }; return t + String(repeating: "=", count: (4 - t.count % 4) % 4) }

    /// Raw 8-bit header text (Latin-1 view of UTF-8 bytes) back to real characters.
    static func latin1ToUTF8(_ s: String) -> String {
        guard let d = s.data(using: .isoLatin1) else { return s }
        return String(data: d, encoding: .utf8) ?? s
    }

    static func address(_ s: String) -> (String, String) {
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            return (name, s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces).lowercased())
        }
        return ("", s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func date(_ s: String) -> Date? {
        let t = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    static func param(_ header: String, _ name: String) -> String? {
        guard let r = header.range(of: #"(?i)\b"# + name + #"\s*=\s*("[^"]*"|[^;\s]+)"#, options: .regularExpression) else { return nil }
        return header[r].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    /// Goes through the MIME parts, collecting plain text, HTML and calendar invitations.
    static func walk(_ h: [String: String], _ body: String, plain: inout [String], html: inout [String], invites: inout [String], depth: Int = 0) {
        let type = (h["content-type"] ?? "text/plain").lowercased()
        let cte = (h["content-transfer-encoding"] ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if type.hasPrefix("multipart/"), depth < 6, let b = param(h["content-type"] ?? "", "boundary") {
            let parts = body.components(separatedBy: "--" + b)
            for p in parts.dropFirst() {
                if p.hasPrefix("--") { break }   // closing boundary
                let (ph, pb) = split(p.hasPrefix("\r\n") ? String(p.dropFirst(2)) : p.hasPrefix("\n") ? String(p.dropFirst()) : p)
                walk(headers(ph), pb, plain: &plain, html: &html, invites: &invites, depth: depth + 1)
            }
            return
        }
        let bytes: Data = switch cte {
        case "base64": Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        case "quoted-printable": qp(body) ?? Data()
        default: body.data(using: .isoLatin1) ?? Data()
        }
        let text = decode(bytes, charset: param(h["content-type"] ?? "", "charset") ?? "utf-8")
        let file = (param(h["content-disposition"] ?? "", "filename") ?? param(h["content-type"] ?? "", "name") ?? "").lowercased()
        if type.hasPrefix("text/calendar") || type.hasPrefix("application/ics") || file.hasSuffix(".ics") { invites.append(text) }
        else if (h["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return }
        else if type.hasPrefix("text/plain") { plain.append(text) }
        else if type.hasPrefix("text/html") { html.append(text) }
    }

    /// Quoted-printable, byte for byte (the text is a Latin-1 view of the raw bytes).
    static func qp(_ s: String) -> Data? {
        guard let src = s.data(using: .isoLatin1) ?? s.data(using: .utf8) else { return nil }
        let b = [UInt8](src)
        var out = Data(), i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        while i < b.count {
            if b[i] == 61 {   // "="
                if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }                        // soft line break
                if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(b[i]); i += 1
        }
        return out
    }

    static func decode(_ d: Data, charset: String) -> String {
        let cs = charset.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: "*").first.map(String.init) ?? ""
        let enc: String.Encoding = switch cs {
        case "utf-8", "utf8", "us-ascii", "ascii": .utf8
        case "iso-8859-1", "latin1", "iso8859-1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        default: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(cs as CFString)))
        }
        return String(data: d, encoding: enc) ?? String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    static func stripHTML(_ h: String) -> String {
        var t = h.replacingOccurrences(of: #"(?is)<(style|script|head)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table)>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "’"), ("&ndash;", "–"), ("&mdash;", "—")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        let ent = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        var ns = t as NSString
        for m in ent.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { ns = ns.replacingCharacters(in: m.range, with: String(u)) as NSString }
        }
        return ns as String
    }

    /// Tidy text: no quoted replies (they hold old plans; forwarded messages stay), no runs of blank lines.
    static func clean(_ s: String) -> String {
        var lines: [Substring] = []
        for l in s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if t.range(of: #"^On .{6,120} wrote:$"#, options: .regularExpression) != nil || t.hasPrefix("-----Original Message-----") { break }
            lines.append(l)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Calendar invitations (text/calendar)

enum ICS {
    struct Event: Equatable {
        var uid = "", title = "", location = ""
        var start: Date?, end: Date?
        var allDay = false, cancelled = false
        // For calendars read from a link: how it repeats, skipped and moved dates, notes, and its time zone.
        var rrule = "", exdates: [Date] = [], recurrenceID: Date?, notes = "", zone: TimeZone?
    }

    static func events(_ text: String) -> [Event] {
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var out: [Event] = [], cur: Event?, nested = 0, duration: TimeInterval?, cancelAll = false
        for raw in unfolded.split(separator: "\n") {
            let line = String(raw)
            guard let (name, params, value) = parse(line) else { continue }
            switch name {
            case "METHOD": if value.uppercased() == "CANCEL" { cancelAll = true }
            case "BEGIN" where value == "VEVENT": cur = Event(); duration = nil; nested = 0
            case "BEGIN" where cur != nil: nested += 1          // an alarm inside the event
            case "END" where value == "VEVENT":
                if var e = cur {
                    if e.end == nil, let s = e.start { e.end = s.addingTimeInterval(duration ?? (e.allDay ? 86400 : 3600)) }
                    if cancelAll { e.cancelled = true }
                    if e.start != nil { out.append(e) }
                }
                cur = nil
            case "END" where cur != nil: nested -= 1
            default:
                guard cur != nil, nested == 0 else { continue }
                switch name {
                case "UID": cur!.uid = value
                case "SUMMARY": cur!.title = unescape(value)
                case "LOCATION": cur!.location = unescape(value)
                case "STATUS": if value.uppercased() == "CANCELLED" { cur!.cancelled = true }
                case "DTSTART":
                    let d = date(value, params); cur!.start = d.date; cur!.allDay = d.allDay
                    cur!.zone = value.hasSuffix("Z") ? TimeZone(identifier: "UTC") : params["TZID"].flatMap(zone) ?? .current
                case "RRULE": cur!.rrule = value
                case "EXDATE": cur!.exdates += value.split(separator: ",").compactMap { date(String($0), params).date }
                case "RECURRENCE-ID": cur!.recurrenceID = date(value, params).date
                case "DESCRIPTION": cur!.notes = unescape(value)
                case "DTEND": cur!.end = date(value, params).date
                case "DURATION": duration = Self.duration(value)
                default: break
                }
            }
        }
        return out
    }

    /// NAME;PARAM=V;PARAM="V:X":VALUE
    static func parse(_ line: String) -> (String, [String: String], String)? {
        var inQuote = false, colon: String.Index?
        for i in line.indices {
            if line[i] == "\"" { inQuote.toggle() } else if line[i] == ":" && !inQuote { colon = i; break }
        }
        guard let colon else { return nil }
        let left = line[..<colon].split(separator: ";").map(String.init)
        var params: [String: String] = [:]
        for p in left.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (left.first?.uppercased() ?? "", params, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func date(_ v: String, _ params: [String: String]) -> (date: Date?, allDay: Bool) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || (v.count == 8 && !v.contains("T")) {
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return (f.date(from: String(v.prefix(8))), true)
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if v.hasSuffix("Z") { f.timeZone = TimeZone(identifier: "UTC") }
        else { f.timeZone = params["TZID"].flatMap(zone) ?? .current }
        return (f.date(from: String(v.prefix(15))), false)
    }

    /// Olson names, plus the Windows names Outlook uses.
    static func zone(_ id: String) -> TimeZone? {
        if let z = TimeZone(identifier: id) { return z }
        let windows = ["Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
                       "US Mountain Standard Time": "America/Phoenix", "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
                       "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax", "GMT Standard Time": "Europe/London",
                       "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris", "Central Europe Standard Time": "Europe/Budapest",
                       "E. Europe Standard Time": "Europe/Bucharest", "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
                       "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul", "AUS Eastern Standard Time": "Australia/Sydney",
                       "New Zealand Standard Time": "Pacific/Auckland", "UTC": "UTC"]
        return windows[id].flatMap(TimeZone.init(identifier:)) ?? windows.first { id.contains($0.key) }.flatMap { TimeZone(identifier: $0.value) }
    }

    /// PT1H30M, P1D, PT45M
    static func duration(_ v: String) -> TimeInterval? {
        var total: TimeInterval = 0, num = "", inTime = false
        for ch in v.uppercased() {
            if ch.isNumber { num.append(ch); continue }
            let n = Double(num) ?? 0; num = ""
            switch ch {
            case "T": inTime = true
            case "W": total += n * 604800
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 2_592_000
            case "S": total += n
            default: break
            }
        }
        return total > 0 ? total : nil
    }
}

// MARK: - The accounts already in Apple Mail (read through AppleScript, only while Mail is open)

enum AppleMailReader {
    static let key = "mail.appleMail"
    static let skipKey = "mail.appleSkip"   // Apple Mail accounts not to read (names)

    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty }

    /// Inbox messages from the last `days` days. Never opens Mail; macOS asks once to let Onyx read it.
    static func recent(days: Int = 3, limit: Int = 40) async -> (messages: [MailMessage], accounts: [String], error: String?) {
        guard running else { return ([], [], nil) }
        let script = """
        tell application "Mail"
            set out to {}
            set cutoff to (current date) - (\(days) * days)
            set n to 0
            repeat with m in (messages of inbox whose date received > cutoff)
                set n to n + 1
                if n > \(limit) then exit repeat
                set c to content of m
                if length of c > 12000 then set c to text 1 thru 12000 of c
                set end of out to (message id of m) & (ASCII character 31) & (sender of m) & (ASCII character 31) & (subject of m) & (ASCII character 31) & ((date received of m) as «class isot» as string) & (ASCII character 31) & (name of account of mailbox of m) & (ASCII character 31) & c
            end repeat
            set AppleScript's text item delimiters to (ASCII character 30)
            return out as text
        end tell
        """
        let r = await Shell.read("/usr/bin/osascript", ["-e", script])
        guard r.status == 0 else { return ([], [], r.output.contains("-1743") ? "Onyx isn't allowed to read Mail. Turn it on in System Settings › Privacy & Security › Automation." : "Couldn't read Mail.") }
        return parse(r.output)
    }

    static func parse(_ out: String) -> (messages: [MailMessage], accounts: [String], error: String?) {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]; iso.timeZone = .current
        var names = Set<String>()
        let msgs: [MailMessage] = out.trimmingCharacters(in: .newlines).split(separator: "\u{1E}").compactMap { rec in
            let f = rec.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { return nil }
            var m = MailMessage()
            m.messageID = f[0]; (m.fromName, m.from) = MailMessage.address(f[1]); m.subject = f[2]
            m.date = iso.date(from: f[3]) ?? Date(); m.account = f[4]; names.insert(f[4])
            m.text = MailMessage.clean(f[5]); m.key = "applemail/" + f[0]
            return m
        }
        return (msgs, names.sorted(), nil)
    }
}
