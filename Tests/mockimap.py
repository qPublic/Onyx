#!/usr/bin/env python3
"""A stand-in IMAP server for Onyx's self-test: plain TCP on 127.0.0.1:8766 (this Mac only), one inbox of made-up emails.
Sign in as test@example.com with the password mock-pass. It refuses SELECT, STORE and non-PEEK fetches, and logs every
command to the file given as the first argument, so the test can check Onyx never changes a mailbox."""
import datetime, socketserver, sys, re
from email.message import EmailMessage
from email.utils import format_datetime, formataddr

LOG = sys.argv[1] if len(sys.argv) > 1 else "/dev/null"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8766
now = datetime.datetime.now().astimezone()
def day(n, h=0, m=0): return (now + datetime.timedelta(days=n)).replace(hour=h, minute=m, second=0, microsecond=0)
def spoken(d): return d.strftime("%A, %B ") + str(d.day)          # "Saturday, October 4"

def mail(frm, subject, sent, extra=None):
    m = EmailMessage()
    m["From"] = frm
    m["To"] = "test@example.com"
    m["Subject"] = subject
    m["Date"] = format_datetime(sent)
    m["Message-ID"] = "<%d@mock.example>" % (abs(hash(subject)) % 10**9)
    for k, v in (extra or {}).items(): m[k] = v
    return m

dinner = day(4, 19, 30)
ics_day = day(6, 15, 0)
ics = "\r\n".join([
    "BEGIN:VCALENDAR", "PRODID:-//Mock//EN", "VERSION:2.0", "METHOD:REQUEST",
    "BEGIN:VTIMEZONE", "TZID:America/New_York", "END:VTIMEZONE",
    "BEGIN:VEVENT", "UID:conf-123@school.org",
    "DTSTART;TZID=America/New_York:" + ics_day.strftime("%Y%m%dT150000"),
    "DTEND;TZID=America/New_York:" + ics_day.strftime("%Y%m%dT153000"),
    "SUMMARY:Parent-teacher conference", "LOCATION:Room 204",
    "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR", ""])

m1 = mail(formataddr(("Sam Lee", "sam@example.com")), "Dinner?", now - datetime.timedelta(days=1))
m1.set_content(f"Hey! Want to grab dinner at Luigi's on {spoken(dinner)} at 7:30pm? Let me know.\n\n— Sam\n\n"
               "On Mon, Sep 1, 2025 at 9:00 AM Alex wrote:\n> Lunch on Friday at noon?\n", charset="utf-8", cte="quoted-printable")
m2 = mail(formataddr(("Coach Rivera", "coach@school.org")), "Practice moved", now - datetime.timedelta(hours=2))
m2.set_content("<html><head><style>p{color:red}</style></head><body><p>Hi team,</p><p>Soccer practice is moved to <b>Thursday</b> at "
               "4:00&nbsp;PM on the North Field.</p><p>Coach Rivera</p></body></html>", subtype="html", cte="base64")
m3 = mail("calendar@school.org", "Invitation: Parent-teacher conference", now - datetime.timedelta(hours=5))
m3.set_content("You're invited to a parent-teacher conference.")
m3.add_alternative(ics, subtype="calendar", params={"method": "REQUEST"})
m4 = mail("deals@shop.example", "Fall sale ends Sunday!", now - datetime.timedelta(hours=3), {"List-Unsubscribe": "<https://shop.example/unsub>"})
m4.set_content("Our biggest sale ends this Sunday at midnight. Shop now and save 40%!")
m5 = mail("blocked@spam.example", "Meeting Monday", now - datetime.timedelta(hours=4))
m5.set_content("Let's meet Monday at 10am in the lobby.")
m6 = mail("friend@example.com", "Thanks!", now - datetime.timedelta(hours=6))
m6.set_content("Thanks for the notes from class, they helped a lot.")
m7 = mail(formataddr(("Renée", "renee@example.com")), "Café meetup ☕", now - datetime.timedelta(hours=1))
m7.set_content("Coffee at Café Nero tomorrow at 9 am?", charset="iso-8859-1", cte="quoted-printable")
m8 = mail("team@example.com", "Great game", now - datetime.timedelta(hours=7))
m8.set_content("Great game last Saturday! See you all next season.")
MESSAGES = [(101 + i, m.as_bytes()) for i, m in enumerate([m1, m2, m3, m4, m5, m6, m7, m8])]

def log(line):
    with open(LOG, "a") as f: f.write(line + "\n")

class Handler(socketserver.StreamRequestHandler):
    def send(self, s): self.wfile.write(s if isinstance(s, bytes) else s.encode()); self.wfile.flush()
    def handle(self):
        self.send("* OK [CAPABILITY IMAP4rev1] Mock mail ready\r\n")
        authed = False
        while True:
            line = self.rfile.readline()
            if not line: return
            line = line.decode(errors="replace").rstrip("\r\n")
            tag, _, rest = line.partition(" ")
            cmd = rest.upper()
            log(re.sub(r'(LOGIN "[^"]*") "(?:[^"\\]|\\.)*"', r'\1 "***"', rest))
            if cmd.startswith("CAPABILITY"):
                self.send("* CAPABILITY IMAP4rev1\r\n%s OK done\r\n" % tag)
            elif cmd.startswith("LOGIN"):
                args = re.findall(r'"((?:[^"\\]|\\.)*)"', rest)
                if args == ["test@example.com", "mock-pass"]: authed = True; self.send("%s OK Logged in\r\n" % tag)
                else: self.send("%s NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" % tag)
            elif not authed:
                self.send("%s NO Sign in first\r\n" % tag)
            elif cmd.startswith("EXAMINE"):
                self.send("* %d EXISTS\r\n* OK [UIDVALIDITY 42] ok\r\n* OK [UIDNEXT 109] ok\r\n%s OK [READ-ONLY] EXAMINE done\r\n" % (len(MESSAGES), tag))
            elif cmd.startswith("UID SEARCH"):
                m = re.search(r"UID (\d+):\*", cmd)
                uids = [u for u, _ in MESSAGES]
                if m:
                    lo = int(m.group(1)); uids = [u for u in uids if u >= lo] or [uids[-1]]   # n:* always includes the last one
                self.send("* SEARCH %s\r\n%s OK done\r\n" % (" ".join(map(str, uids)), tag))
            elif cmd.startswith("UID FETCH") and "BODY.PEEK[]" in cmd:
                want = set()
                for part in cmd.split()[2].split(","):
                    a, _, b = part.partition(":"); want.update(range(int(a), int(b or a) + 1))
                lim = int(re.search(r"<0\.(\d+)>", cmd).group(1))
                for i, (u, raw) in enumerate(MESSAGES):
                    if u in want:
                        d = raw[:lim]
                        self.send(b"* %d FETCH (UID %d BODY[]<0> {%d}\r\n" % (i + 1, u, len(d)) + d + b")\r\n")
                self.send("%s OK done\r\n" % tag)
            elif cmd.startswith("LOGOUT"):
                self.send("* BYE bye\r\n%s OK done\r\n" % tag); return
            else:
                log("REFUSED: " + rest)   # SELECT, STORE, EXPUNGE, non-PEEK fetches: never allowed
                self.send("%s NO not allowed in the mock\r\n" % tag)

class Server(socketserver.ThreadingTCPServer): allow_reuse_address = True; daemon_threads = True
Server(("127.0.0.1", PORT), Handler).serve_forever()
