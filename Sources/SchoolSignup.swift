import AppKit
import SwiftUI
import WebKit

// MARK: - Academy sign-up (TeachMore): watches your school's offerings list and signs you up the moment the one you want is posted.
// Everything happens inside your own signed-in browser tab, with the same requests TeachMore's page makes,
// so Onyx never sees or stores your password.

/// One offering, read from TeachMore's `offerings/search` list with the same rules its page uses.
struct SchoolOffering: Equatable {
    var id = "", title = "", teacherID = "", teacherLast = "", teacherFirst = "", date = "", event = "1"
    var enrolled = false, unavailable = false, full = false
    var hasAppt = false, apptType = 0, existingTeacher = "", sameDayLocked = false
    var teacher: String { [teacherFirst, teacherLast].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ") }
    var day: String { SchoolSignup.dayText(date) }

    init() {}
    init?(_ o: [String: Any]) {
        func s(_ k: String) -> String {
            switch o[k] { case let v as String: v; case let v as NSNumber: v.stringValue; default: "" }
        }
        func b(_ k: String) -> Bool {
            switch o[k] {
            case let v as NSNumber: v.boolValue
            case let v as String: ["1", "true", "yes"].contains(v.lowercased())
            default: false
            }
        }
        id = s("uniqueID"); date = s("offeringDate")
        guard !id.isEmpty, !date.isEmpty else { return nil }
        title = SchoolSignup.plain(s("offering")); teacherID = s("teacherID")
        teacherLast = SchoolSignup.plain(s("teacherLast")); teacherFirst = SchoolSignup.plain(s("teacherFirst"))
        event = s("offeringEvent").isEmpty ? "1" : s("offeringEvent")
        enrolled = b("isEnrolled")
        let cap = s("offeringCap"), capZero = cap == "0"
        unavailable = capZero || b("isRestricted")
        full = b("isFull") || capZero || (cap != "N/A" && Int(s("numberLeft")).map { $0 <= 0 } == true)
        hasAppt = b("hasAppt"); apptType = Int(s("existingApptType")) ?? 0
        existingTeacher = SchoolSignup.plain(s("existingTeacher"))
        sameDayLocked = s("existingDayOfEdits").lowercased().trimmingCharacters(in: .whitespaces) == "no"
    }
}

/// What to sign up for.
struct SchoolRule: Equatable {
    var teacherID = "", teacherName = "", words = "", date = ""   // date: "yyyy-MM-dd", or "" for the first day it's offered
    var keepWatching = false, replace = true
    var offeringID = ""   // one academy you picked from the list
    var isSet: Bool { !offeringID.isEmpty || !teacherID.isEmpty || !wordList.isEmpty }
    var wordList: [String] { words.split(whereSeparator: { $0 == " " || $0 == "," }).map { SchoolSignup.fold(String($0)) } }
    var label: String {
        let w = words.trimmingCharacters(in: .whitespaces)
        let l = [teacherName.isEmpty ? nil : teacherName, w.isEmpty ? nil : "“\(w)”"].compactMap { $0 }.joined(separator: " · ")
        return l.isEmpty ? "your academy" : l
    }
    func matches(_ o: SchoolOffering) -> Bool {
        guard isSet else { return false }
        if !offeringID.isEmpty { return o.id == offeringID }
        if !teacherID.isEmpty, o.teacherID != teacherID { return false }
        if !date.isEmpty, o.date != date { return false }
        let t = SchoolSignup.fold(o.title)
        return wordList.allSatisfy { t.contains($0) }
    }
}

/// A day you planned in the calendar: one academy from the list, or a teacher's (or words in the title) whenever it's posted for that day.
struct SchoolPlan: Codable, Identifiable, Equatable {
    var date: String, teacherID = "", teacherName = "", words = "", offeringID = "", title = "", done = false
    var id: String { date }
    var label: String {
        offeringID.isEmpty ? rule(replace: true).label : "“\(title)”" + (teacherName.isEmpty ? "" : " with \(teacherName)")
    }
    func rule(replace: Bool) -> SchoolRule {
        SchoolRule(teacherID: teacherID, teacherName: teacherName, words: words, date: date, replace: replace, offeringID: offeringID)
    }
}

struct SchoolChoice { var pick: SchoolOffering?; var note: String; var satisfied = false }

struct SchoolTeacher: Codable, Identifiable, Hashable { var id: String; var name: String; var mine: Bool }

struct SchoolSignupRecord: Codable, Identifiable, Equatable {
    var id: String, title: String, teacher: String, date: String, at: Date, confirmed: Bool
}

enum SchoolBrowser: String, CaseIterable, Identifiable {
    case onyx = "onyx", chrome = "com.google.Chrome", brave = "com.brave.Browser", edge = "com.microsoft.edgemac", safari = "com.apple.Safari"
    var id: String { rawValue }
    var name: String {
        switch self { case .onyx: "Onyx's own browser"; case .chrome: "Google Chrome"; case .brave: "Brave"; case .edge: "Microsoft Edge"; case .safari: "Safari" }
    }
    var installed: Bool { self == .onyx || NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
    var running: Bool { self == .onyx || !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    /// Where the one setting Onyx needs lives.
    var javaScriptSetting: String {
        self == .safari ? "Safari's Develop › Developer Settings › Allow JavaScript from Apple Events (show the Develop menu in Settings › Advanced first)"
                        : "\(name)'s View › Developer › Allow JavaScript from Apple Events"
    }
}

struct SchoolSettings {
    var on = false, link = "", browser = SchoolBrowser.chrome, rule = SchoolRule(), google = ""
    var password: String?   // the self-test's; otherwise it's read from your Keychain only when Onyx's browser signs in
    static func load() -> SchoolSettings {
        SchoolSettings(on: Prefs.bool(SchoolSignup.onKey), link: Prefs.string(SchoolSignup.linkKey),
                       browser: SchoolBrowser(rawValue: Prefs.string(SchoolSignup.browserKey)) ?? .chrome,
                       rule: SchoolRule(teacherID: Prefs.string(SchoolSignup.teacherKey), teacherName: Prefs.string(SchoolSignup.teacherNameKey),
                                        words: Prefs.string(SchoolSignup.wordsKey), date: Prefs.string(SchoolSignup.dateKey),
                                        keepWatching: Prefs.bool(SchoolSignup.repeatKey), replace: Prefs.bool(SchoolSignup.replaceKey)),
                       google: Prefs.string(SchoolSignup.googleKey))
    }
}

// MARK: Where the page's JavaScript runs: your browser tab, or (for the self-test) a web view

enum SchoolPageResult: Equatable { case value(String), noTab, opened, reloaded, jsOff, notAllowed, notRunning, failed(String) }

@MainActor protocol SchoolPage {
    /// Runs `start` in the TeachMore page, then `poll` until it returns something (about 20 seconds at most).
    /// `openURL` (if not empty) is opened in a background tab when no TeachMore tab is open.
    func run(_ start: String, poll: String, openURL: String) async -> SchoolPageResult
    /// Sends the TeachMore tab to `url` (to sign in again with Google).
    func navigate(_ url: String) async -> SchoolPageResult
    /// Where the sign-in has got to. On Google's "Choose an account" (for TeachMore) it clicks `email`, or the only
    /// account there; it never types anything.
    func signInStep(_ email: String) async -> SignInStep
}

enum SignInStep: Equatable { case google(String), teachmore(url: String, loading: Bool), gone, trouble(SchoolPageResult) }

/// Your signed-in tab in Chrome, Brave, Edge or Safari, through AppleScript. Never launches or brings the browser forward.
struct BrowserTab: SchoolPage {
    let browser: SchoolBrowser, key: String   // key: "teachmore.org/": any TeachMore tab, even its 404 page when you're signed out

    /// Runs the script; if the browser jumped in front of what you were using, puts that back in front.
    private func osa(_ args: [String]) async -> (status: Int32, output: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let r = await Shell.read("/usr/bin/osascript", args)
        if let front, front.bundleIdentifier != browser.rawValue, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.rawValue {
            if front == NSRunningApplication.current { NSApp.activate() } else { front.activate(options: []) }
        }
        return r
    }

    func run(_ start: String, poll: String, openURL: String) async -> SchoolPageResult {
        guard browser.running else { return .notRunning }
        let chromium = browser != .safari
        func js(_ v: String) -> String { chromium ? "execute t javascript \(v)" : "do JavaScript \(v) in t" }
        // A new tab opens behind the one you're looking at.
        let open = chromium ? "set w to window 1\nset prev to active tab index of w\nmake new tab at end of tabs of w with properties {URL:openURL}\nset active tab index of w to prev"
                            : "make new tab at end of tabs of window 1 with properties {URL:openURL}"
        let reload = chromium ? "tell t to reload" : "set URL of t to u"   // a tab the browser put to sleep
        let script = """
        on run argv
            set tabKey to item 1 of argv
            set startJS to item 2 of argv
            set pollJS to item 3 of argv
            set openURL to item 4 of argv
            with timeout of 40 seconds
                tell application id "\(browser.rawValue)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to ""
                            try
                                set u to (URL of t) as text
                            end try
                            if u contains ("//" & tabKey) or u contains ("." & tabKey) then
                                set s to \(js("startJS"))
                                if s is missing value then
                                    \(reload)
                                    return "ONYX_RELOADED"
                                end if
                                repeat 80 times
                                    set r to \(js("pollJS"))
                                    if r is not missing value and r is not "" then return r
                                    delay 0.25
                                end repeat
                                return "ONYX_TIMEOUT"
                            end if
                        end repeat
                    end repeat
                    if openURL is not "" and (count of windows) > 0 then
                        \(open)
                        return "ONYX_OPENED"
                    end if
                end tell
            end timeout
            return "ONYX_NO_TAB"
        end run
        """
        return Self.result(await osa(["-e", script, key, start, poll, openURL]))
    }

    func navigate(_ url: String) async -> SchoolPageResult {
        guard browser.running else { return .notRunning }
        let script = """
        on run argv
            set tabKey to item 1 of argv
            set newURL to item 2 of argv
            with timeout of 20 seconds
                tell application id "\(browser.rawValue)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to ""
                            try
                                set u to (URL of t) as text
                            end try
                            if u contains ("//" & tabKey) or u contains ("." & tabKey) then
                                set URL of t to newURL
                                return "ONYX_DONE"
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return "ONYX_NO_TAB"
        end run
        """
        return Self.result(await osa(["-e", script, key, url]))
    }

    func signInStep(_ email: String) async -> SignInStep {
        guard browser.running else { return .trouble(.notRunning) }
        let chromium = browser != .safari
        let busy = chromium ? "set busy to loading of t" : "set busy to ((do JavaScript \"document.readyState\" in t) is not \"complete\")"
        let exec = chromium ? "execute t javascript js" : "do JavaScript js in t"
        // Google's pages for TeachMore's sign-in carry TeachMore's address; other Google tabs are left alone.
        let script = """
        on run argv
            set tabKey to item 1 of argv
            set js to item 2 of argv
            with timeout of 20 seconds
                tell application id "\(browser.rawValue)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to ""
                            try
                                set u to (URL of t) as text
                            end try
                            if u starts with "https://accounts.google.com/" and u contains "teachmore" then
                                \(busy)
                                if busy then return "google:loading"
                                set r to \(exec)
                                if r is missing value then return "google:none"
                                return "google:" & r
                            end if
                        end repeat
                    end repeat
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to ""
                            try
                                set u to (URL of t) as text
                            end try
                            if u contains ("//" & tabKey) or u contains ("." & tabKey) then
                                \(busy)
                                if busy then return "teachmore:1:" & u
                                return "teachmore:0:" & u
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return "ONYX_NO_TAB"
        end run
        """
        switch Self.result(await osa(["-e", script, key, SchoolJS.pickAccount(email)])) {
        case .value(let out) where out.hasPrefix("google:"): return .google(String(out.dropFirst(7)))
        case .value(let out) where out.hasPrefix("teachmore:"):
            let rest = out.dropFirst(10)
            return .teachmore(url: String(rest.dropFirst(2)), loading: rest.hasPrefix("1"))
        case .value, .noTab: return .gone
        case let r: return .trouble(r)
        }
    }

    private static func result(_ r: (status: Int32, output: String)) -> SchoolPageResult {
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0 else {
            if out.contains("Allow JavaScript") || out.contains("JavaScript through AppleScript is turned off") { return .jsOff }
            if out.contains("-1743") || out.contains("-1744") || out.localizedCaseInsensitiveContains("not authorized") { return .notAllowed }
            if out.contains("-600") { return .notRunning }
            return .failed(out)
        }
        switch out {
        case "ONYX_NO_TAB": return .noTab
        case "ONYX_OPENED": return .opened
        case "ONYX_RELOADED": return .reloaded
        case "ONYX_TIMEOUT": return .failed("TeachMore didn't answer in time.")
        default: return .value(out)
        }
    }
}

/// The self-test's stand-in for your browser: the same JavaScript, run in a web view.
@MainActor final class WebSchoolPage: NSObject, SchoolPage, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private var loaded: CheckedContinuation<Void, Never>?

    func load(_ url: URL) async {
        web.navigationDelegate = self
        await withCheckedContinuation { c in loaded = c; web.load(URLRequest(url: url)) }
    }
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(); loaded = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded?.resume(); loaded = nil }

    func run(_ start: String, poll: String, openURL: String) async -> SchoolPageResult {
        guard web.url?.path.contains("google") != true else { return .noTab }   // like a tab that's on Google's sign-in
        guard (try? await web.evaluateJavaScript(start)) is String else { return .failed("The page didn't run the script.") }
        for _ in 0..<80 {
            if let r = try? await web.evaluateJavaScript(poll) as? String, !r.isEmpty { return .value(r) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .failed("TeachMore didn't answer in time.")
    }

    func navigate(_ url: String) async -> SchoolPageResult {
        guard let u = URL(string: url) else { return .failed("Bad link") }
        await load(u)
        return .value("ONYX_DONE")
    }

    func signInStep(_ email: String) async -> SignInStep {
        guard let u = web.url else { return .gone }
        if u.path.contains("google") {
            if web.isLoading { return .google("loading") }
            return .google((try? await web.evaluateJavaScript(SchoolJS.pickAccount(email)) as? String) ?? "none")
        }
        return .teachmore(url: u.absoluteString, loading: web.isLoading)
    }
}

// MARK: The JavaScript: the same requests TeachMore's own page makes

enum SchoolJS {
    static let poll = "(function(){var x=window.__onyxTM;return (x&&x.state!=='pending')?JSON.stringify(x):''})()"
    /// Which page the tab is on, and whether it has finished loading.
    static let here = "(function(){window.__onyxTM={state:'done',url:location.href,ready:document.readyState};return 'started';})()"

    /// Google's "Choose an account": clicks the matching account (or the only one listed). Stops if Google wants a password.
    static func pickAccount(_ email: String) -> String {
        """
        (function(E){E=(E||'').trim().toLowerCase();
        if(document.querySelector('input[type=password]'))return 'password';
        var els=[].slice.call(document.querySelectorAll('[data-identifier],[data-email]'));
        var ids=els.map(function(e){return (e.getAttribute('data-identifier')||e.getAttribute('data-email')||'').toLowerCase();});
        var uniq=ids.filter(function(x,i){return x&&ids.indexOf(x)===i;});
        var i=E?ids.indexOf(E):(uniq.length===1?ids.indexOf(uniq[0]):-1);
        if(i<0)return ids.length?'nomatch':'none';
        els[i].click();return 'clicked';})(\(lit(email)))
        """
    }

    /// Google's sign-in, in Onyx's own browser: picks your account, or types your email, then your saved password, and
    /// presses Next. It does nothing unless the page really is Google's sign-in (origin and path), and types the password
    /// once per page at most.
    static func signIn(_ email: String, password: String, origin: String, path: String) -> String {
        """
        (function(E,P,O,H){
        if(location.origin!==O||location.pathname.indexOf(H)!==0)return 'none';
        E=(E||'').trim().toLowerCase();
        function vis(e){if(!e)return false;var r=e.getBoundingClientRect();return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden';}
        function first(q){return [].slice.call(document.querySelectorAll(q)).filter(vis)[0];}
        function put(e,v){var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;e.focus();s.call(e,v);
          e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));}
        function next(id){var b=first('#'+id+' button')||first('#'+id);
          if(!b)b=[].slice.call(document.querySelectorAll('button')).filter(function(x){return vis(x)&&/^next$/i.test(x.textContent.trim());})[0];
          if(b){b.click();return true;}return false;}
        var pw=first('input[type=password]');
        if(pw){if(!P)return 'password';if(window.__onyxPw)return 'wait';put(pw,P);window.__onyxPw=1;return next('passwordNext')?'typed':'none';}
        var em=first('input[type=email],input[name=identifier]');
        if(em&&E){if(window.__onyxEm)return 'wait';put(em,E);window.__onyxEm=1;return next('identifierNext')?'email':'none';}
        var els=[].slice.call(document.querySelectorAll('[data-identifier],[data-email]'));
        var ids=els.map(function(e){return (e.getAttribute('data-identifier')||e.getAttribute('data-email')||'').toLowerCase();});
        var uniq=ids.filter(function(x,i){return x&&ids.indexOf(x)===i;});
        var i=E?ids.indexOf(E):(uniq.length===1?ids.indexOf(uniq[0]):-1);
        if(i>=0){els[i].click();return 'clicked';}
        if(E){var other=[].slice.call(document.querySelectorAll('li,div,a,button')).filter(function(x){return vis(x)&&x.children.length<4&&/^use another account$/i.test((x.textContent||'').trim());}).pop();
          if(other){other.click();return 'clicked';}}
        return ids.length?'nomatch':'none';})(\(lit(email)),\(lit(password)),\(lit(origin)),\(lit(path)))
        """
    }

    /// A JavaScript string literal.
    static func lit(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private static func wrap(_ path: String, _ body: String) -> String {
        """
        (function(){var B=\(lit(path));window.__onyxTM={state:'pending'};
        function done(x){x.state='done';window.__onyxTM=x;}
        function fail(e){done({status:0,error:String(e)});}
        function get(u){return fetch(B+u,{credentials:'same-origin',headers:{'X-Requested-With':'XMLHttpRequest','Accept':'application/json, text/javascript, */*; q=0.01'}});}
        function keep(r){return r.text().then(function(t){done({status:r.status,url:r.url,redirected:r.redirected,body:t});});}
        \(body)
        return 'started';})()
        """
    }

    /// The offerings list, exactly as the page loads it when you refresh (only one teacher's, when a teacher is chosen).
    static func search(_ path: String, teacher: String) -> String {
        wrap(path, "get('offerings/search?'+new URLSearchParams([['term',''],['date',''],['teacherID',\(lit(teacher))],['eventType',''],['rosteredOnly','0'],['openOnly','0']]).toString()).then(keep).catch(fail);")
    }

    /// Your name and the teacher list, from the Offerings page.
    static func info(_ path: String) -> String {
        wrap(path, """
        get('offerings').then(function(r){return r.text().then(function(t){
          var d=new DOMParser().parseFromString(t,'text/html'),sel=d.querySelector('#filterTeacher'),list=[];
          if(sel){sel.querySelectorAll('optgroup').forEach(function(g){var mine=/my/i.test(g.label||'');
            g.querySelectorAll('option').forEach(function(o){if(o.value)list.push({id:o.value,name:o.textContent.trim(),mine:mine});});});}
          var w=((d.querySelector('.navbar-text')||{}).textContent||'').replace(/^\\s*Welcome,\\s*/i,'').trim();
          done({status:r.status,url:r.url,teachers:list,name:w,signedIn:!!sel});});}).catch(fail);
        """)
    }

    /// What "Yes, Sign Me Up!" sends, with the page's security token (fetched fresh once if it has gone stale).
    static func signUp(_ path: String, _ o: SchoolOffering) -> String {
        let fields = [("date", o.date), ("teacherID", o.teacherID), ("eventType", o.event), ("offeringID", o.id), ("comment", "Offering Signup")]
            .map { "[\(lit($0.0)),\(lit($0.1))]" }.joined(separator: ",")
        return wrap(path, """
        var F=new URLSearchParams([\(fields)]).toString();
        function token(){var m=document.querySelector('meta[name="csrf-token"]');return m?m.content:'';}
        function fresh(){return get('offerings').then(function(r){return r.text();}).then(function(t){var m=t.match(/name="csrf-token"\\s+content="([^"]+)"/);return m?m[1]:'';});}
        function post(tok){return fetch(B+'appointment/create',{method:'POST',credentials:'same-origin',body:F,headers:{'X-CSRF-TOKEN':tok,
          'X-Requested-With':'XMLHttpRequest','Accept':'application/json, text/javascript, */*; q=0.01','Content-Type':'application/x-www-form-urlencoded; charset=UTF-8'}});}
        var t0=token();(t0?Promise.resolve(t0):fresh()).then(post).then(function(r){return r.status===419?fresh().then(post):r;}).then(keep).catch(fail);
        """)
    }
}

// MARK: - The watcher

@MainActor final class SchoolSignup: ObservableObject {
    static let shared = SchoolSignup()
    nonisolated static let onKey = "school.on", linkKey = "school.link", browserKey = "school.browser", teacherKey = "school.teacherID",
                           teacherNameKey = "school.teacherName", wordsKey = "school.words", dateKey = "school.date",
                           repeatKey = "school.repeat", replaceKey = "school.replace", googleKey = "school.google"
    nonisolated static let passwordAccount = "school.googlePassword"   // Keychain

    @Published private(set) var status: String?
    @Published private(set) var problem = false
    @Published private(set) var checking = false
    @Published private(set) var connecting = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var history: [SchoolSignupRecord] = []
    @Published private(set) var teachers: [SchoolTeacher] = []
    @Published private(set) var student: String?
    @Published private(set) var plans: [SchoolPlan] = []           // days you planned in the calendar
    @Published private(set) var offerings: [SchoolOffering] = []   // what's posted, for the calendar
    @Published private(set) var loadingOfferings = false
    @Published private(set) var hasPassword = false

    /// Self-test: a web view instead of your browser, settings that aren't saved, and no notch messages.
    var testPage: SchoolPage?
    var testSettings: SchoolSettings?
    private(set) var posts = 0   // sign-up requests sent (the self-test checks there's never a second one)

    private var done = Set<String>()      // offerings Onyx signed you up for: never again, even if you leave one
    private var failedAt: [String: Date] = [:]
    private var warned = Set<String>()    // notch warnings already shown; cleared once a check works
    private var lastOpened: Date?
    private var reauthTries = 0           // times Onyx sent the tab to "Sign in with Google" since the last check that worked
    private var badPassword = false       // Google turned the saved password down: never typed again until you save it again
    private var timer: Timer?
    private var file: URL { Prefs.supportDir.appendingPathComponent("school-signups.json") }

    private struct Saved: Codable { var history: [SchoolSignupRecord]; var done: [String]; var teachers: [SchoolTeacher]; var student: String?; var plans: [SchoolPlan]? }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            history = s.history; done = Set(s.done); teachers = s.teachers; student = s.student
            let today = Self.dayKey(Date())
            plans = (s.plans ?? []).filter { $0.date >= today }   // days gone by drop off
        }
    }

    private func save() {
        guard testSettings == nil else { return }
        if let d = try? JSONEncoder().encode(Saved(history: history, done: Array(done), teachers: teachers, student: student, plans: plans)) {
            try? d.write(to: file, options: .atomic)
        }
    }

    var settings: SchoolSettings { testSettings ?? .load() }

    /// Planned days still to come that Onyx hasn't signed you up for yet.
    var openPlans: [SchoolPlan] { let t = Self.dayKey(Date()); return plans.filter { !$0.done && $0.date >= t }.sorted { $0.date < $1.date } }

    /// Sets a day's academy (replacing what that day had).
    func plan(_ p: SchoolPlan) {
        plans.removeAll { $0.date == p.date }
        plans.append(p); plans.sort { $0.date < $1.date }
        save(); if testPage == nil { update() }
    }
    func unplan(_ date: String) {
        plans.removeAll { $0.date == date }
        save(); if testPage == nil { update() }
    }
    private func finish(_ date: String) {
        guard let i = plans.firstIndex(where: { $0.date == date }) else { return }
        plans[i].done = true; save()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in if SchoolSignup.shared.settings.on { SchoolSignup.shared.schedule(after: 20) } }
        }
        update()
    }

    /// Call after a setting changes.
    func update() {
        timer?.invalidate(); timer = nil
        let s = settings
        guard s.on else { if !checking { status = nil; problem = false }; return }
        schedule(after: 2)
    }

    private func schedule(after seconds: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in Task { @MainActor in await SchoolSignup.shared.check() } }.tolerant(0.1)
    }

    /// Every 30 seconds from 6 AM to 10 PM, every 3 minutes overnight.
    private var interval: Double { (6..<22).contains(Calendar.current.component(.hour, from: Date())) ? 30 : 180 }

    private func page(_ s: SchoolSettings, _ b: Base) -> SchoolPage { testPage ?? (s.browser == .onyx ? OnyxBrowser.shared : BrowserTab(browser: s.browser, key: b.host)) }

    /// Saves (or with nil, removes) the Google password Onyx's browser signs in with. Kept in your Keychain.
    func savePassword(_ p: String?) {
        if let p, !p.isEmpty { Keychain.set(p, account: Self.passwordAccount) } else { Keychain.delete(Self.passwordAccount) }
        badPassword = false; reauthTries = 0; checkPassword()
        if testPage == nil { update() }
    }
    func checkPassword() { hasPassword = Keychain.get(Self.passwordAccount)?.isEmpty == false }

    private func report(_ text: String, problem p: Bool) { status = text; problem = p }

    private func warn(_ key: String, _ text: String) {
        guard testSettings == nil, warned.insert(key).inserted else { return }
        NotchModel.shared.flash(.message(icon: "exclamationmark.triangle.fill", text: text, tint: .orange), for: 5)
    }

    /// Checks the list once and signs you up if the academy you want is there with a free seat.
    func check(force: Bool = false) async {
        while loadingOfferings { try? await Task.sleep(for: .milliseconds(200)) }   // one script in the tab at a time
        let s = settings
        guard !checking, force || s.on else { return }
        guard let b = Self.base(s.link) else { report("Paste your school's TeachMore link first.", problem: true); return }
        guard s.rule.isSet || !openPlans.isEmpty else { report("Choose a teacher or words to watch for, or plan a day in the calendar.", problem: true); return }
        // With days planned, look at every teacher's offerings; otherwise just the one teacher's, as the page shows them.
        let teacher = openPlans.isEmpty ? s.rule.teacherID : ""
        checking = true
        var next = interval
        defer {
            checking = false; lastCheck = Date()
            if settings.on && testPage == nil { schedule(after: next) }
        }
        if PrivateGuard.active && s.browser != .onyx { report("Waiting while a private window is open.", problem: false); next = 60; return }
        let p = page(s, b)
        var signedBackIn = false
        for _ in 0..<2 {
            // At most one new tab every half hour, and none while a Google sign-in is under way.
            let openURL = s.browser == .onyx || reauthTries == 0 && (lastOpened.map { Date().timeIntervalSince($0) > 1800 } ?? true) ? b.url + "offerings" : ""
            let r = await p.run(SchoolJS.search(b.path, teacher: teacher), poll: SchoolJS.poll, openURL: openURL)
            guard case .value(let raw) = r else { next = trouble(r, s); return }
            guard let res = Self.object(raw), !Self.signedOut(res, path: b.path), let list = Self.offerings(res["body"] as? String ?? "") else {
                if let res = Self.object(raw), Self.signedOut(res, path: b.path) {
                    // TeachMore only signs in with Google, and your browser is already signed in to Google: go through
                    // "Sign in with Google" now and carry on in this same check. Twice at most until a check works.
                    if !signedBackIn, reauthTries < 2 {
                        if let why = await reSignIn(p, b, s) {
                            report("TeachMore signed you out and Onyx couldn't sign you back in: \(why) \(s.browser == .onyx ? "Press Sign In… in Settings › Academy Sign-Up, sign in once yourself," : "Sign in to TeachMore once in \(s.browser.name)") and Onyx carries on."
                                   + (s.google.isEmpty ? " Adding your school Google account above helps next time." : ""), problem: true)
                            warn("signedOut", "Sign in to TeachMore again so Onyx can sign you up"); next = 300; return
                        }
                        signedBackIn = true
                        continue
                    }
                    report("TeachMore signed you out. \(s.browser == .onyx ? "Press Sign In… in Settings › Academy Sign-Up, sign in once yourself," : "Sign in to TeachMore once in \(s.browser.name)") and Onyx carries on.", problem: true)
                    warn("signedOut", "Sign in to TeachMore again so Onyx can sign you up"); next = 300
                } else { report("TeachMore sent something Onyx didn't understand. It tries again soon.", problem: true); next = 120 }
                return
            }
            warned.removeAll(); reauthTries = 0
            remember(list, teacher: teacher)
            if let n = await act(list, p, b, s) { next = n }
            // Signing in lands on TeachMore's home page (the calendar); put the tab back on Offerings.
            if signedBackIn { _ = await p.navigate(b.url + "offerings") }
            return
        }
    }

    /// Picks what to sign up for and does it: each day you planned in the calendar, then your academy on every other day.
    /// Returns when to check next, if sooner than usual.
    private func act(_ list: [SchoolOffering], _ p: SchoolPage, _ b: Base, _ s: SchoolSettings) async -> Double? {
        let today = Self.dayKey(Date())
        func lower(_ n: String) -> String { n.prefix(1).lowercased() + n.dropFirst() }
        func recent(_ o: SchoolOffering) -> Bool { failedAt[o.id].map { Date().timeIntervalSince($0) < 300 } ?? false }   // it said no a moment ago
        var waiting: [String] = [], spoke = false, next: Double?
        for plan in openPlans {
            let c = Self.choose(list, rule: plan.rule(replace: s.rule.replace), done: done, today: today)
            if c.satisfied { finish(plan.date); continue }
            guard let pick = c.pick else { waiting.append("\(plan.label) on \(Self.dayText(plan.date)): \(lower(c.note))"); continue }
            if recent(pick) { spoke = true; continue }
            spoke = true
            if await signUp(pick, p, b, s) { finish(plan.date) }
        }
        var over = !s.rule.isSet, note: String?   // over: nothing more to do for the teacher and words above
        if s.rule.isSet {
            let planned = Set(plans.map(\.date))   // a day you planned has its own academy
            let c = Self.choose(list.filter { !planned.contains($0.date) }, rule: s.rule, done: done, today: today)
            if c.satisfied, !s.rule.keepWatching { over = true; note = c.note }
            else if let pick = c.pick {
                spoke = true
                if !recent(pick), await signUp(pick, p, b, s) { if s.rule.keepWatching { next = 3 } else { over = true } }
            } else { waiting.insert("\(s.rule.label): \(lower(c.note))", at: 0) }
        }
        if over && openPlans.isEmpty {
            if !spoke { report("\(note ?? "You're signed up for every day you planned"), so Onyx stopped watching.", problem: false) }
            turnOff(); return nil
        }
        if !spoke, !waiting.isEmpty {
            report("Watching for " + waiting.prefix(2).joined(separator: "; ") + (waiting.count > 2 ? "; and \(waiting.count - 2) more" : "") + ".", problem: false)
        }
        return next
    }

    /// What's posted, for the calendar in Settings (one teacher's list only replaces that teacher's offerings).
    private func remember(_ list: [SchoolOffering], teacher: String) {
        let new = (teacher.isEmpty ? [] : offerings.filter { $0.teacherID != teacher }) + list
        if new != offerings { offerings = new }
    }

    /// Everything posted, for the calendar in Settings. Never opens a tab.
    func loadOfferings() async {
        let s = settings
        guard let b = Self.base(s.link), !loadingOfferings, !checking, !PrivateGuard.active || s.browser == .onyx else { return }
        loadingOfferings = true; defer { loadingOfferings = false }
        if case .value(let raw) = await page(s, b).run(SchoolJS.search(b.path, teacher: ""), poll: SchoolJS.poll, openURL: s.browser == .onyx ? b.url + "offerings" : ""),
           let res = Self.object(raw), !Self.signedOut(res, path: b.path), let list = Self.offerings(res["body"] as? String ?? "") {
            remember(list, teacher: "")
        }
    }

    /// Puts the tab on Offerings (if it's somewhere else, like TeachMore's calendar) and waits until the page has loaded.
    private func onOfferings(_ p: SchoolPage, _ b: Base) async -> Bool {
        let want = (b.path + "offerings").lowercased()
        var sent = false
        for _ in 0..<30 {   // about 15 seconds
            if case .value(let raw) = await p.run(SchoolJS.here, poll: SchoolJS.poll, openURL: ""), let h = Self.object(raw) {
                let path = (URLComponents(string: h["url"] as? String ?? "")?.path ?? "").lowercased()
                if path == want || path == want + "/" {
                    if h["ready"] as? String == "complete" { return true }
                } else if !sent {
                    sent = true
                    guard case .value = await p.navigate(b.url + "offerings") else { return false }
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Takes the tab through "Sign in with Google" in one go: picks your school account if Google asks, and comes back
    /// as soon as the tab is on TeachMore again. nil when you're signed in; otherwise what's in the way.
    private func reSignIn(_ p: SchoolPage, _ b: Base, _ s: SchoolSettings) async -> String? {
        guard case .value = await p.navigate(b.url + "auth/google") else { return "Onyx couldn't reach your TeachMore tab." }
        reauthTries += 1
        report("TeachMore signed you out, so Onyx is signing you back in with Google…", problem: false)
        // Onyx's own browser types your saved password on Google's sign-in page; your own browser is never typed into.
        let own = p as? OnyxBrowser
        if let own { own.password = badPassword ? "" : s.password ?? Keychain.get(Self.passwordAccount) ?? "" }
        defer { own?.password = "" }
        let yourself = " Or press Sign In… in Settings › Academy Sign-Up and sign in once yourself."
        var moved = false, clicks = 0, stuck = 0, lost = 0, out = 0, emails = 0, typed = 0, turnedDown = 0
        for poll in 1...60 {   // half a second apart: about 30 seconds in all
            try? await Task.sleep(for: .milliseconds(500))
            switch await p.signInStep(s.google) {
            case .google(let r):
                moved = true; lost = 0; out = 0
                switch r {
                case "loading", "wait": continue
                case "email":
                    emails += 1; stuck = 0
                    if emails > 2 { return "Google keeps asking for your email." }
                    report("Signing in to Google as \(s.google)…", problem: false)
                case "typed":
                    typed += 1; stuck = 0; turnedDown = 0
                    own?.password = ""   // never twice: a wrong password typed again and again can lock the account
                    report("Signing in to Google as \(s.google)…", problem: false)
                case "password" where own != nil:
                    if typed > 0 {   // Google is still asking after Onyx typed it: give it a moment, then call it turned down
                        turnedDown += 1
                        if turnedDown >= 8 {
                            badPassword = true
                            return "Google didn't accept the saved password, so Onyx won't type it again until you save it again in Settings › Academy Sign-Up."
                        }
                        continue
                    }
                    return badPassword ? "Google didn't accept the saved password, so Onyx won't type it again until you save it again in Settings › Academy Sign-Up."
                                       : "Google wants your password. Save it in Settings › Academy Sign-Up." + yourself
                case "clicked":
                    clicks += 1; stuck = 0
                    if clicks > 2 { return "Google keeps asking which account to use." }
                    report("Picking \(s.google.isEmpty ? "your Google account" : s.google) to sign back in to TeachMore…", problem: false)
                case "password": return "Google wants your password."
                default:   // an account Onyx can't pick, or a question for you
                    stuck += 1
                    if stuck >= 12 {
                        if own != nil { return "Google wants to check it's you (like a code from your phone)." + yourself }
                        return s.google.isEmpty ? "Google asks which account to use." : "Google didn't offer \(s.google), or it's asking you something."
                    }
                }
            case .teachmore(let url, let loading):
                lost = 0
                let u = url.lowercased()
                if loading || u.contains("/auth/google") { moved = true; continue }
                if u.contains(b.path.lowercased()) && !u.contains("/login") {
                    if moved || poll >= 4 { return nil }   // back on TeachMore, signed in
                    continue
                }
                out += 1   // TeachMore's sign-in page or its error page
                if out >= 6 { return "TeachMore didn't sign you in." }
            case .gone:
                lost += 1
                if lost >= 10 { return "Onyx lost track of your TeachMore tab." }
            case .trouble(let r):
                _ = trouble(r, s); return "Onyx couldn't reach \(s.browser.name)."
            }
        }
        return "Signing in with Google took too long."
    }

    /// What to do when the browser couldn't be reached. Returns when to try again.
    private func trouble(_ r: SchoolPageResult, _ s: SchoolSettings) -> Double {
        switch r {
        case .notRunning:
            report("Open \(s.browser.name) and sign in to TeachMore. Onyx checks again in 2 minutes.", problem: true)
            warn("notRunning", "Open \(s.browser.name) so Onyx can watch TeachMore"); return 120
        case .noTab where s.browser == .onyx:
            report("Onyx's browser hasn't opened TeachMore yet. Press Connect in Settings › Academy Sign-Up.", problem: true); return 120
        case .noTab where reauthTries > 0:   // the tab is on Google's sign-in page
            report("Finish signing in with Google in \(s.browser.name). Onyx sent your TeachMore tab there because TeachMore signed you out." + (s.google.isEmpty ? " Add your school Google account in Settings › Academy Sign-Up so Onyx can pick it next time." : ""), problem: true)
            warn("google", "Finish signing in to TeachMore in \(s.browser.name)"); return 60
        case .noTab:
            report("Open a \(s.browser.name) window with TeachMore in it.", problem: true); return 120
        case .opened:
            lastOpened = Date(); report("Opened TeachMore in a background tab in \(s.browser.name).", problem: false); return 10
        case .reloaded:
            report("Woke up the TeachMore tab.", problem: false); return 10
        case .jsOff:
            report("Turn on \(s.browser.javaScriptSetting) so Onyx can use your TeachMore tab.", problem: true)
            warn("jsOff", "Turn on Allow JavaScript from Apple Events in \(s.browser.name)"); return 300
        case .notAllowed:
            report("Allow Onyx to control \(s.browser.name) in System Settings › Privacy & Security › Automation.", problem: true)
            warn("notAllowed", "Let Onyx control \(s.browser.name) for TeachMore sign-ups"); return 300
        case .failed(let e):
            report("Couldn't check TeachMore: \(e.prefix(160))", problem: true); return 60
        case .value: return interval
        }
    }

    private func signUp(_ o: SchoolOffering, _ p: SchoolPage, _ b: Base, _ s: SchoolSettings) async -> Bool {
        report("Signing you up for “\(o.title)” on \(o.day)…", problem: false)
        // Always from the Offerings page, never TeachMore's calendar: a sign-up made there can say it worked when it didn't.
        guard await onOfferings(p, b) else {
            failedAt[o.id] = Date(); report("Couldn't get your TeachMore tab onto Offerings to sign up for “\(o.title)”. Onyx tries again in 5 minutes.", problem: true)
            return false
        }
        posts += 1
        guard case .value(let raw) = await p.run(SchoolJS.signUp(b.path, o), poll: SchoolJS.poll, openURL: ""), let res = Self.object(raw) else {
            failedAt[o.id] = Date(); report("Couldn't reach TeachMore to sign up for “\(o.title)”. Onyx tries again in 5 minutes.", problem: true)
            return false
        }
        let answer = Self.object(res["body"] as? String ?? "")
        let ok = (answer?["success"] as? NSNumber)?.boolValue ?? false
        guard ok else {
            failedAt[o.id] = Date()
            let why = (answer?["message"] as? String).map(Self.plain) ?? (Self.signedOut(res) ? "you were signed out" : "it answered \((res["status"] as? NSNumber)?.intValue ?? 0)")
            report("TeachMore didn't sign you up for “\(o.title)” on \(o.day): \(why). Onyx tries again in 5 minutes.", problem: true)
            warn("no-\(o.id)", "Couldn't sign up for \(Self.short(o.title)): \(why)")
            return false
        }
        // Check TeachMore now lists you.
        var listed = false
        if case .value(let again) = await p.run(SchoolJS.search(b.path, teacher: o.teacherID), poll: SchoolJS.poll, openURL: ""),
           let list = Self.object(again).flatMap({ Self.offerings($0["body"] as? String ?? "") }) {
            listed = list.contains { $0.id == o.id && $0.enrolled }
        }
        done.insert(o.id)
        history.insert(SchoolSignupRecord(id: o.id, title: o.title, teacher: o.teacher, date: o.date, at: Date(), confirmed: listed), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        save()
        let with = o.teacher.isEmpty ? "" : " with \(o.teacher)"
        report(listed ? "Signed you up for “\(o.title)”\(with) on \(o.day)." : "TeachMore accepted “\(o.title)” on \(o.day) but doesn't list it yet. Check TeachMore to be sure.", problem: !listed)
        if testSettings == nil {
            NotchModel.shared.flash(.message(icon: "checkmark.seal.fill", text: "Signed up: \(Self.short(o.title)) · \(o.day)", tint: .green), for: 6)
        }
        return true
    }

    private func turnOff() {
        if testSettings != nil { testSettings?.on = false } else { UserDefaults.standard.set(false, forKey: Self.onKey) }
        timer?.invalidate(); timer = nil
    }

    /// Loads your name and the teacher list (and checks Onyx can reach your TeachMore tab).
    func connect() async {
        let s = settings
        guard let b = Self.base(s.link) else { report("Paste your school's TeachMore link first.", problem: true); return }
        connecting = true; defer { connecting = false }
        let p = page(s, b)
        var r = await p.run(SchoolJS.info(b.path), poll: SchoolJS.poll, openURL: b.url + "offerings")
        // Onyx's own browser signs itself in the first time.
        if s.browser == .onyx, case .value(let raw) = r, let res = Self.object(raw), Self.signedOut(res) || (res["signedIn"] as? NSNumber)?.boolValue != true {
            if let why = await reSignIn(p, b, s) { report("Onyx couldn't sign in to TeachMore: \(why)", problem: true); return }
            r = await p.run(SchoolJS.info(b.path), poll: SchoolJS.poll, openURL: b.url + "offerings")
        }
        guard case .value(let raw) = r else { _ = trouble(r, s); return }
        guard let res = Self.object(raw), !Self.signedOut(res), (res["signedIn"] as? NSNumber)?.boolValue == true else {
            report("Sign in to TeachMore in \(s.browser.name), then press Connect again.", problem: true); return
        }
        let list = (res["teachers"] as? [[String: Any]] ?? []).compactMap { t -> SchoolTeacher? in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return SchoolTeacher(id: id, name: Self.plain(name), mine: (t["mine"] as? NSNumber)?.boolValue ?? false)
        }
        var seen = Set<String>()   // "My Teachers" first; the full list repeats them
        teachers = list.sorted { $0.mine && !$1.mine }.filter { seen.insert($0.id).inserted }
        let name = (res["name"] as? String).map(Self.plain) ?? ""
        student = name.isEmpty ? nil : name
        warned.removeAll(); reauthTries = 0
        report("Connected\(student.map { " as \($0)" } ?? ""). \(teachers.count) teachers.", problem: false)
        save()
        await loadOfferings()
    }

    // MARK: Helpers (pure, so the self-test can check them)

    struct Base: Equatable {
        var url: String, path: String, key: String
        var host: String { String(key.dropLast(path.count - 1)) }   // "teachmore.org/"
    }

    /// Any TeachMore link → the school's student pages. "https://teachmore.org/lincoln/students/dashboard" →
    /// url "https://teachmore.org/lincoln/students/", path "/lincoln/students/", key "teachmore.org/lincoln/students/".
    nonisolated static func base(_ link: String) -> Base? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let local = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard local || host == "teachmore.org" || host.hasSuffix(".teachmore.org") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        let school: [String]
        if let i = parts.firstIndex(where: { $0.lowercased() == "students" }), i > 0 { school = Array(parts[..<i]) }
        else if let f = parts.first { school = [f] } else { return nil }
        let path = "/" + (school + ["students"]).joined(separator: "/") + "/"
        let hostPort = host + (c.port.map { ":\($0)" } ?? "")
        return Base(url: "\(scheme)://\(hostPort)\(path)", path: path, key: hostPort + path)
    }

    /// Picks the earliest offering you can be signed up for, or says why there isn't one.
    nonisolated static func choose(_ list: [SchoolOffering], rule: SchoolRule, done: Set<String>, today: String) -> SchoolChoice {
        let matches = list.filter { rule.matches($0) && $0.date >= today }.sorted { $0.date < $1.date }
        guard !matches.isEmpty else { return SchoolChoice(pick: nil, note: "Not posted yet") }
        if !rule.keepWatching, let e = matches.first(where: \.enrolled) {
            return SchoolChoice(pick: nil, note: "You're signed up for “\(e.title)” on \(e.day)", satisfied: true)
        }
        let signedDays = Set(matches.filter(\.enrolled).map(\.date))
        var why: [String] = []
        for o in matches where !o.enrolled && !signedDays.contains(o.date) {
            if done.contains(o.id) { continue }   // Onyx signed you up once; if you left it, it stays left
            if o.unavailable { why.append("\(o.day) is only for students on the teacher's list"); continue }
            if o.full { why.append("\(o.day) is full, waiting for a seat"); continue }
            if o.hasAppt && o.apptType == 1 { why.append("a teacher assigned you somewhere else on \(o.day)"); continue }
            if o.hasAppt && o.sameDayLocked && o.date == today { why.append("your sign-up for \(o.day) can't change on the day"); continue }
            if o.hasAppt && !rule.replace {
                why.append("you're already signed up on \(o.day)\(o.existingTeacher.isEmpty ? "" : " with \(o.existingTeacher)")"); continue
            }
            return SchoolChoice(pick: o, note: "")
        }
        if why.isEmpty { return SchoolChoice(pick: nil, note: signedDays.isEmpty ? "Not posted yet" : "You're signed up for every date posted so far") }
        return SchoolChoice(pick: nil, note: "Posted, but " + why.prefix(2).joined(separator: "; "))
    }

    nonisolated static func object(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    nonisolated static func offerings(_ body: String) -> [SchoolOffering]? {
        ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]])?.compactMap(SchoolOffering.init)
    }

    /// TeachMore answers a signed-out request with 401/403/419, or by sending it to a sign-in page or to a 404 page
    /// outside the school's pages.
    nonisolated static func signedOut(_ r: [String: Any], path: String = "") -> Bool {
        let st = (r["status"] as? NSNumber)?.intValue ?? 0, url = (r["url"] as? String ?? "").lowercased()
        let redirected = (r["redirected"] as? NSNumber)?.boolValue ?? false
        return [401, 403, 419].contains(st) || url.contains("/login") || (redirected && !path.isEmpty && !url.contains(path.lowercased()))
    }

    nonisolated static func plain(_ s: String) -> String {
        var t = s
        for (a, b) in [("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func fold(_ s: String) -> String { plain(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    nonisolated static func short(_ s: String) -> String { s.count > 36 ? String(s.prefix(35)) + "…" : s }

    nonisolated static func dayKey(_ d: Date) -> String { dayFormatter.string(from: d) }
    nonisolated static func date(_ key: String) -> Date? { dayFormatter.date(from: key) }
    nonisolated static func dayText(_ key: String) -> String {
        date(key).map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? key
    }
    nonisolated private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}

// MARK: - Settings › Academy Sign-Up

struct SchoolSetupSteps: View {
    @AppStorage(SchoolSignup.browserKey) private var browser = SchoolBrowser.chrome.rawValue

    var body: some View {
        let b = SchoolBrowser(rawValue: browser) ?? .chrome
        Section("How to set it up") {
            if b == .onyx {
                step(1, "Paste your TeachMore link below (the sign-in page is fine).")
                step(2, "Add your school Google account and its password, then press Connect. Onyx signs in to TeachMore in its own browser, in the background, so no other browser needs to be open.")
                step(3, "Pick the teacher (★ marks yours) or words in the academy's title, or plan days in the calendar below, then turn on Watch TeachMore and sign me up.")
            } else {
                step(1, "Sign in to TeachMore in \(b.name), the way you always do.")
                step(2, "Turn on \(b.javaScriptSetting).")
                step(3, "Paste your TeachMore link below (the sign-in page is fine) and press Connect. macOS asks once to let Onyx control \(b.name): click Allow.")
                step(4, "Pick the teacher (★ marks yours) or words in the academy's title, or plan days in the calendar below, then turn on Watch TeachMore and sign me up.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Circle().fill(.orange.opacity(0.3)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SchoolSignupSection: View {
    @ObservedObject var school = SchoolSignup.shared
    @AppStorage(SchoolSignup.onKey) private var on = false
    @AppStorage(SchoolSignup.linkKey) private var link = ""
    @AppStorage(SchoolSignup.browserKey) private var browser = SchoolBrowser.chrome.rawValue
    @AppStorage(SchoolSignup.googleKey) private var google = ""
    @AppStorage(SchoolSignup.teacherKey) private var teacher = ""
    @AppStorage(SchoolSignup.teacherNameKey) private var teacherName = ""
    @AppStorage(SchoolSignup.wordsKey) private var words = ""
    @AppStorage(SchoolSignup.dateKey) private var date = ""
    @AppStorage(SchoolSignup.repeatKey) private var keep = false
    @AppStorage(SchoolSignup.replaceKey) private var replace = true
    @State private var password = ""

    private var own: Bool { browser == SchoolBrowser.onyx.rawValue }
    private var browserName: String { (SchoolBrowser(rawValue: browser) ?? .chrome).name }
    private var ready: Bool { SchoolSignup.base(link) != nil && (!teacher.isEmpty || !words.trimmingCharacters(in: .whitespaces).isEmpty || !school.openPlans.isEmpty) }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                TextField("TeachMore link", text: $link, prompt: Text("teachmore.org/yourschool/students/login"))
                Text("Any TeachMore page works, like the sign-in page. Onyx signs in with Google, goes to Offerings and signs you up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !link.isEmpty && SchoolSignup.base(link) == nil {
                Text("That doesn't look like a TeachMore link. Copy it from your browser's address bar.").font(.caption).foregroundStyle(.orange)
            }
            Picker("Browser", selection: $browser) {
                ForEach(SchoolBrowser.allCases.filter { $0.installed || $0.rawValue == browser }) { Text($0 == .onyx ? "Onyx's own browser (in the background)" : $0.name).tag($0.rawValue) }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("School Google account", text: $google, prompt: Text("you@yourschool.org"))
                Text(own ? "Onyx signs in to TeachMore with Google as this account, in its own browser."
                         : "When TeachMore signs you out, Onyx signs you back in with Google. If Google asks which account to use, it picks this one (or the only one there). It never types a password into \(browserName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if own {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        SecureField("Google password", text: $password, prompt: Text(school.hasPassword ? "Saved in your Keychain" : "Your school Google password"))
                        Button("Save") { school.savePassword(password); password = "" }.disabled(password.isEmpty)
                        if school.hasPassword { Button("Remove", role: .destructive) { school.savePassword(nil) } }
                    }
                    Text("Kept in your Keychain. Onyx types it only on Google's own sign-in page (accounts.google.com), only in its own browser, and only when TeachMore has signed you out. If Google turns it down, Onyx doesn't try it again until you save it again. If Google wants a code from your phone, press Sign In… and finish once yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { school.checkPassword() }
            }
            HStack {
                Button(school.teachers.isEmpty ? "Connect" : "Refresh Teachers") { Task { await school.connect() } }
                    .disabled(school.connecting || SchoolSignup.base(link) == nil)
                if own, let b = SchoolSignup.base(link) { Button("Sign In…") { OnyxBrowser.shared.show(b.url + "auth/google") }.help("Open Onyx's browser to sign in yourself, or to look at TeachMore") }
                if school.connecting { ProgressView().controlSize(.small) }
                if let s = school.student { Text("Signed in as \(s)").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("Teacher", selection: $teacher) {
                Text("Any teacher").tag("")
                if !teacher.isEmpty && !school.teachers.contains(where: { $0.id == teacher }) { Text(teacherName.isEmpty ? teacher : teacherName).tag(teacher) }
                ForEach(school.teachers) { t in Text(t.mine ? "★ \(t.name)" : t.name).tag(t.id) }
            }
            .disabled(school.teachers.isEmpty && teacher.isEmpty)
            .onChange(of: teacher) { _, id in
                teacherName = school.teachers.first { $0.id == id }.map { $0.name.replacingOccurrences(of: #"\s*\(Period.*\)$"#, with: "", options: .regularExpression) } ?? ""
            }
            TextField("Title has the words", text: $words, prompt: Text("Optional, like “robotics”"))
            if !school.plans.isEmpty { Text("The teacher and words cover every day you haven't planned in the calendar below.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Only on a certain day", isOn: Binding(get: { !date.isEmpty }, set: { date = $0 ? SchoolSignup.dayKey(Date().addingTimeInterval(86400)) : "" }))
            if !date.isEmpty {
                DatePicker("Day", selection: Binding(get: { SchoolSignup.date(date) ?? Date() }, set: { date = SchoolSignup.dayKey($0) }), displayedComponents: .date)
            }
            Picker("If I already have a sign-up that day", selection: $replace) {
                Text("Switch to this academy").tag(true)
                Text("Keep what I have").tag(false)
            }
            Picker("After signing me up", selection: $keep) {
                Text("Stop watching").tag(false)
                Text("Keep watching for new dates").tag(true)
            }
            Toggle("Watch TeachMore and sign me up", isOn: $on).disabled(!ready && !on)
            if on || school.status != nil {
                HStack(alignment: .firstTextBaseline) {
                    Button("Check Now") { Task { await school.check(force: true) } }.disabled(school.checking || !ready)
                    if school.checking { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 1) {
                        if let s = school.status { Text(s).font(.caption).foregroundStyle(school.problem ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
                        if let d = school.lastCheck, on { Text("Checked \(d.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            ForEach(school.history.prefix(5)) { h in
                HStack(spacing: 8) {
                    Image(systemName: h.confirmed ? "checkmark.seal.fill" : "questionmark.circle").foregroundStyle(h.confirmed ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.title).lineLimit(1)
                        Text("\(SchoolSignup.dayText(h.date))\(h.teacher.isEmpty ? "" : " · \(h.teacher)") · signed up \(h.at.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Academy sign-up (TeachMore)") } footer: {
            Text(own ? "Onyx checks your offerings list every 30 seconds (every 3 minutes overnight) in its own browser, in the background, with its own sign-in (apart from your browsers). When the academy you chose is posted with a free seat, it signs you up, checks TeachMore lists you, and tells you in the notch. It never replaces an appointment a teacher assigned, and never signs you up again for one you left. Your Mac needs to be awake. Make sure your school is fine with automatic sign-ups."
                     : "Onyx checks your offerings list every 30 seconds (every 3 minutes overnight) in your own signed-in \(browserName) tab, so it never sees your password. When the academy you chose is posted with a free seat, it signs you up, checks TeachMore lists you, and tells you in the notch. It never replaces an appointment a teacher assigned, and never signs you up again for one you left. First turn on View › Developer › Allow JavaScript from Apple Events in \(browserName); macOS asks once to let Onyx control it. Your Mac needs to be awake with \(browserName) open. Make sure your school is fine with automatic sign-ups.")
        }
        .onChange(of: on) { _, _ in school.update() }
        .onChange(of: link) { _, _ in school.update() }
        .onChange(of: browser) { _, _ in school.update() }
        .onChange(of: teacher) { _, _ in school.update() }
        .onChange(of: date) { _, _ in school.update() }
    }
}

// MARK: - Settings › Academy Sign-Up › the calendar: a different academy for each day

struct SchoolCalendarSection: View {
    @ObservedObject var school = SchoolSignup.shared
    @AppStorage(SchoolSignup.onKey) private var on = false
    @AppStorage(SchoolSignup.linkKey) private var link = ""
    @State private var from = SchoolCalendarSection.week(Date())   // five weeks from here, starting this week
    @State private var picked: String?   // the day you pressed, "yyyy-MM-dd"
    @State private var teacher = ""
    @State private var words = ""

    init(day: String? = nil) { _picked = State(initialValue: day) }

    static func week(_ d: Date) -> Date { Calendar.current.dateInterval(of: .weekOfYear, for: d)?.start ?? Calendar.current.startOfDay(for: d) }

    var body: some View {
        Section {
            grid
            if let d = picked { day(d) }
            if !on && !school.openPlans.isEmpty {
                Text("Turn on Watch TeachMore and sign me up above so Onyx signs you up for these days.").font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("Plan days in the calendar") } footer: {
            Text("Press a day to choose its academy: one that's posted, or a teacher's (or words in the title) whenever it's posted for that day. Each day keeps its own choice. Onyx always signs you up from TeachMore's Offerings page, never from TeachMore's calendar, because a sign-up made there can say it worked when it didn't.")
        }
        .task { if school.offerings.isEmpty, SchoolSignup.base(link) != nil { await school.loadOfferings() } }
    }

    private var grid: some View {
        let c = Calendar.current
        let days = (0..<35).map { c.date(byAdding: .day, value: $0, to: from)! }
        let today = SchoolSignup.dayKey(Date())
        let symbols = c.shortWeekdaySymbols
        let ordered = Array(symbols[(c.firstWeekday - 1)...] + symbols[..<(c.firstWeekday - 1)])
        return VStack(spacing: 6) {
            HStack {
                Button { from = max(Self.week(Date()), c.date(byAdding: .day, value: -35, to: from)!) } label: { Image(systemName: "chevron.left") }
                    .disabled(from <= Self.week(Date())).accessibilityLabel("Earlier weeks")
                Text("\(days[0].formatted(.dateTime.month(.abbreviated).day())) – \(days[34].formatted(.dateTime.month(.abbreviated).day().year()))")
                    .font(.headline).frame(maxWidth: .infinity)
                Button { from = c.date(byAdding: .day, value: 35, to: from)! } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Later weeks")
                Button { Task { await school.loadOfferings() } } label: {
                    if school.loadingOfferings { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(school.loadingOfferings || SchoolSignup.base(link) == nil).help("Load what's posted on TeachMore").accessibilityLabel("Load what's posted")
            }
            .buttonStyle(.borderless)
            // Weekday names get negative ids so they never collide with the days.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(-7..<0, id: \.self) { i in Text(ordered[i + 7]).font(.caption2).foregroundStyle(.secondary) }
                ForEach(0..<35, id: \.self) { i in
                    let n = c.component(.day, from: days[i])
                    cell(SchoolSignup.dayKey(days[i]), n == 1 || i == 0 ? days[i].formatted(.dateTime.month(.abbreviated).day()) : "\(n)", today)
                }
            }
            HStack(spacing: 12) {
                legend("star.fill", .orange, "Planned"); legend("checkmark.seal.fill", .green, "Signed up"); legend("circle.fill", .blue, "Posted")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legend(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 3) { Image(systemName: icon).font(.system(size: 7)).foregroundStyle(tint); Text(text) }
    }

    private func cell(_ key: String, _ n: String, _ today: String) -> some View {
        let plan = school.plans.first { $0.date == key }
        let posted = school.offerings.filter { $0.date == key }
        let enrolled = posted.contains(where: \.enrolled)
        let past = key < today, sel = picked == key
        return Button { choose(sel ? nil : key) } label: {
            VStack(spacing: 2) {
                Text(n).font(.system(size: 12, weight: key == today ? .bold : .regular))
                    .foregroundStyle(key == today ? Color.red : past ? Color.secondary.opacity(0.5) : Color.primary)
                Group {
                    if let plan { Image(systemName: plan.done ? "checkmark.seal.fill" : "star.fill").foregroundStyle(plan.done ? .green : .orange) }
                    else if enrolled { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    else if !posted.isEmpty && !past { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.blue) }
                    else { Color.clear }
                }
                .font(.system(size: 8)).frame(height: 9)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(sel ? Color.accentColor.opacity(0.28) : plan != nil && !past ? (plan!.done ? Color.green : Color.orange).opacity(0.14) : Color.primary.opacity(past ? 0 : 0.04),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(past)
        .accessibilityLabel(SchoolSignup.dayText(key) + (plan.map { ", \($0.done ? "signed up" : "planned"): \($0.label)" } ?? (posted.isEmpty ? "" : ", \(posted.count) posted")))
    }

    private func choose(_ key: String?) {
        picked = key
        let plan = key.flatMap { k in school.plans.first { $0.date == k } }
        teacher = plan?.offeringID.isEmpty == true ? plan?.teacherID ?? "" : ""
        words = plan?.offeringID.isEmpty == true ? plan?.words ?? "" : ""
    }

    private func day(_ key: String) -> some View {
        let plan = school.plans.first { $0.date == key }
        let posted = school.offerings.filter { $0.date == key }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let w = words.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SchoolSignup.date(key)?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? key).font(.headline)
                Spacer()
                if plan != nil { Button("Clear This Day") { school.unplan(key); choose(key) } }
            }
            if let plan {
                Label(plan.done ? "Signed up: \(plan.label)" : "Planned: \(plan.label)", systemImage: plan.done ? "checkmark.seal.fill" : "star.fill")
                    .foregroundStyle(plan.done ? .green : .orange)
            }
            if posted.isEmpty {
                Text(school.offerings.isEmpty ? "Press ↻ above to load what's posted." : "Nothing's posted for this day yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(posted, id: \.id) { o in row(o, key, plan) }
            }
            Text("Or whenever it's posted for this day:").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            HStack {
                Picker("Teacher", selection: $teacher) {
                    Text("Any teacher").tag("")
                    if !teacher.isEmpty && !school.teachers.contains(where: { $0.id == teacher }) { Text(plan?.teacherName ?? teacher).tag(teacher) }
                    ForEach(school.teachers) { t in Text(t.mine ? "★ \(t.name)" : t.name).tag(t.id) }
                }
                .labelsHidden().fixedSize()
                TextField("Title words", text: $words, prompt: Text("Title words (optional)")).labelsHidden()
                Button("Plan") {
                    school.plan(SchoolPlan(date: key, teacherID: teacher, teacherName: name(teacher, fallback: plan?.teacherName ?? ""), words: w))
                }
                .disabled(teacher.isEmpty && w.isEmpty)
            }
            if school.teachers.isEmpty { Text("Press Connect above to load the teacher list.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func row(_ o: SchoolOffering, _ key: String, _ plan: SchoolPlan?) -> some View {
        let chosen = plan?.offeringID == o.id
        let note = o.enrolled ? "you're signed up" : o.unavailable ? "only for the teacher's students" : o.full ? "full: Onyx waits for a seat"
                 : o.hasAppt && o.apptType == 1 ? "a teacher assigned you somewhere else" : ""
        return HStack(spacing: 8) {
            Image(systemName: chosen ? "star.fill" : o.enrolled ? "checkmark.seal.fill" : "circle").foregroundStyle(chosen ? .orange : o.enrolled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.title).lineLimit(1)
                Text([o.teacher, note].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !o.enrolled && !chosen {
                Button("Choose") { school.plan(SchoolPlan(date: key, teacherID: o.teacherID, teacherName: o.teacher, offeringID: o.id, title: o.title)) }
                    .disabled(o.unavailable || (o.hasAppt && o.apptType == 1))
            }
        }
    }

    private func name(_ id: String, fallback: String) -> String {
        school.teachers.first { $0.id == id }.map { $0.name.replacingOccurrences(of: #"\s*\(Period.*\)$"#, with: "", options: .regularExpression) } ?? fallback
    }
}
