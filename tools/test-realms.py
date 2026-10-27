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
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(REPO, "realms-backend")
EXE = os.path.join(REPO, "mod", "SurrounSync", "bridge", "SurrounSyncBridge.exe")
# REALMS_TEST_PORT: run beside a wrangler that already holds 8787
PORT_API, PORT_NET = int(os.environ.get("REALMS_TEST_PORT", "8787")), 47911
URL = "http://127.0.0.1:%d" % PORT_API
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

    def __init__(self, name, test_id):
        self.name, self.test_id = name, test_id
        self.dir = tempfile.mkdtemp(prefix="realms_%s_" % name)
        self.proc = None

    def start(self):
        args = [EXE, "--role", "auto", "--dir", self.dir, "--test-net", str(PORT_NET), "--no-game-check",
                "--test-id", str(self.test_id), "--realms-url", URL]
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
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit("couldn't make the local database")
    p = subprocess.Popen([npx, "wrangler", "dev", "--local", "--port", str(PORT_API), "--persist-to",
                          ".wrangler/test-state", "--var", "LEASE_SECONDS:3"], cwd=BACKEND,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def up():
        try:
            with urllib.request.urlopen(URL + "/v1", timeout=2) as r:
                return r.status == 200
        except Exception:
            return False
    if not wait_for(up, 60):
        kill_tree(p)
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


def main():
    global EXE
    if "--exe" in sys.argv:
        EXE = sys.argv[sys.argv.index("--exe") + 1]
    if not os.path.exists(EXE):
        sys.exit("build the bridge first: tools\\build-bridge.ps1")
    server = start_backend()
    a, b = B("A", 1002), B("B", 1003)
    try:
        a.start(); b.start()
        check(a.state().startswith("realms on "), "A: Realms switched on by --realms-url")

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
        check(r.startswith("fail bad_invite"), "the invite works once: " + r)

        r = b.cmd("claim " + rid)
        check(r.startswith("ok hosted 76561197960266730"), "B finds A hosting (A's SteamID): " + r)

        world = {"Level.sav": b"EMSH" + os.urandom(5000), "General.sav": b"EMSH" + b"g" * 300,
                 "mirror_realm_beds.txt": b"bed 1 2 3\n"}
        write_world(os.path.join(a.realm_dir(rid), "up"), world)
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
        r = a.cmd("upload %s 2" % rid)
        check(r.startswith("fail bad_input"), "a file name with a space isn't uploaded: " + r)

        # a hostile world on the server: an entry that climbs out of the folder
        key = open(os.path.join(a.realm_dir(rid), "member.key")).read().strip()
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

        r = b.cmd("leave " + rid)
        check(r == "ok" and not os.path.exists(os.path.join(b.realm_dir(rid), "member.key")), "B leaves; its key is gone")
        b.cmd("list")
        check(b.lines("realm") == [], "B lists no Realms")
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
    finally:
        a.stop(); b.stop()
        kill_tree(server)
        for x in (a, b):
            shutil.rmtree(x.dir, ignore_errors=True)
    print("\n%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
