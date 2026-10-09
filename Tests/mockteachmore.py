#!/usr/bin/env python3
"""A stand-in TeachMore for Onyx's academy sign-up self-test: http://127.0.0.1:8767 (this Mac only).
It answers the same three requests the real Offerings page makes (the page, offerings/search and appointment/create),
with made-up offerings. GET /__mock/set?name=<scenario>[&reset=1] changes what's posted; GET /__mock/log lists every
sign-up request it received. Everything is also logged to the file given as the first argument."""
import datetime, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "/dev/null"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8767
B = "/lincoln/students/"
today = datetime.date.today()
def d(n): return (today + datetime.timedelta(days=n)).isoformat()

def off(uid, title, tid, last, first, day, cap="20", left=10, restricted=False, appt=None, existing=""):
    return {"uniqueID": uid, "offering": title, "teacherID": tid, "teacherLast": last, "teacherFirst": first, "offeringDate": day,
            "offeringEvent": "1", "eventName": "Academy", "offeringCap": cap, "numberLeft": left, "isFull": False,
            "isRestricted": restricted, "isEnrolled": False, "hasAppt": appt is not None, "existingApptType": appt or 0,
            "existingTeacher": existing, "existingDayOfEdits": "yes", "groupDisplay": "All Students"}

BASE = [
    off("2750", "AP Physics Academy", "200101", "Okafor", "Dana", d(1), "25", 19),
    off(2128, "Mandarin Academy (B2) ", 200102, "Lindqvist", "Mei", d(1), "12", 0),          # numbers, full
    off("3942", "Government - Room B4", "tbrooks", "Brooks", "Theo", d(3), "N/A", None),
]
SCENARIOS = {
    "start": [],
    "post": [off("5001", "Robotics Club &amp; Build Night", "305", "Park", "Julia", d(3), "20", 3, appt=3, existing="Castillo-Reyes, Ana")],
    "locked": [off("5002", "Robotics Club", "305", "Park", "Julia", d(8), "20", 5, appt=1, existing="Moreau, Elena")],
    "full": [off("5003", "Robotics Club", "305", "Park", "Julia", d(8), "10", 0)],
    "seat": [off("5003", "Robotics Club", "305", "Park", "Julia", d(8), "10", 1)],
    "restricted": [off("5004", "Robotics Club", "305", "Park", "Julia", d(10), "10", 9, restricted=True)],
    "stale": [off("5005", "Robotics Club", "305", "Park", "Julia", d(9), "10", 4)],
    "conflict": [off("5006", "Robotics Club", "305", "Park", "Julia", d(11), "10", 4, appt=3, existing="Castillo-Reyes, Ana")],
    "days": [off("6001", "Robotics Club", "305", "Park", "Julia", d(2), "20", 5), off("6002", "Chess Club", "200103", "Moreau", "Elena", d(2), "20", 5),
             off("6003", "Robotics Club", "305", "Park", "Julia", d(4), "20", 5), off("6004", "Chess Club", "200103", "Moreau", "Elena", d(4), "20", 5)],
    "far": [off("7001", "Robotics Club", "305", "Park", "Julia", d(2), "20", 5), off("7002", "Robotics Club", "305", "Park", "Julia", d(20), "20", 5)],
    "signedout": [],
    "chooser": [],
    "password": [],
}
state = {"name": "start", "enrolled": set(), "taken": {}, "posts": [], "searches": 0, "token": "tok-1", "out": False, "chooser": False, "auth": 0, "pwflow": False, "typed": "", "pwtries": 0}

def offerings():
    out = []
    for o in BASE + SCENARIOS[state["name"]]:
        o = dict(o); uid = str(o["uniqueID"])
        if o["numberLeft"] is not None: o["numberLeft"] = o["numberLeft"] - state["taken"].get(uid, 0)
        o["isEnrolled"] = uid in state["enrolled"]
        mine = [x for x in BASE + SCENARIOS[state["name"]] if str(x["uniqueID"]) in state["enrolled"] and x["offeringDate"] == o["offeringDate"]]
        if mine and not o["isEnrolled"]:
            o.update(hasAppt=True, existingApptType=3, existingTeacher="%s, %s" % (mine[0]["teacherLast"], mine[0]["teacherFirst"]))
        out.append(o)
    return out

PAGE = """<!DOCTYPE html><html lang="en"><head><meta name="viewport" content="width=device-width">
<meta name="csrf-token" content="%s"><title>Offerings</title></head><body>
<nav class="navbar"><ul class="navbar-nav ml-auto"><li class="nav-item"><span class="navbar-text text-white mr-3">
                        Welcome, Sam                    </span></li></ul></nav>
<select id="filterTeacher" class="form-control select2"><option value="">All Teachers</option>
<optgroup label="My Teachers"><option value="200103">Moreau, Elena (Period 1)</option><option value="305">Park, Julia (Period 2)</option></optgroup>
<optgroup label="All Teachers"><option value="200101">Okafor, Dana</option><option value="305">Park, Julia</option>
<option value="200103">Moreau, Elena</option><option value="200102">Lindqvist, Mei</option><option value="tbrooks">Brooks, Theo</option></optgroup>
</select><div id="resultsArea" class="list-group"></div></body></html>"""

def log(line):
    with open(LOG, "a") as f: f.write(line + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body, kind="application/json", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(data)))
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
        log("GET " + self.path)
        if u.path == "/__mock/set":
            state["name"] = q["name"]
            if q.get("reset"): state.update(enrolled=set(), taken={}, posts=[], token="tok-1", out=False, chooser=False, auth=0, picked="", pwflow=False, typed="", pwtries=0)
            if q["name"] == "stale": state["token"] = "tok-2"      # the page still holds tok-1
            if q["name"] in ("signedout", "chooser", "password"): state.update(out=True, chooser=q["name"] == "chooser", pwflow=q["name"] == "password")
            return self.send(200, json.dumps({"ok": True}))
        if u.path == "/__mock/log":
            return self.send(200, json.dumps({"posts": state["posts"], "searches": state["searches"], "auth": state["auth"], "picked": state.get("picked", ""), "typed": state["typed"], "pwtries": state["pwtries"]}))
        if u.path == "/__mock/cal.ics":     # a calendar feed, as Google serves one
            return self.send(200, "BEGIN:VCALENDAR\r\nX-WR-CALNAME:Stand-in Calendar\r\nBEGIN:VEVENT\r\nUID:a@x\r\nDTSTART:%sT170000Z\r\n"
                "DTEND:%sT180000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Stand-in practice\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" % ((today.strftime("%Y%m%d"),) * 2), "text/calendar")
        if u.path == "/__mock/private.ics":  # a private calendar without its secret address: Google's sign-in page
            return self.send(200, "<html><body>Sign in</body></html>", "text/html")
        if u.path == "/__mock/google":      # Google's "Choose an account", with a personal and a school account
            return self.send(200, "<html><body><h1>Choose an account</h1>"
                "<div data-identifier=\"sam.personal@gmail.com\" onclick=\"location='%sauth/google/callback?as=personal'\">Sam</div>"
                "<div data-identifier=\"sam@school.org\" onclick=\"location='%sauth/google/callback?as=school'\">Sam</div></body></html>" % (B, B), "text/html")
        if u.path == "/__mock/google/signin":   # Google's sign-in, for a browser that isn't signed in to Google: email first
            return self.send(200, "<html><body><h1>Sign in</h1><input type=\"email\" id=\"identifierId\" name=\"identifier\">"
                "<div id=\"identifierNext\"><button type=\"button\" onclick=\"location='/__mock/google/pwd?email='+encodeURIComponent("
                "document.getElementById('identifierId').value)\">Next</button></div></body></html>", "text/html")
        if u.path == "/__mock/google/pwd":      # then the password
            e = urllib.parse.quote(q.get("email", ""))
            return self.send(200, "<html><body><h1>Welcome</h1>%s<input type=\"password\" name=\"Passwd\" id=\"pw\">"
                "<div id=\"passwordNext\"><button type=\"button\" onclick=\"location='/__mock/google/check?email=%s&p='+encodeURIComponent("
                "document.getElementById('pw').value)\">Next</button></div></body></html>" % ("<p>Wrong password.</p>" if q.get("wrong") else "", e), "text/html")
        if u.path == "/__mock/google/check":
            state["pwtries"] += 1
            if q.get("p") != "correct-horse":
                return self.send(302, "", "text/html", [("Location", "/__mock/google/pwd?wrong=1&email=" + urllib.parse.quote(q.get("email", "")))])
            state.update(out=False, pwflow=False, typed=q.get("email", ""))
            return self.send(302, "", "text/html", [("Location", B + "dashboard")])
        if u.path == B + "auth/google/callback":
            state.update(out=False, chooser=False, picked=q.get("as", ""))
            return self.send(302, "", "text/html", [("Location", B + "dashboard")])   # like TeachMore: its home page (the calendar)
        if u.path == B + "auth/google":      # Sign in with Google: straight back in, unless Google wants you to pick an account
            state["auth"] += 1
            if state["chooser"]: return self.send(302, "", "text/html", [("Location", "/__mock/google")])
            if state["pwflow"]: return self.send(302, "", "text/html", [("Location", "/__mock/google/signin")])
            state["out"] = False
            return self.send(302, "", "text/html", [("Location", B + "dashboard")])
        if u.path == B + "login":
            return self.send(200, "<html><body><h1>Log in</h1><form><input type=\"email\"><input type=\"password\" name=\"password\"></form></body></html>", "text/html")
        if u.path == "/login":              # where TeachMore sends you when you're signed out: a 404 page
            return self.send(404, "<html><body><h1>404 Not Found</h1></body></html>", "text/html")
        if state["out"] and u.path.startswith(B):
            return self.send(302, "", "text/html", [("Location", "/login")])
        if u.path in (B + "offerings", B + "dashboard"):
            return self.send(200, PAGE % state["token"], "text/html; charset=UTF-8")
        if u.path == B + "offerings/search":
            state["searches"] += 1
            rows = [o for o in offerings() if not q.get("teacherID") or str(o["teacherID"]) == q["teacherID"]]
            if not q.get("teacherID"): rows = [o for o in rows if o["offeringDate"] < d(14)]   # every teacher's: only two weeks out
            return self.send(200, json.dumps(rows))
        self.send(404, "not found", "text/plain")

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        log("POST %s %s token=%s" % (self.path, body, self.headers.get("X-CSRF-TOKEN")))
        if u.path != B + "appointment/create": return self.send(404, "not found", "text/plain")
        f = dict(urllib.parse.parse_qsl(body, keep_blank_values=True))
        p = dict(f, token=self.headers.get("X-CSRF-TOKEN"), page=urllib.parse.urlparse(self.headers.get("Referer", "")).path, ajax=self.headers.get("X-Requested-With") == "XMLHttpRequest",
                 form=self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"), ok=False)
        state["posts"].append(p)
        if p["token"] != state["token"]:
            p["status"] = 419
            return self.send(419, json.dumps({"message": "CSRF token mismatch."}))
        o = next((o for o in offerings() if str(o["uniqueID"]) == f.get("offeringID")), None)
        p["valid"] = bool(o) and f.get("date") == o["offeringDate"] and f.get("teacherID") == str(o["teacherID"]) \
            and f.get("eventType") == "1" and f.get("comment") == "Offering Signup" and p["ajax"] and p["form"]
        if not o: return self.send(200, json.dumps({"success": False, "message": "Offering not found."}))
        if o["hasAppt"] and o["existingApptType"] == 1: return self.send(200, json.dumps({"success": False, "message": "You have a mandatory appointment that day."}))
        if o["offeringCap"] != "N/A" and o["numberLeft"] is not None and o["numberLeft"] <= 0:
            return self.send(200, json.dumps({"success": False, "message": "This offering is full."}))
        for x in offerings():   # switching: leave the old one that day
            if x["offeringDate"] == o["offeringDate"]: state["enrolled"].discard(str(x["uniqueID"]))
        state["enrolled"].add(str(o["uniqueID"])); state["taken"][str(o["uniqueID"])] = state["taken"].get(str(o["uniqueID"]), 0) + 1
        p["ok"] = True
        self.send(200, json.dumps({"success": True}))

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
