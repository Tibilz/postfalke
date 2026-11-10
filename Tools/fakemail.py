"""Tiny in-memory IMAP + SMTP server for exercising the Swift client (plain TCP)."""
import re, socketserver, sys, threading, base64

# usage: fakemail.py IMAP_PORT SMTP_PORT [PASSWORD] [CARDDAV_PORT]
USER = "tester@example.org"
PASSWORD = sys.argv[3] if len(sys.argv) > 3 else 'p"äss wort'
lock = threading.Lock()
SEEN = "\\Seen"
folders = {"INBOX": [], "Sent": [], "Trash": [], "Entw&APw-rfe": []}
flagsof = {"INBOX": "", "Sent": "\\Sent", "Trash": "\\Trash", "Entw&APw-rfe": "\\Drafts"}
nextuid = {k: 1 for k in folders}

def add(folder, data, flags=()):
    with lock:
        uid = nextuid[folder]; nextuid[folder] += 1
        folders[folder].append({"uid": uid, "flags": set(flags), "data": data})

for i in range(1, 4):
    add("INBOX", (f"From: =?UTF-8?B?SsO8cmdlbg==?= <j{i}@example.org>\r\nTo: {USER}\r\nSubject: Testnachricht {i} (mit Klammer)\r\n"
                  f"Date: Tue, 10 Nov 2026 1{i}:00:00 +0100\r\nMessage-ID: <m{i}@example.org>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nInhalt {i} äöü\r\n").encode())

def tokens(line, literals):
    out, i = [], 0
    for m in re.finditer(rb'"((?:[^"\\]|\\.)*)"|\x00(\d+)\x00|(\([^)]*\))|(\S+)', line):
        if m.group(1) is not None: out.append(re.sub(rb'\\(.)', rb'\1', m.group(1)))
        elif m.group(2) is not None: out.append(literals[int(m.group(2))])
        else: out.append(m.group(3) or m.group(4))
    return out

class IMAP(socketserver.StreamRequestHandler):
    def send(self, s):
        self.wfile.write(s if isinstance(s, bytes) else s.encode()); self.wfile.flush()
    def handle(self):
        self.send("* OK fake IMAP ready\r\n")
        sel, authed = None, False
        while True:
            line = self.rfile.readline()
            if not line: return
            literals = []
            while True:
                m = re.search(rb'\{(\d+)\}\r\n$', line)
                if not m: break
                self.send("+ go ahead\r\n")
                literals.append(self.rfile.read(int(m.group(1))))
                line = line[:m.start()] + b"\x00%d\x00" % (len(literals) - 1) + self.rfile.readline()
            t = tokens(line.strip(), literals)
            if not t: continue
            tag, cmd, args = t[0].decode(), t[1].decode().upper(), t[2:]
            if cmd == "UID": cmd = "UID " + args[0].decode().upper(); args = args[1:]
            ok = lambda extra="": self.send(f"{tag} OK {extra}done\r\n")
            if cmd == "CAPABILITY":
                self.send("* CAPABILITY IMAP4rev1 MOVE UIDPLUS SPECIAL-USE\r\n"); ok()
            elif cmd == "LOGIN":
                if args[0].decode() == USER and args[1].decode() == PASSWORD: authed = True; ok()
                else: self.send(f"{tag} NO [AUTHENTICATIONFAILED] wrong credentials\r\n")
            elif cmd == "LOGOUT":
                self.send("* BYE bye\r\n"); ok(); return
            elif not authed:
                self.send(f"{tag} BAD login first\r\n")
            elif cmd == "LIST":
                for f in folders: self.send(f'* LIST (\\HasNoChildren {flagsof[f]}) "/" "{f}"\r\n')
                ok()
            elif cmd == "STATUS":
                f = folders[args[0].decode()]
                unseen = sum(1 for m in f if SEEN not in m["flags"])
                self.send(f'* STATUS "{args[0].decode()}" (MESSAGES {len(f)} UNSEEN {unseen})\r\n'); ok()
            elif cmd == "SELECT":
                sel = args[0].decode()
                if sel not in folders: self.send(f"{tag} NO no such mailbox\r\n"); sel = None; continue
                self.send(f"* {len(folders[sel])} EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 42] ok\r\n* OK [UIDNEXT {nextuid[sel]}] ok\r\n"); ok("[READ-WRITE] ")
            elif cmd == "NOOP":
                if sel: self.send(f"* {len(folders[sel])} EXISTS\r\n")
                ok()
            elif cmd in ("FETCH", "UID FETCH"):
                msgs = folders[sel]; chosen = []
                for part in args[0].decode().split(","):
                    a, _, b = part.partition(":"); a = int(a); b = int(b) if b else a
                    for n, m in enumerate(msgs, 1):
                        key = m["uid"] if cmd.startswith("UID") else n
                        if a <= key <= b: chosen.append((n, m))
                full = b"BODY.PEEK[]" in line
                for n, m in chosen:
                    fl = " ".join(sorted(m["flags"]))
                    if full:
                        self.send(f"* {n} FETCH (UID {m['uid']} BODY[] {{{len(m['data'])}}}\r\n".encode() + m["data"] + b")\r\n")
                    else:
                        hdr = m["data"].split(b"\r\n\r\n")[0] + b"\r\n\r\n"
                        self.send(f'* {n} FETCH (UID {m["uid"]} FLAGS ({fl}) INTERNALDATE "10-Nov-2026 12:00:00 +0100" RFC822.SIZE {len(m["data"])} BODY[HEADER.FIELDS (FROM TO CC)] {{{len(hdr)}}}\r\n'.encode() + hdr + b")\r\n")
                ok()
            elif cmd == "UID STORE":
                uids = {int(u) for u in args[0].decode().split(",")}; fl = set(args[2].decode().strip("()").split())
                for m in folders[sel]:
                    if m["uid"] in uids: m["flags"] = (m["flags"] | fl) if args[1].startswith(b"+") else (m["flags"] - fl)
                ok()
            elif cmd == "UID MOVE":
                uids = {int(u) for u in args[0].decode().split(",")}
                for m in [m for m in folders[sel] if m["uid"] in uids]:
                    folders[sel].remove(m); add(args[1].decode(), m["data"], m["flags"])
                ok()
            elif cmd in ("UID EXPUNGE", "EXPUNGE"):
                folders[sel][:] = [m for m in folders[sel] if "\\Deleted" not in m["flags"]]; ok()
            elif cmd == "APPEND":
                add(args[0].decode(), args[-1], set(args[1].decode().strip("()").split())); ok("[APPENDUID 42 1] ")
            elif cmd == "UID SEARCH":
                q = args[-1]
                self.send("* SEARCH " + " ".join(str(m["uid"]) for m in folders[sel] if q.lower() in m["data"].lower()) + "\r\n"); ok()
            else:
                self.send(f"{tag} BAD unknown command {cmd}\r\n")

class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        w = lambda s: (self.wfile.write(s.encode()), self.wfile.flush())
        w("220 fake ESMTP\r\n"); authed = False; rcpts = []
        while True:
            line = self.rfile.readline().decode().strip()
            if not line: return
            up = line.upper()
            if up.startswith("EHLO"): w("250-fake\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n")
            elif up.startswith("AUTH PLAIN"):
                parts = base64.b64decode(line.split()[2]).decode().split("\0")
                authed = parts[1:] == [USER, PASSWORD]
                w("235 ok\r\n" if authed else "535 bad credentials\r\n")
            elif not authed: w("530 auth required\r\n")
            elif up.startswith("MAIL FROM"): rcpts = []; w("250 ok\r\n")
            elif up.startswith("RCPT TO"): rcpts.append(line); w("250 ok\r\n")
            elif up == "DATA":
                w("354 go\r\n"); data = b""
                while True:
                    l = self.rfile.readline()
                    if l == b".\r\n": break
                    data += l[1:] if l.startswith(b".") else l
                add("INBOX", data); w("250 queued\r\n")
            elif up == "QUIT": w("221 bye\r\n"); return
            else: w("500 what\r\n")

# ---- optional CardDAV endpoint (4th argument = port) -------------------------------------------
import http.server
cards = {}
MULTI = '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">%s</d:multistatus>'
def resp(href, props):
    return f"<d:response><d:href>{href}</d:href><d:propstat><d:prop>{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"

class DAV(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b"", ctype="application/xml; charset=utf-8", extra=()):
        if isinstance(body, str): body = body.encode()
        self.send_response(code)
        for k, v in extra: self.send_header(k, v)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def authed(self):
        want = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        if self.headers.get("Authorization") == want: return True
        self.reply(401, extra=[("WWW-Authenticate", 'Basic realm="dav"')]); return False
    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))
    def do_PUT(self):
        data = self.body()
        if self.authed(): cards[self.path] = data.decode(); self.reply(201)
    def do_PROPFIND(self):
        self.body()
        if not self.authed(): return
        p = self.path
        if p == "/.well-known/carddav": return self.reply(301, extra=[("Location", "/dav/")])
        if p == "/dav/": return self.reply(207, MULTI % resp(p, "<d:resourcetype><d:collection/></d:resourcetype><d:current-user-principal><d:href>/dav/principals/tester/</d:href></d:current-user-principal>"))
        if p == "/dav/principals/tester/": return self.reply(207, MULTI % resp(p, "<card:addressbook-home-set><d:href>/dav/addressbooks/tester/</d:href></card:addressbook-home-set>"))
        if p == "/dav/addressbooks/tester/":
            return self.reply(207, MULTI % (resp(p, "<d:resourcetype><d:collection/></d:resourcetype>")
                + resp(p + "contacts/", "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>")
                + resp(p + "kalender/", "<d:resourcetype><d:collection/></d:resourcetype>")))
        if p == "/dav/addressbooks/tester/contacts/": return self.reply(207, MULTI % resp(p, "<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>"))
        self.reply(404)
    def do_REPORT(self):
        self.body()
        if not self.authed(): return
        from xml.sax.saxutils import escape
        items = "".join(resp(path, f'<d:getetag>"1"</d:getetag><card:address-data>{escape(card)}</card:address-data>')
                        for path, card in cards.items() if path.startswith(self.path))
        self.reply(207, MULTI % items)

if len(sys.argv) > 4:
    dav = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[4])), DAV)
    threading.Thread(target=dav.serve_forever, daemon=True).start()

socketserver.ThreadingTCPServer.allow_reuse_address = True
imap = socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[1])), IMAP)
smtp = socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[2])), SMTP)
threading.Thread(target=smtp.serve_forever, daemon=True).start()
print("ready", flush=True)
imap.serve_forever()
