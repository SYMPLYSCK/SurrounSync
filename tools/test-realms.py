"""Realms client in the bridge (bridge/Realms.cs) end to end against a local Realms server.

Starts realms-backend with `wrangler dev --local` (fresh database, 3 s leases) and two bridges on the test
network, then drives them through their command files the way the mod does and reads mirror_realms.txt.
    python -I tools/test-realms.py        (build the bridge first: tools/build-bridge.ps1 [-Out <dir>])
    python -I tools/test-realms.py --exe <path to SurrounSyncBridge.exe>
"""
import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, "realms-backend")
EXE = os.environ.get("SURROUNSYNC_BRIDGE") or os.path.join(REPO, "mod", "SurrounSync", "bridge", "SurrounSyncBridge.exe")


def free_port():
    # a port the OS lets us listen on: Windows (Hyper-V/WinNAT) reserves ranges that move at boot, and a fixed
    # port can also be held by another wrangler
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# REALMS_TEST_PORT: a fixed port for the local Realms server (default: any free one)
PORT_API, PORT_NET = int(os.environ.get("REALMS_TEST_PORT") or free_port()), free_port()
URL = "http://127.0.0.1:%d" % PORT_API
MOTD_TOKEN = "test-motd-token-0123456789abcdefghijklmnop"
failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def wait_for(fn, secs=15.0):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    return None


class B:
    """One bridge with its own folder, driven like the mod drives it."""
    seq = 0

    def __init__(self, name, test_id, extra=None):
        self.name, self.test_id, self.extra = name, test_id, extra or []
        self.dir = tempfile.mkdtemp(prefix="realms_%s_" % name)
        self.proc = None

    def start(self):
        args = [EXE, "--role", "auto", "--dir", self.dir, "--test-net", str(PORT_NET), "--no-game-check",
                "--test-id", str(self.test_id), "--realms-url", URL, "--motd-every", "1"] + self.extra
        if os.path.exists(os.path.join(self.dir, "mirror_realms.txt")):
            os.remove(os.path.join(self.dir, "mirror_realms.txt"))
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        check(wait_for(lambda: os.path.exists(os.path.join(self.dir, "mirror_realms.txt"))) is not None,
              "%s: bridge writes mirror_realms.txt" % self.name)

    def stop(self):
        if self.proc:
            self.proc.kill()
            self.proc.wait()
            self.proc = None

    def realm_dir(self, rid):
        return os.path.join(self.dir, "Saved", "SurrounSyncRealms", rid)

    def state(self):
        try:
            with open(os.path.join(self.dir, "mirror_realms.txt"), encoding="utf-8") as f:
                s = f.read()
        except OSError:
            return None
        return s if s.endswith("END\n") else None

    def cmd(self, text, secs=30.0):
        B.seq += 1
        n = B.seq
        path = os.path.join(self.dir, "mirror_bridge_cmd.txt")
        wait_for(lambda: not os.path.exists(path), 5)
        with open(path, "w", encoding="utf-8") as f:
            f.write("realm %d %s" % (n, text))

        def answer():
            s = self.state() or ""
            for line in s.splitlines():
                p = line.split(" ", 3)
                if p[0] == "op" and p[1] == str(n):
                    return p[3]
            return None
        r = wait_for(answer, secs)
        return r or "timeout"

    def lines(self, kind):
        return [l.split(" ")[1:] for l in (self.state() or "").splitlines() if l.startswith(kind + " ")]


def http(method, path, auth=None, headers=None, raw=None):
    h = dict(headers or {})
    if auth:
        h["authorization"] = "Member " + auth
    if raw is not None:
        h["content-type"] = "application/octet-stream"
    req = urllib.request.Request(URL + "/v1" + path, data=raw, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def start_backend():
    state = os.path.join(BACKEND, ".wrangler", "test-state")
    shutil.rmtree(state, ignore_errors=True)
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    r = subprocess.run([npx, "wrangler", "d1", "execute", "surrounsync-realms", "--local", "--persist-to",
                        ".wrangler/test-state", "--file", "schema.sql"], cwd=BACKEND, capture_output=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        # (ascii: wrangler prints box and emoji characters, and a redirected Windows console is cp1252)
        print((r.stdout[-2000:] + "\n" + r.stderr[-2000:]).encode("ascii", "replace").decode())
        sys.exit("couldn't make the local database")
    # wrangler's own output goes to a file, shown when the server doesn't come up
    out_path = os.path.join(tempfile.gettempdir(), "realms_wrangler_%d.log" % os.getpid())
    out = open(out_path, "w", encoding="utf-8", errors="replace")
    # (no --ip 127.0.0.1: with it the local server answered every Realm request with "not a Realm code")
    p = subprocess.Popen([npx, "wrangler", "dev", "--local", "--port", str(PORT_API), "--persist-to",
                          ".wrangler/test-state", "--var", "LEASE_SECONDS:3", "--var", "MOTD_TOKEN:" + MOTD_TOKEN], cwd=BACKEND,
                         stdout=out, stderr=subprocess.STDOUT)

    def up():
        try:
            with urllib.request.urlopen(URL + "/v1", timeout=2) as r:
                return r.status == 200
        except Exception:
            return False
    if not wait_for(up, 60):
        kill_tree(p)
        out.close()
        print(open(out_path, encoding="utf-8", errors="replace").read()[-3000:])
        sys.exit("the local Realms server didn't start")
    return p


def kill_tree(p):
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)


def write_world(folder, files):
    os.makedirs(folder, exist_ok=True)
    for n in os.listdir(folder):
        os.remove(os.path.join(folder, n))
    for n, data in files.items():
        with open(os.path.join(folder, n), "wb") as f:
            f.write(data)


def motd_checks(a):
    """The message of the day: only the admin token sets it, the bridge writes it for the mod."""
    path = os.path.join(a.dir, "mirror_motd.txt")

    def motd_file():
        try:
            with open(path, encoding="utf-8") as f:
                s = f.read()
        except OSError:
            return None
        return s if s.endswith("END\n") else None

    def put(body, token):
        h = {"authorization": "Admin " + token} if token else {}
        return http("PUT", "/motd", headers=h, raw=json.dumps(body).encode())

    st, body = http("GET", "/motd")
    check(st == 200 and json.loads(body).get("id") is None, "motd: none at first: %d %s" % (st, body[:80]))
    check(wait_for(lambda: motd_file() == "motd none\nEND\n", 10) is not None, "motd: the bridge writes 'motd none': %r" % motd_file())
    st, body = put({"text": "hello"}, None)
    check(st == 403 and b"not_admin" in body, "motd: PUT without the token refused: %d %s" % (st, body[:80]))
    st, body = put({"text": "hello"}, MOTD_TOKEN + "x")
    check(st == 403 and b"not_admin" in body, "motd: PUT with a wrong token refused: %d %s" % (st, body[:80]))
    st, body = http("DELETE", "/motd", headers={"authorization": "Member AAAAAAAA:" + MOTD_TOKEN})
    check(st == 403, "motd: DELETE with a member header refused: %d" % st)
    st, body = put({"text": "x" * 501}, MOTD_TOKEN)
    check(st == 400 and b"bad_input" in body, "motd: 501 characters refused: %d %s" % (st, body[:80]))
    st, body = put({"text": "line\nbreak"}, MOTD_TOKEN)
    check(st == 400, "motd: control characters refused: %d" % st)
    st, body = put({"text": "hi", "hours": 0}, MOTD_TOKEN)
    check(st == 400, "motd: hours 0 refused: %d" % st)
    st, body = put({"text": "hi", "minutes": 0}, MOTD_TOKEN)
    check(st == 400, "motd: minutes 0 refused: %d" % st)
    st, body = put({"text": "hi", "minutes": 90 * 24 * 60 + 1}, MOTD_TOKEN)
    check(st == 400, "motd: more than 90 days of minutes refused: %d" % st)
    st, body = put({"text": "hi", "minutes": 5, "hours": 1}, MOTD_TOKEN)
    check(st == 400 and b"not both" in body, "motd: hours and minutes together refused: %d %s" % (st, body[:80]))
    st, body = http("GET", "/motd")
    check(json.loads(body).get("id") is None, "motd: still none after the refusals")

    text = "Servers down tonight, café open - see you at 9!"
    st, body = put({"text": text}, MOTD_TOKEN)
    m = json.loads(body) if st == 200 else {}
    check(st == 200 and len(m.get("id") or "") == 8 and m.get("expires_at") == 0, "motd: the admin sets one: %d %s" % (st, body[:120]))
    want = "motd %s 0 %s\nEND\n" % (m.get("id"), text)
    check(wait_for(lambda: motd_file() == want, 10) is not None, "motd: the bridge writes it (UTF-8 kept): %r" % motd_file())

    st, body = put({"text": "Weekend event", "hours": 2}, MOTD_TOKEN)
    m2 = json.loads(body) if st == 200 else {}
    check(st == 200 and m2.get("id") != m.get("id") and m2.get("expires_at", 0) > time.time() + 7000,
          "motd: a new one replaces it with its own id and an expiry: %s" % body[:120])
    check(wait_for(lambda: (motd_file() or "").startswith("motd %s %d Weekend event\n" % (m2.get("id"), m2.get("expires_at", 0))), 10)
          is not None, "motd: the bridge writes the new one: %r" % motd_file())
    st, body = put({"text": "Back in 5", "minutes": 5}, MOTD_TOKEN)
    m3 = json.loads(body) if st == 200 else {}
    check(st == 200 and 290 <= m3.get("expires_at", 0) - m3.get("created_at", 0) <= 310,
          "motd: minutes set a short expiry (5 min): %s" % body[:120])
    st, body = http("DELETE", "/motd", headers={"authorization": "Admin " + MOTD_TOKEN})
    check(st == 200, "motd: the admin clears it: %d" % st)
    check(wait_for(lambda: motd_file() == "motd none\nEND\n", 10) is not None, "motd: the bridge writes 'motd none' again: %r" % motd_file())


def hosting_guard_checks(c, d):
    # 0.14.2 report 2026-10-31: a host left the Realm and it stayed "hosted" - the bridge heartbeats a held lease for
    # as long as it runs. Now the game confirms hosting; a lease it stopped confirming isn't heartbeated any more.
    c.start(); d.start()
    r = c.cmd("create Guard World")
    rid = r.split(" ")[1] if r.startswith("ok ") else "0000000000"
    code = (c.cmd("invite " + rid).split(" ") + ["X", "X"])[1]
    check(d.cmd("redeem " + code).startswith("ok " + rid), "(setup) D joins C's Realm")
    check(c.cmd("claim " + rid) == "ok won 0", "(setup) C hosts")
    check(c.cmd("hosting " + rid) == "ok", "the game's hosting confirmation is answered at once")
    check(c.cmd("hosting not-an-id").startswith("fail bad_input"), "...a bad id is refused")
    for _ in range(4):
        time.sleep(1.0)
        c.cmd("hosting " + rid)
    r = d.cmd("claim " + rid)
    check(r.startswith("ok hosted"), "a confirmed host keeps the Realm past the 3 s lease: " + r)
    # the game stops confirming (hung, or left without a release)
    time.sleep(7)
    r = d.cmd("claim " + rid)
    check(r == "ok won 0", "unconfirmed: C's bridge stopped heartbeating and D can host: " + r)
    check("no more heartbeats" in tb_log(c), "C's bridge logged why")
    # D never confirms (an older mod): its bridge heartbeats as before
    time.sleep(5)
    r = c.cmd("claim " + rid)
    check(r.startswith("ok hosted"), "a host that never confirmed keeps its lease as before: " + r)
    d.cmd("release " + rid)


def server_list_checks(c, d, g):
    # user 2026-11-01: "realms server list ... Name|Players0/0|Ping|Locked/Unlocked -Join" + public Realms.
    # C and D are still running from hosting_guard_checks (C: fast heartbeats, needs the game's hosting confirms)
    g.start()
    r = c.cmd("create Public World")
    rid = r.split(" ")[1] if r.startswith("ok ") else "0000000000"

    def rows(x):
        x.cmd("browse")
        return [l for l in x.lines("server") if l[0] == rid]

    def keep(secs):
        end = time.time() + secs
        while time.time() < end:
            c.cmd("hosting " + rid)
            time.sleep(0.8)

    check(rows(d) == [], "a new Realm isn't on the server list")
    check(d.cmd("joinpublic " + rid).startswith("fail no_realm"), "a private Realm can't be joined from the list")
    check(c.cmd("public %s maybe" % rid).startswith("fail bad_input"), "public needs on or off")
    r = c.cmd("public %s on" % rid)
    check(r == "ok on open" and [rid, "1", "0", "invited"] in c.lines("pub"), "the owner lists it, open: %s %s" % (r, c.lines("pub")))
    check(c.cmd("claim " + rid) == "ok won 0", "(setup) C hosts the public Realm")

    def numbers():
        st, body = http("GET", "/realms/public")
        x = [s for s in json.loads(body).get("realms", []) if s.get("realm_id") == rid] if st == 200 else []
        return x[0] if x and x[0].get("live") and x[0].get("players", 0) >= 1 and (x[0].get("ping_loc") or "").startswith("test=") else None
    got = None
    end = time.time() + 8
    while got is None and time.time() < end:
        keep(1)
        got = numbers()
    check(got is not None and got["max_players"] >= got["players"], "the host's heartbeat carries players, max and its ping location: %s" % got)
    keep(0.1)
    row = rows(d)
    check(len(row) == 1 and row[0][1:3] == ["1", "0"] and row[0][5] == "40" and row[0][6] == "0"
          and " ".join(row[0][7:]) == "Public World" and row[0][3] == str((got or {}).get("players")),
          "D's list: live, open, players, ping from the test net (40 ms), not mine, name last: %s" % row)
    hd = d.lines("servers")
    check(len(hd) == 1 and int(hd[0][0]) > 0 and int(hd[0][1]) == len(d.lines("server")),
          "one servers header: browse time and the row count: %s" % hd)

    r = d.cmd("joinpublic " + rid)
    check(r.startswith("ok " + rid) and os.path.exists(os.path.join(d.realm_dir(rid), "member.key")), "D joins from the list: " + r)
    d.cmd("list")
    check([rid, "1", "0", "public"] in d.lines("pub"), "D's pub line: listed, open, joined from the list: %s" % d.lines("pub"))
    check(d.cmd("joinpublic " + rid).startswith("ok " + rid), "JOIN again with a key: no second request")
    keep(0.1)
    row = rows(d)
    check(len(row) == 1 and row[0][6] == "1", "D's list marks it mine now: %s" % row)
    keep(0.1)
    r = d.cmd("claim " + rid)
    check(r.startswith("ok hosted"), "a list member finds C hosting (the game then joins it): " + r)

    # locked: the password may hold spaces; it reaches only the server
    pw = "secret pass"
    check(c.cmd("public %s on %s" % (rid, pw)) == "ok on locked", "the owner locks it with a password")
    keep(0.1)
    row = rows(g)
    check(len(row) == 1 and row[0][2] == "1", "G's list shows it locked: %s" % row)
    check(g.cmd("joinpublic " + rid).startswith("fail bad_password"), "no password: refused")
    check(g.cmd("joinpublic %s wrong one" % rid).startswith("fail bad_password"), "a wrong password: refused")
    check(not os.path.exists(os.path.join(g.realm_dir(rid), "member.key")), "...and no key saved")
    r = g.cmd("joinpublic %s %s" % (rid, pw))
    check(r.startswith("ok " + rid), "the right password: G joins: " + r)
    d.cmd("list")
    check(not any(l[0] == rid and l[1] != "offline" for l in d.lines("realm")), "locking removed D, who joined while it was open: %s" % d.lines("realm"))

    # a dead key (removed by the lock, or by a list join made with D's Steam id) must not answer JOIN: D joins afresh
    def key_of(x):
        return open(os.path.join(x.realm_dir(rid), "member.key"), encoding="utf-8").read().strip()

    def key_works(x):
        return http("GET", "/realms/" + rid, auth=key_of(x))[0] == 200
    dead = key_of(d)
    r = d.cmd("joinpublic %s %s" % (rid, pw))
    check(r.startswith("ok " + rid) and key_of(d) != dead and key_works(d), "D's dead key: JOIN makes a new working one: " + r)
    st = json.loads(http("GET", "/realms/" + rid, auth=key_of(c))[1])
    d_steam = next((x["steam_id"] for x in st.get("members", []) if x["member_id"] == key_of(d).split(":")[0]), None)
    req = urllib.request.Request(URL + "/v1/realms/%s/join" % rid, method="POST", headers={"content-type": "application/json"},
                                 data=json.dumps({"steam_id": d_steam, "player_name": "Fake", "password": pw}).encode())
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
    check(code == 201 and not key_works(d), "a list join made with D's Steam id replaces D's membership (%s)" % code)
    r = d.cmd("joinpublic %s %s" % (rid, pw))
    check(r.startswith("ok " + rid) and key_works(d), "...and D's next JOIN gets back in at once: " + r)
    files = [tb_log(x) + (x.state() or "") for x in (c, g)]
    for x in (c, g):
        for root, _, names in os.walk(x.dir):
            for n in names:
                try:
                    files.append(open(os.path.join(root, n), encoding="utf-8", errors="replace").read())
                except OSError:
                    pass
    check(not any(pw in f for f in files), "the password is in no file or log the bridges write")

    check(c.cmd("public %s off" % rid) == "ok off", "the owner takes it off the list")
    check(rows(d) == [], "...and it's gone from the list")
    c.cmd("release " + rid)
    g.stop()


def raw_cmd(x, text):
    """A plain bridge command (the CO-OP tab's), not a Realm one."""
    path = os.path.join(x.dir, "mirror_bridge_cmd.txt")
    wait_for(lambda: not os.path.exists(path), 5)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    wait_for(lambda: not os.path.exists(path), 5)


def presence_checks(e):
    # user 2026-11-01: "only coop worlds show up in coop, and realms only show up in realms" - a Realm host set the
    # same Steam presence ("host") as a co-op host, and friends' CO-OP tabs list every "host"
    e.start()
    raw_cmd(e, "host")
    time.sleep(3)
    check("presence: hosting a Realm" not in tb_log(e), "a co-op host without a Realm stays a co-op game")
    r = e.cmd("create Presence World")
    rid = r.split(" ")[1] if r.startswith("ok ") else "0000000000"
    check(e.cmd("claim " + rid) == "ok won 0", "(setup) E hosts its Realm")
    check(wait_for(lambda: "presence: hosting a Realm - not listed as a co-op game" in tb_log(e), 6) is not None,
          "hosting a Realm: the bridge stops saying it hosts a co-op game")
    check(e.cmd("release " + rid) == "ok", "(setup) E ends its Realm")
    check(wait_for(lambda: tb_log(e).rstrip().endswith("presence: host") or "presence: host\n" in tb_log(e), 6) is not None,
          "the Realm ended, still hosting: a co-op game again")
    raw_cmd(e, "stop")
    e.stop()


def tb_log(x):
    try:
        with open(os.path.join(x.dir, "mirror_bridge.log"), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main():
    global EXE
    if "--exe" in sys.argv:
        EXE = sys.argv[sys.argv.index("--exe") + 1]
    if not os.path.exists(EXE):
        sys.exit("build the bridge first: tools\\build-bridge.ps1")
    server = start_backend()
    a, b = B("A", 1002), B("B", 1003)
    # (1 s heartbeats against the server's 3 s leases; a lease the game stopped confirming goes after 2.5 s)
    fast = ["--realm-beat", "1000", "--hosting-stale", os.environ.get("REALMS_TEST_STALE_MS", "2500")]
    c, d = B("C", 1004, fast), B("D", 1005, fast)
    e = B("E", 1006)
    g = B("G", 1007)
    try:
        # an id can itself start with R (1 in 32): read as an id, not as a code losing its R (CI 2026-10-30: the
        # server turned RWE288BGVE into WE288BGVE and refused every request for that Realm)
        for form in ("RWE288BGVE", "rwe288bgve", "R-RWE28-8BGVE", "RRWE288BGVE", "R-ABCDE-FGHJK"):
            st, body = http("GET", "/realms/" + form)
            check(b"not a Realm code" not in body, "Realm id/code %s is read: %d %s" % (form, st, body[:80]))
        st, body = http("GET", "/realms/WE288BGVE")
        check(st == 400 and b"not a Realm code" in body, "a 9-character id is still refused: %d %s" % (st, body[:80]))
        a.start(); b.start()
        check(a.state().startswith("realms on "), "A: Realms switched on by --realms-url")
        motd_checks(a)

        r = a.cmd("create My Test World")
        check(r.startswith("ok "), "A creates a Realm: " + r)
        rid = r.split(" ")[1] if r.startswith("ok ") else "0000000000"
        check(os.path.exists(os.path.join(a.realm_dir(rid), "member.key")), "A: member key stored in the Realm folder")
        check("member.key" not in (a.state() or "") and ":" not in "".join(l[0] for l in a.lines("op")),
              "A: the key isn't in mirror_realms.txt")

        r = a.cmd("list")
        check(r == "ok 1", "A lists 1 Realm: " + r)
        rl = a.lines("realm")
        check(len(rl) == 1 and rl[0][:5] == [rid, "owner", "-", "0", "1"] and " ".join(rl[0][6:]) == "My Test World",
              "A: realm line id/owner/no host/gen 0/1 member/name: %s" % rl)

        check(a.cmd("download " + rid) == "ok none", "A: nothing to download yet")
        r = a.cmd("claim " + rid)
        check(r == "ok won 0", "A claims the lease: " + r)
        check([rid, "held"] in a.lines("lease"), "A: lease held")

        r = b.cmd("claim " + rid)
        check(r.startswith("fail not_member"), "B (no key) can't claim: " + r)

        r = a.cmd("invite " + rid)
        check(r.startswith("ok ") and len(r.split(" ")[1]) == 19, "A makes an invite: " + r)
        code = r.split(" ")[1] if r.startswith("ok ") else "X"
        r = b.cmd("redeem " + code.lower())
        check(r.startswith("ok " + rid), "B redeems it (any case): " + r)
        r = b.cmd("redeem " + code)
        # a member redeeming again is refused before the used check (audit N19); one-time use by another
        # player is covered in realms-backend/test/test_api.py
        check(r.startswith("fail already_member"), "a second redeem makes no second member: " + r)

        r = b.cmd("claim " + rid)
        check(r.startswith("ok hosted 76561197960266730"), "B finds A hosting (A's SteamID): " + r)

        world = {"Level.sav": b"EMSH" + os.urandom(5000), "General.sav": b"EMSH" + b"g" * 300,
                 "mirror_realm_beds.txt": b"bed 1 2 3\n"}
        write_world(os.path.join(a.realm_dir(rid), "up"), world)
        # the server runs 3 s leases (the take-over below needs one to run out): A renews right before each step
        # that needs it, or a slow run lost it on the way ("lease.token" gone, uploads refused)
        renew = lambda: check(a.cmd("claim " + rid).startswith("ok won"), "A renews its lease")
        renew()
        r = a.cmd("upload %s 1" % rid)
        check(r.startswith("ok 1 "), "A uploads generation 1: " + r)
        r = a.cmd("upload %s 1" % rid)
        check(r.startswith("fail stale"), "the same generation twice is refused: " + r)

        r = b.cmd("download " + rid)
        check(r == "ok 1 3", "B downloads generation 1 (3 files): " + r)
        down = os.path.join(b.realm_dir(rid), "down")
        got = {n: open(os.path.join(down, n), "rb").read() for n in os.listdir(down)}
        check(got == world, "B's files are byte-identical to A's")

        b.cmd("list")
        rl = b.lines("realm")
        check(len(rl) == 1 and rl[0][1] == "member" and rl[0][2] == "76561197960266730" and rl[0][3] == "1" and rl[0][4] == "2",
              "B: realm line member/host A/gen 1/2 members: %s" % rl)
        ml = b.lines("member")
        check(len(ml) == 2 and all(m[0] == rid for m in ml) and sorted(m[1] for m in ml) == ["member", "owner"]
              and any(m[2] == "76561197960266730" for m in ml if m[1] == "owner") and all(len(m) >= 5 for m in ml),
              "B: one member line per member (owner A with its steam id, names last): %s" % ml)

        write_world(os.path.join(a.realm_dir(rid), "up"), {"bad name.sav": b"x"})
        renew()
        r = a.cmd("upload %s 2" % rid)
        check(r.startswith("fail bad_input"), "a file name with a space isn't uploaded: " + r)

        # a hostile world on the server: an entry that climbs out of the folder
        key = open(os.path.join(a.realm_dir(rid), "member.key")).read().strip()
        renew()
        token = open(os.path.join(a.realm_dir(rid), "lease.token")).read().strip()
        z = io.BytesIO()
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("../evil.txt", "x")
        data = z.getvalue()
        st, _ = http("PUT", "/realms/%s/world/2" % rid, key, {"x-lease-token": token,
                     "x-sha256": hashlib.sha256(data).hexdigest()}, data)
        check(st == 201, "test setup: hostile generation 2 uploaded (%d)" % st)
        r = b.cmd("download " + rid)
        check(r.startswith("fail bad_world"), "B refuses a world with a path in a file name: " + r)
        check(not os.path.exists(os.path.join(b.realm_dir(rid), "evil.txt")), "nothing was written outside the folder")

        # A's game is gone (no heartbeat): after the 3 s lease B can take over
        time.sleep(4)
        r = b.cmd("claim " + rid)
        check(r == "ok won 2", "B takes over after A's lease ran out: " + r)
        write_world(os.path.join(a.realm_dir(rid), "up"), world)
        r = a.cmd("upload %s 3" % rid)
        check(r.startswith("fail lease_lost"), "A can't upload any more: " + r)
        check([rid, "lost"] in a.lines("lease"), "A: lease marked lost")

        # B's bridge restarts while B hosts: resume picks the lease up again
        b.stop(); b.start()
        check([rid, "held"] not in b.lines("lease"), "B: a restarted bridge doesn't heartbeat on its own")
        r = b.cmd("resume " + rid)
        check(r == "ok", "B resumes its lease: " + r)
        check([rid, "held"] in b.lines("lease"), "B: lease held again")
        write_world(os.path.join(b.realm_dir(rid), "up"), world)
        r = b.cmd("upload %s 3" % rid)
        check(r.startswith("ok 3 "), "B uploads generation 3: " + r)
        r = b.cmd("release " + rid)
        check(r == "ok" and not os.path.exists(os.path.join(b.realm_dir(rid), "lease.token")), "B releases the lease")
        r = a.cmd("claim " + rid)
        check(r == "ok won 3", "A can host again at once, newest world 3: " + r)

        r = b.cmd("rename %s Other" % rid)
        check(r.startswith("fail owner_only"), "a member can't rename: " + r)
        r = a.cmd("rename %s Renamed World" % rid)
        check(r == "ok", "the owner renames: " + r)
        # user 2026-10-30 'owner rules': only the owner sets the Realm's rules; members get them with the list,
        # the host with its heartbeat
        check(not any(l[0] == rid for l in a.lines("rules")), "A: no rules line while the server has none")
        r = b.cmd("rules %s pvp on" % rid)
        check(r.startswith("fail owner_only"), "a member can't set the rules: " + r)
        r = a.cmd("rules %s PVP on" % rid)
        check(r.startswith("fail bad_input"), "the bridge refuses malformed rules: " + r)
        r = a.cmd("rules %s pvp on debugmenu off" % rid)
        check(r == "ok" and [rid, "pvp", "on", "debugmenu", "off"] in a.lines("rules"), "the owner sets the rules: %s %s" % (r, a.lines("rules")))
        akey_now = open(os.path.join(a.realm_dir(rid), "member.key")).read().strip()
        for bad in (b'{"rules":"pvp"}', b'{"rules":"pvp on; drop"}', b'{"rules":7}', b'{}'):
            st, body = http("PUT", "/realms/%s/rules" % rid, akey_now, raw=bad)
            check(st == 400 and b"bad_input" in body, "the server refuses rules %s: %d %s" % (bad, st, body[:60]))
        b.cmd("list")
        check([rid, "pvp", "on", "debugmenu", "off"] in b.lines("rules"), "a member gets the owner's rules with the list: %s" % b.lines("rules"))
        st, body = http("PUT", "/realms/%s/rules" % rid, akey_now, raw=b'{"rules":"pvp off players 2"}')
        check(st == 200, "test setup: the owner's rules changed on the server (%d)" % st)
        renew()
        token = open(os.path.join(a.realm_dir(rid), "lease.token")).read().strip()
        st, body = http("POST", "/realms/%s/lease/heartbeat" % rid, akey_now, {"x-lease-token": token})
        check(st == 200 and json.loads(body).get("rules") == "pvp off players 2", "the heartbeat answer carries the rules: %d %s" % (st, body[:80]))
        r = a.cmd("resume " + rid)
        check(r == "ok" and [rid, "pvp", "off", "players", "2"] in a.lines("rules"),
              "the host's bridge takes the new rules from its heartbeat, no list needed: %s %s" % (r, a.lines("rules")))

        r = b.cmd("rekey " + rid)
        check(r == "ok", "B gets a new key: " + r)
        st, _ = http("GET", "/realms/" + rid, open(os.path.join(a.realm_dir(rid), "member.key")).read().strip())
        check(st == 200, "A's key still works")

        # USE A KEY (new PC / reinstall): checked with the server before it is saved
        bkey_path = os.path.join(b.realm_dir(rid), "member.key")
        bkey = open(bkey_path).read().strip()
        mid, key = bkey.split(":")
        os.remove(bkey_path)
        r = b.cmd("usekey SSRK1.%s.%s.%sX" % (rid, mid, key[:-1]))
        check(r.startswith("fail") and not os.path.exists(bkey_path), "a wrong key is refused and nothing saved: " + r)
        r = b.cmd("usekey nonsense")
        check(r.startswith("fail bad_input"), "not a key: " + r)
        r = b.cmd("usekey  SSRK1.%s.%s.%s \n" % (rid, mid, key))
        check(r.startswith("ok " + rid) and open(bkey_path).read().strip() == bkey, "the right key is restored: " + r)
        check(bkey not in (b.state() or "") and key not in (b.state() or ""), "the key never shows in mirror_realms.txt")
        r = b.cmd("copykey not-an-id")
        check(r.startswith("fail bad_input"), "copykey needs a Realm id: " + r)
        r = b.cmd("copykey XXXXXXXXXX")
        check(r.startswith("fail not_member"), "copykey only for my Realms: " + r)

        # a key the server refuses (a server mistake - 2026-10-30 ids starting with R - or the Realm gone): kept and
        # shown offline; forgotten only after refusals over days, and then moved aside, never deleted
        gone = "ZZZZZZZZZZ"
        gdir = b.realm_dir(gone)
        os.makedirs(gdir, exist_ok=True)
        gkey = os.path.join(gdir, "member.key")
        with open(gkey, "w") as f:
            f.write("ABCDEFGH:" + "A" * 43 + "\n")
        b.cmd("list")
        check(os.path.exists(gkey) and any(l[0] == gone and l[1] == "offline" for l in b.lines("realm")),
              "a refused key is kept, its Realm shown offline: %s" % b.lines("realm"))
        refused = os.path.join(gdir, "refused.txt")
        check(os.path.exists(refused) and open(refused).read().split()[1] == "1", "...one refusal counted")
        with open(refused, "w") as f:
            f.write("%d 4\n" % (time.time() - 4 * 86400))
        b.cmd("list")
        check(not os.path.exists(gkey) and os.path.exists(gkey + ".forgotten"),
              "refused 5 times over 4 days: the key is moved aside, not deleted")
        ok_refused = os.path.join(b.realm_dir(rid), "refused.txt")
        with open(ok_refused, "w") as f:
            f.write("%d 3\n" % (time.time() - 86400))
        b.cmd("list")
        check(not os.path.exists(ok_refused) and os.path.exists(bkey_path), "the server knows the key again: the count is cleared")

        r = b.cmd("leave " + rid)
        check(r == "ok" and not os.path.exists(os.path.join(b.realm_dir(rid), "member.key")), "B leaves; its key is gone")
        check(os.path.exists(os.path.join(b.realm_dir(rid), "member.key.forgotten")), "...moved aside, not deleted")
        b.cmd("list")
        check(b.lines("realm") == [], "B lists no Realms")
        # 2026-10-30 17:46: LEAVE of a Realm the server no longer has me in failed with not_member and it stayed listed
        bkey_back = os.path.join(b.realm_dir(rid), "member.key")
        shutil.copyfile(bkey_back + ".forgotten", bkey_back)
        b.cmd("list")
        r = b.cmd("leave " + rid)
        check(r == "ok" and not os.path.exists(bkey_back) and os.path.exists(bkey_back + ".forgotten"),
              "LEAVE of a Realm the server says I'm not in: forgotten here, key moved aside: " + r)
        b.cmd("list")
        check(b.lines("realm") == [], "...and no longer listed")
        r = a.cmd("leave " + rid)
        check(r.startswith("fail owner_must_transfer"), "the owner can't just leave: " + r)
        r = a.cmd("bogus " + rid)
        check(r.startswith("fail bad_command"), "unknown verb answered: " + r)
        r = a.cmd("claim not-an-id")
        check(r.startswith("fail bad_input"), "bad id refused: " + r)
        r = a.cmd("delete " + rid)
        check(r == "ok", "the owner deletes the Realm")
        a.cmd("list")
        check(a.lines("realm") == [], "A lists no Realms")
        akey = os.path.join(a.realm_dir(rid), "member.key")
        shutil.copyfile(akey + ".forgotten", akey)
        r = a.cmd("delete " + rid)
        check(r == "ok" and not os.path.exists(akey), "DELETE of a Realm already gone on the server: forgotten here: " + r)
        a.stop(); b.stop()
        hosting_guard_checks(c, d)
        server_list_checks(c, d, g)
        presence_checks(e)
    finally:
        a.stop(); b.stop(); c.stop(); d.stop(); e.stop(); g.stop()
        kill_tree(server)
        for x in (a, b, c, d, e, g):
            shutil.rmtree(x.dir, ignore_errors=True)
    print("\n%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
