"""4-player test of SurrounSyncBridge.exe without Steam or the game: one host bridge and three guest bridges
talk over TCP on 127.0.0.1 (--test-net, guest ids 1002-1004) and we check slots, routing, the guest-to-guest
relay, a guest leaving and coming back, and a fifth player being turned away.

    python tools/test-bridge-4p.py      (build the bridge first: tools/build-bridge.ps1)
"""
import os, random, shutil, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
tb = import_module("test-bridge")

ROOT = tb.ROOT
EXE = tb.EXE
def free_port():
    # a port the OS lets us listen on: Windows (Hyper-V/WinNAT) reserves ranges that move at boot, and this
    # range overlapped one (45915-46014 here: ~1 run in 12 couldn't listen)
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT = free_port()
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def start(role, d, test_id=None):
    args = [EXE, "--role", role, "--dir", d, "--test-net", str(PORT), "--no-game-check"]
    if role == "guest":
        args += ["--peer", "1001"]
    if test_id:
        args += ["--test-id", str(test_id)]
    return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def roster(d):
    p = os.path.join(d, "mirror_roster.txt")
    try:
        s = open(p, encoding="utf-8").read()
    except OSError:
        return None
    if not s.endswith("END\n"):
        return None
    r = {"peers": {}}
    for line in s.splitlines():
        f = line.split(" ", 6)
        if f[0] == "me":
            r["slot"], r["id"] = int(f[1]), f[2]
        elif f[0] == "peer" and len(f) >= 6:
            r["peers"][f[4]] = {"out": f[1], "in": f[2], "slot": int(f[3]), "state": f[5]}
    return r


def pose(d, tag, seq, text):
    tb.lua_write(os.path.join(d, "mirror_link_%s.txt" % tag), "%d %d %s END\n" % (seq, int(time.time()), text))


def read_pose(d, tag):
    try:
        return open(os.path.join(d, "mirror_link_%s.txt" % tag), encoding="utf-8").read()
    except OSError:
        return ""


def main():
    if not os.path.exists(EXE):
        print("build the bridge first: tools\\build-bridge.ps1")
        return 2
    base = tempfile.mkdtemp(prefix="mirror_bridge_4p_")
    H = os.path.join(base, "host")
    G = {i: os.path.join(base, "g%d" % i) for i in (1002, 1003, 1004, 1005)}
    for d in [H] + list(G.values()):
        os.makedirs(d)
    procs = {}
    try:
        procs["h"] = start("host", H)
        time.sleep(0.5)
        def connected(n):
            peers = (roster(H) or {}).get("peers", {})
            return peers if len(peers) == n and all(p["state"] == "connected" for p in peers.values()) else None
        # in order, each after the one before is in: slots follow the connect order, and a slow loopback connect
        # (antivirus here: 1-3 s) reordered them with fixed gaps (audit N1)
        for n, i in enumerate((1002, 1003, 1004), 1):
            procs[i] = start("guest", G[i], i)
            tb.wait_for(lambda: connected(n), 20)

        r = tb.wait_for(lambda: connected(3), 40)
        check(r is not None, "host has three connected guests")
        if r:
            check(r["1002"]["out"] == "host" and r["1002"]["in"] == "guest" and r["1002"]["slot"] == 1,
                  "first guest is slot 1 with the two-player file names")
            check(r["1003"]["out"] == "to2" and r["1003"]["slot"] == 2, "second guest is slot 2 (to2/from2)")
            check(r["1004"]["out"] == "to3" and r["1004"]["slot"] == 3, "third guest is slot 3 (to3/from3)")

        def mates_ok(i, want):
            r = roster(G[i])
            return r and set(r["peers"].keys()) == want and all(p["state"] == "connected" for p in r["peers"].values())
        ok = tb.wait_for(lambda: mates_ok(1002, {"1001", "1003", "1004"}) and mates_ok(1003, {"1001", "1002", "1004"})
                         and mates_ok(1004, {"1001", "1002", "1003"}), 20)
        check(ok, "every guest is connected to the host and (through it) to both other guests")
        g = roster(G[1003]) or {}
        check(g.get("slot") == 2, "guest 1003 knows it is slot 2 (%s)" % g.get("slot"))
        if g.get("peers"):
            check(g["peers"]["1001"]["out"] == "guest" and g["peers"]["1002"]["out"] == "to1" and g["peers"]["1004"]["in"] == "from3",
                  "guest file names: host link guest/host, other guests to<slot>/from<slot>")

        # host -> one guest only
        tb.put_blob(H, "look", "to2", "host look for slot 2")
        got = tb.wait_for(lambda: tb.get_blob(G[1003], "look", "host"), 10)
        check(got == "host look for slot 2", "a host blob for slot 2 reaches only that guest")
        time.sleep(0.5)
        check(tb.get_blob(G[1002], "look", "host") is None and tb.get_blob(G[1004], "look", "host") is None,
              "the other guests don't get slot 2's blob")
        # guest -> host
        tb.put_blob(G[1004], "req", "guest", "join 42")
        check(tb.wait_for(lambda: tb.get_blob(H, "req", "from3"), 10) == "join 42", "guest 3's blob arrives on the host as from3")
        # guest -> guest through the host
        tb.put_blob(G[1002], "look", "to2", "guest1 look for guest2")
        check(tb.wait_for(lambda: tb.get_blob(G[1003], "look", "from1"), 10) == "guest1 look for guest2",
              "guest 1 -> guest 2 blob goes through the host's bridge")
        check(tb.get_blob(H, "look", "from1") is None, "the relayed blob is not written on the host")
        big = "".join(random.choice("abcdefgh \n") for _ in range(60000))
        tb.put_blob(G[1004], "zombies", "to1", big)
        check(tb.wait_for(lambda: tb.get_blob(G[1002], "zombies", "from3"), 10) == big,
              "a 60 KB compressed fragmented blob survives the relay")
        pose(G[1003], "to3", 7, "1.0 2.0 3.0")
        check(tb.wait_for(lambda: "1.0 2.0 3.0" in read_pose(G[1004], "from2"), 10), "guest 2's pose reaches guest 3 through the host")
        pose(G[1002], "guest", 9, "5.0 6.0 7.0")
        check(tb.wait_for(lambda: "5.0 6.0 7.0" in read_pose(H, "guest"), 10), "guest 1's pose still reaches the host directly")

        # a fifth player: the game is full
        procs[1005] = start("guest", G[1005], 1005)
        def lobby():
            try:
                with open(os.path.join(G[1005], "mirror_lobby.txt"), encoding="utf-8") as f: return f.read()
            except OSError:   # missing yet, or denied while the bridge replaces it
                return ""
        check(tb.wait_for(lambda: "joinerror full" in lobby(), 15), "a fifth player is told the game is full")
        procs[1005].kill(); procs[1005].wait(); del procs[1005]

        # guest 3 crashes: the others carry on, guest 3 drops out of their lists
        procs[1004].kill(); procs[1004].wait(); del procs[1004]
        gone = tb.wait_for(lambda: mates_ok(1002, {"1001", "1003"}) and mates_ok(1003, {"1001", "1002"}), 40)
        check(gone, "after guest 3 goes silent the other guests drop it (and keep each other)")
        tb.put_blob(G[1003], "life", "to1", "dead")
        check(tb.wait_for(lambda: tb.get_blob(G[1002], "life", "from2"), 10) == "dead", "guests 1 and 2 still talk after guest 3 left")
        tb.put_blob(H, "sky", "host", "noon")
        check(tb.wait_for(lambda: tb.get_blob(G[1002], "sky", "host"), 10) == "noon", "the host still reaches guest 1")

        # guest 3 comes back: same slot, no second entry
        procs[1004] = start("guest", G[1004], 1004)
        back = tb.wait_for(lambda: mates_ok(1002, {"1001", "1003", "1004"}), 25)
        check(back, "guest 3 comes back and the others see it again")
        r = roster(H) or {"peers": {}}
        check(len(r["peers"]) == 3 and r["peers"].get("1004", {}).get("slot") == 3, "it gets slot 3 again, no duplicate entry")
        tb.put_blob(G[1002], "look", "to3", "hello again")
        check(tb.wait_for(lambda: tb.get_blob(G[1004], "look", "from1"), 10) == "hello again", "relay to the rejoined guest works")
    finally:
        for p in procs.values():
            try:
                p.kill(); p.wait()
            except Exception:
                pass
        if fails:
            for d in [H] + list(G.values()):
                for name in os.listdir(d):
                    if name.startswith("mirror_bridge_") and name.endswith(".log"):
                        print("--- %s/%s\n%s" % (os.path.basename(d), name, tb.log_of(d, name).strip()[-3000:]))
        shutil.rmtree(base, ignore_errors=True)
    print("\n%s" % ("ALL PASSED" if not fails else "%d FAILED" % len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
