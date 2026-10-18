"""Tests SurrounSyncBridge.exe without Steam or the game: two bridges talk over TCP on 127.0.0.1
(--test-net) and we check what arrives on the other side.

    python tools/test-bridge.py      (build the bridge first: tools/build-bridge.ps1)
"""
import os, random, re, shutil, string, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "mod", "SurrounSync", "bridge", "SurrounSyncBridge.exe")
PORT = 47000 + random.randint(0, 999)
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def lua_write(path, text):
    with open(path, "wb") as f:
        f.write(text.replace("\n", "\r\n").encode("utf-8"))


def put_blob(d, name, role, body):
    lua_write(os.path.join(d, "mirror_%s_%s.txt" % (name, role)), body + "\nEND\n")


def get_blob(d, name, role):
    p = os.path.join(d, "mirror_%s_%s.txt" % (name, role))
    if not os.path.exists(p):
        return None
    try:
        with open(p, "rb") as f:
            s = f.read().decode("utf-8").replace("\r\n", "\n")
    except OSError:
        return None
    return s[:-len("\nEND\n")] if s.endswith("\nEND\n") else None


def wait_for(fn, secs=10.0):
    t = time.time()
    while time.time() - t < secs:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    return fn()


def start(role, d, extra=()):
    args = [EXE, "--role", role, "--dir", d, "--test-net", str(PORT), "--no-game-check"] + list(extra)
    return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def log_of(d, name):
    p = os.path.join(d, name)
    try:
        return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
    except OSError:
        return ""


def hammer(path, stop):
    while not stop[0]:
        try:
            with open(path, "rb") as f:
                f.read()
                time.sleep(0.002)
        except OSError:
            pass


def main():
    if not os.path.exists(EXE):
        print("build the bridge first: tools\\build-bridge.ps1")
        return 2
    base = tempfile.mkdtemp(prefix="mirror_bridge_test_")
    A, B = os.path.join(base, "host"), os.path.join(base, "guest")
    os.makedirs(A); os.makedirs(B)
    procs = []
    try:
        print("1. fixed roles, both directions")
        put_blob(A, "hello", "host", "SurrounSync protocol 26 role host")
        put_blob(B, "hello", "guest", "SurrounSync protocol 26 role guest")
        put_blob(B, "req", "guest", "join 1792119879")
        world = "".join(random.choice(string.ascii_letters + string.digits + "+/") for _ in range(1_500_000))
        put_blob(A, "file_world_Level.sav", "host", "1792119879:1125000:" + world)
        procs.append(start("host", A))
        procs.append(start("guest", B, ["--peer", "1001"]))
        lua_write(os.path.join(A, "mirror_link_host.txt"), "7 %d 1.0 2.0 3.0 END\n" % int(time.time()))
        lua_write(os.path.join(B, "mirror_link_guest.txt"), "9 %d 4.0 5.0 6.0 END\n" % int(time.time()))

        check(wait_for(lambda: get_blob(B, "hello", "host")) == "SurrounSync protocol 26 role host", "host hello reached the guest (\\r\\n file)")
        check(wait_for(lambda: get_blob(A, "hello", "guest")) == "SurrounSync protocol 26 role guest", "guest hello reached the host")
        check(wait_for(lambda: get_blob(A, "req", "guest")) == "join 1792119879", "guest join request reached the host")
        got = wait_for(lambda: get_blob(B, "file_world_Level.sav", "host"), 20)
        check(got == "1792119879:1125000:" + world, "1.5 MB world file arrived intact (chunked)")
        pose = wait_for(lambda: log_of(B, "mirror_link_host.txt"))
        check(pose.startswith("7 ") and pose.rstrip().endswith("1.0 2.0 3.0 END"), "host pose reached the guest")
        check(wait_for(lambda: log_of(A, "mirror_link_guest.txt")).startswith("9 "), "guest pose reached the host")
        check(wait_for(lambda: os.path.exists(os.path.join(B, "mirror_clock_offset.txt"))), "clock offset written")

        put_blob(A, "life", "host", "alive")
        check(wait_for(lambda: get_blob(B, "life", "host")) == "alive", "a new blob arrives")
        put_blob(A, "life", "host", "dead")
        check(wait_for(lambda: get_blob(B, "life", "host") == "dead"), "a changed blob arrives again")

        print("1b. the game reading the file non-stop while updates arrive")
        import threading
        stop = [False]
        th = threading.Thread(target=hammer, args=(os.path.join(B, "mirror_life_host.txt"), stop), daemon=True)
        th.start()
        for i in range(40):
            put_blob(A, "life", "host", "state %d" % i)
            time.sleep(0.04)
        check(wait_for(lambda: get_blob(B, "life", "host") == "state 39", 10), "the last update lands although the file is busy")
        stop[0] = True
        th.join()

        print("1b2. heartbeat: each connector reports the other's game and how long ago it was heard")

        def status(d, role):
            return log_of(d, "mirror_bridge_status_%s.txt" % role) or ""

        def hb(d, role):
            m = re.search(r"peer_hb (-?[\d.]+)", status(d, role))
            return float(m.group(1)) if m else None
        check(wait_for(lambda: "peer_game alive" in status(B, "guest") and "peer_game alive" in status(A, "host"), 10),
              "both status files say the other game is alive")
        h = hb(B, "guest")
        check(h is not None and 0 <= h < 5, "guest heard the host's connector recently (%s s)" % h)
        procs[0].kill(); procs[0].wait()
        check(wait_for(lambda: (hb(B, "guest") or 0) > 15, 25), "host connector gone -> peer_hb passes 15 s (%s)" % hb(B, "guest"))

        print("1c. a file left over from an earlier session is not sent")
        stale = os.path.join(A, "mirror_oldreq_host.txt")
        lua_write(stale, "join 1\nEND\n")
        old = time.time() - 600
        os.utime(stale, (old, old))
        procs[0].kill(); procs[0].wait()
        procs[0] = start("host", A)
        put_blob(A, "fresh", "host", "fresh after restart")
        check(wait_for(lambda: get_blob(B, "fresh", "host"), 15) == "fresh after restart", "fresh blob after the restart arrives")
        check(get_blob(B, "oldreq", "host") is None, "the 10-minute-old leftover was not sent")

        print("2. host restarts: its old files must vanish on the guest")
        procs[0].kill(); procs[0].wait()
        os.remove(os.path.join(A, "mirror_life_host.txt"))
        time.sleep(1.2)
        procs[0] = start("host", A)
        put_blob(A, "look", "host", "new session look")
        check(wait_for(lambda: get_blob(B, "look", "host"), 15) == "new session look", "new session's blob arrives")
        check(wait_for(lambda: not os.path.exists(os.path.join(B, "mirror_life_host.txt"))), "old session's 'life' file is gone")

        for p in procs:
            p.kill(); p.wait()
        procs.clear()

        print("3. menu flow: guest joins before the host presses Host")
        for d in (A, B):
            for f in os.listdir(d):
                os.remove(os.path.join(d, f))
        procs.append(start("auto", A))
        procs.append(start("auto", B))
        lobby = wait_for(lambda: "END" in log_of(A, "mirror_lobby.txt") and log_of(A, "mirror_lobby.txt"))
        check(bool(lobby) and "role idle" in lobby, "idle bridge writes the lobby for the menu")
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0")
        put_blob(B, "hello", "guest", "guest hello")
        put_blob(B, "req", "guest", "join 1")
        time.sleep(2.0)
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        put_blob(A, "hello", "host", "host hello")
        check(wait_for(lambda: "request 1002" in log_of(A, "mirror_lobby.txt"), 15), "the guest shows up as a join request in the host's lobby")
        check(get_blob(A, "req", "guest") is None, "nothing from the guest arrives before the host accepts")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "accept 1002")
        check(wait_for(lambda: get_blob(A, "req", "guest"), 15) == "join 1", "join request sent while the host was idle still arrives")
        check(wait_for(lambda: get_blob(B, "hello", "host"), 15) == "host hello", "host hello reaches the guest after hosting")
        lob = wait_for(lambda: "connected" in log_of(B, "mirror_lobby.txt") and log_of(B, "mirror_lobby.txt"), 10)
        check(bool(lob), "guest lobby shows the peer as connected")

        print("4. the guest joins again in the same run: the host's earlier state arrives again")
        put_blob(A, "look", "host", "host look")
        check(wait_for(lambda: get_blob(B, "look", "host"), 15) == "host look", "(setup) host look arrived")
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0")
        check(wait_for(lambda: get_blob(B, "look", "host") is None, 10), "the switch cleared the host's files on the guest")
        check(wait_for(lambda: get_blob(B, "look", "host"), 15) == "host look", "...and the host resent its look")
        check(wait_for(lambda: get_blob(B, "hello", "host"), 15) == "host hello", "...and its hello")

        print("5. security: limits, kick, block, always-allow, decline")
        big = "x" * (9 * 1024 * 1024)
        put_blob(B, "huge", "guest", big)
        check(wait_for(lambda: "kicked 1002" in log_of(A, "mirror_lobby.txt"), 30), "an oversized message gets the guest kicked")
        check(get_blob(A, "huge", "guest") is None, "...and none of it was written")
        put_blob(B, "after", "guest", "after kick")
        time.sleep(3)
        check(get_blob(A, "after", "guest") is None, "a kicked guest gets nothing through")
        os.remove(os.path.join(B, "mirror_huge_guest.txt"))
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        check(wait_for(lambda: "request 1002" in log_of(A, "mirror_lobby.txt"), 20), "after hosting again the guest can ask again")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "allow 1002")
        check(wait_for(lambda: get_blob(A, "after", "guest"), 15) == "after kick", "always allow: the guest's data flows")
        check("1002" in log_of(A, "mirror_allow.txt"), "always allow: on the allow list")
        procs[0].kill(); procs[0].wait()
        for f in os.listdir(A):
            if f != "mirror_allow.txt":
                os.remove(os.path.join(A, f))
        procs[0] = start("auto", A)
        time.sleep(1.5)
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        put_blob(B, "again", "guest", "allowed")
        check(wait_for(lambda: get_blob(A, "again", "guest"), 20) == "allowed", "an always-allowed guest joins a restarted host without a prompt")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "clearallow")
        time.sleep(1)
        check(not os.path.exists(os.path.join(A, "mirror_allow.txt")), "clearallow empties the list")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        check(wait_for(lambda: "request 1002" in log_of(A, "mirror_lobby.txt"), 20), "(setup) the guest asks again")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "decline 1002")
        put_blob(B, "declined", "guest", "no")
        time.sleep(4)
        check(get_blob(A, "declined", "guest") is None, "a declined guest gets nothing through")
        check("request 1002" not in log_of(A, "mirror_lobby.txt"), "...and doesn't show as a request again")
        check("joinerror declined" in log_of(B, "mirror_lobby.txt"), "...and is told it was declined (no endless waiting)")

        print("6. password: challenge-response, wrong / missing / right, 3 tries")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "password open sesame")
        time.sleep(0.6)
        check("password on" in log_of(A, "mirror_lobby.txt"), "the host's lobby says a password is on")
        check("open sesame" not in log_of(A, "mirror_bridge.log"), "the password itself is never logged")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        time.sleep(0.6)
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0")
        check(wait_for(lambda: "joinerror needpass" in log_of(B, "mirror_lobby.txt"), 20), "no password: the guest is told the host needs one")
        check("request 1002" not in log_of(A, "mirror_lobby.txt"), "...and no join request reached the host")
        time.sleep(1.0)
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0 open says me")
        check(wait_for(lambda: "joinerror badpass" in log_of(B, "mirror_lobby.txt"), 20), "wrong password: told so")
        check("request 1002" not in log_of(A, "mirror_lobby.txt"), "...no join request")
        time.sleep(1.0)
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0 open sesame")
        check(wait_for(lambda: "request 1002" in log_of(A, "mirror_lobby.txt"), 20), "right password: an ordinary join request")
        check("open sesame" not in log_of(B, "mirror_bridge.log"), "the guest doesn't log it either")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "accept 1002")
        put_blob(B, "pw", "guest", "in")
        check(wait_for(lambda: get_blob(A, "pw", "guest"), 15) == "in", "...accepted: data flows")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        time.sleep(0.6)
        for _ in range(3):
            lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0 nope")
            time.sleep(4)
        check("joinerror blocked" in log_of(B, "mirror_lobby.txt"), "three wrong passwords (three tries): blocked")
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "join 0 open sesame")
        time.sleep(5)
        check("request 1002" not in log_of(A, "mirror_lobby.txt"), "...even the right one is refused until hosting again")

        print("7. server browser (test net stand-in for Steam lobbies)")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "password")
        time.sleep(0.6)
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "host")
        time.sleep(0.6)
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "public on 33 Arkis base camp")
        check(wait_for(lambda: "public on" in log_of(A, "mirror_lobby.txt"), 10), "the host's lobby says it's listed")
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "browse")
        check(wait_for(lambda: "server 1001 0 " in log_of(B, "mirror_lobby.txt"), 10), "the guest's search finds the host")
        lob = log_of(B, "mirror_lobby.txt")
        check("33 Arkis_base_camp" in lob or "33 Arkis base camp" in lob, "...with its version and name")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "password pw1")
        time.sleep(0.8)
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "browse")
        check(wait_for(lambda: "server 1001 1 " in log_of(B, "mirror_lobby.txt"), 10), "a password shows in the listing")
        lua_write(os.path.join(A, "mirror_bridge_cmd.txt"), "public off")
        time.sleep(0.8)
        lua_write(os.path.join(B, "mirror_bridge_cmd.txt"), "browse")
        check(wait_for(lambda: "server 1001" not in log_of(B, "mirror_lobby.txt"), 10), "public off: gone from the search")
    finally:
        for p in procs:
            try:
                p.kill(); p.wait()
            except Exception:
                pass
        print("\nbridge logs:")
        for d in (A, B):
            for name in ("mirror_bridge.log", "mirror_bridge_host.log", "mirror_bridge_guest.log"):
                t = log_of(d, name)
                if t:
                    print("--- %s/%s\n%s" % (os.path.basename(d), name, t.strip()))
        shutil.rmtree(base, ignore_errors=True)
    print("\n%s" % ("ALL PASSED" if not fails else "%d FAILED" % len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
