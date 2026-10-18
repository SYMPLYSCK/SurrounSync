"""Runs the mod's real link code (two Lua runtimes via lupa) through two bridges over local TCP,
so the whole Steam path can be tested without Steam or the game.

    pip install --target <dir> lupa, set PYTHONPATH=<dir>, then: python tools/test-link-e2e.py
"""
import os, random, shutil, subprocess, sys, tempfile, time

try:
    from lupa import lua54
except ImportError:
    print("needs lupa (Lua 5.4 for Python): pip install --target <dir> lupa, then set PYTHONPATH=<dir>")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
EXE = os.path.join(ROOT, "mod", "SurrounSync", "bridge", "SurrounSyncBridge.exe")
PORT = 46000 + random.randint(0, 999)
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def pair(r):
    if r is None:
        return None, None
    if isinstance(r, tuple):
        return (r + (None, None))[:2]
    return r, None


def runtime(role, link_dir):
    L = lua54.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
        local scripts, role, link_dir = ...
        package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
        local function out(lvl) return function(m) print("[" .. role .. "][" .. lvl .. "] " .. tostring(m)) end end
        package.preload["mirror.log"] = function()
            return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end }
        end
        link = require("mirror.link")
        events = require("mirror.events")
        link.start_bridge = function() end          -- the test starts the bridges itself
        link.configure({ transport = "steam", link_dir = link_dir, netsim = { enabled = false }, steam = {} })
        link.open(role)
    ''', SCRIPTS, role, link_dir)
    return L


def main():
    if not os.path.exists(EXE):
        print("build the bridge first: tools\\build-bridge.ps1")
        return 2
    base = tempfile.mkdtemp(prefix="mirror_e2e_")
    sd = os.path.join(base, "SurrounDead")
    A, B = os.path.join(sd, "Link_Host"), os.path.join(sd, "Link_Guest")
    os.makedirs(A); os.makedirs(B)
    os.environ["LOCALAPPDATA"] = base
    procs = []
    try:
        procs.append(subprocess.Popen([EXE, "--role", "host", "--dir", A, "--test-net", str(PORT), "--no-game-check"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        procs.append(subprocess.Popen([EXE, "--role", "guest", "--peer", "1001", "--dir", B, "--test-net", str(PORT),
                                       "--no-game-check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        H, G = runtime("host", "Link_Host"), runtime("guest", "Link_Guest")

        world = bytes(range(256)) * 1600
        rnd = random.Random(7)
        world = bytes(rnd.randrange(256) for _ in range(len(world)))
        H.execute('''
            local w = ...
            link.put_blob("hello", "SurrounSync protocol 26 role host")
            link.put_file("world_Level.sav", w, "1792119879")
            ev = events.new("fire", 32, 2)
            ev:send("shot 1")
            ev:send("shot 2")
        ''', world)
        G.execute('expected_world = ...', world)
        G.execute('''
            link.put_blob("hello", "SurrounSync protocol 26 role guest")
            link.put_blob("req", "join 1792119879")
            got_events = {}
            gev = events.new("fire", 32, 2)
        ''')

        state = {"h_pose": None, "g_pose": None, "h_hello": None, "g_hello": None, "req": None, "file": None, "tag": None}
        seq = 0
        t0 = time.time()
        while time.time() - t0 < 25:
            seq += 1
            H.execute('local s = ... ; link.tick(0.033); link.send(s, "1.0 2.0 3.0")', seq)
            G.execute('local s = ... ; link.tick(0.033); link.send(s, "4.0 5.0 6.0")', seq)
            H.execute('ev:pump(function() end)')
            G.execute('gev:pump(function(p) got_events[#got_events + 1] = p end)')
            hs, hp = pair(H.eval('link.poll()'))
            gs, gp = pair(G.eval('link.poll()'))
            if hp: state["h_pose"] = hp
            if gp: state["g_pose"] = gp
            v = H.eval('link.get_blob("hello")'); state["g_hello"] = v or state["g_hello"]
            v = H.eval('link.get_blob("req")'); state["req"] = v or state["req"]
            v = G.eval('link.get_blob("hello")'); state["h_hello"] = v or state["h_hello"]
            same, tag = pair(G.eval('(function() local d, t = link.get_file("world_Level.sav"); '
                                    'if d then return d == expected_world, t end end)()'))
            if same is not None:
                state["file"], state["tag"] = same, tag
            done = all(state[k] is not None for k in ("h_pose", "g_pose", "h_hello", "g_hello", "req", "file")) \
                and G.eval('#got_events') >= 2
            if done:
                break
            time.sleep(0.033)

        check(state["g_pose"] == "1.0 2.0 3.0", "guest gets the host's pose through the Lua link")
        check(state["h_pose"] == "4.0 5.0 6.0", "host gets the guest's pose")
        check(state["h_hello"] == "SurrounSync protocol 26 role host", "guest reads the host's hello (protocol check works)")
        check(state["g_hello"] == "SurrounSync protocol 26 role guest", "host reads the guest's hello")
        check(state["req"] == "join 1792119879", "host reads the guest's join request")
        check(state["file"] is True and state["tag"] == "1792119879", "400 KB binary world file arrives byte-exact with its tag")
        n = G.eval('#got_events')
        check(n == 2 and G.eval('got_events[1]') == "shot 1", "events arrive once, in order, not dropped by the age check (%d)" % n)

        H.execute('link.put_blob("life", "dead")')
        ok = False
        for _ in range(200):
            H.execute('link.tick(0.033)'); G.execute('link.tick(0.033)')
            if G.eval('link.get_blob("life")') == "dead":
                ok = True; break
            time.sleep(0.03)
        check(ok, "a blob written later arrives")
        got_last, n_seen = False, 0
        for i in range(50):
            H.execute('local i = ... ; link.put_blob("zombies", string.rep("Z 12 1 2 3 165000.0 180000.0 1300.0 90.0 0 0 0 0 0 0\\n", 60) .. "n " .. i)', i)
            for _ in range(3):
                H.execute('link.tick(0.033)'); G.execute('link.tick(0.033)')
                v = G.eval('link.get_blob("zombies")')
                if v:
                    n_seen += 1
                    if v.endswith("n 49"):
                        got_last = True
                time.sleep(0.033)
        for _ in range(100):
            if got_last:
                break
            G.execute('link.tick(0.033)')
            v = G.eval('link.get_blob("zombies")')
            if v and v.endswith("n 49"):
                got_last = True
            time.sleep(0.03)
        check(got_last and n_seen >= 25, "zombie-sized blob at 10 Hz: %d updates seen, last one arrived" % n_seen)
        age = G.eval('link.peer_age(os.time())')
        check(age <= 0, "peer_age of a fresh stamp is not positive (%s)" % age)
    finally:
        for p in procs:
            try:
                p.kill(); p.wait()
            except Exception:
                pass
        for d in (A, B):
            for name in ("mirror_bridge_host.log", "mirror_bridge_guest.log"):
                p = os.path.join(d, name)
                if os.path.exists(p):
                    print("--- " + name + "\n" + open(p, encoding="utf-8", errors="replace").read().strip())
        shutil.rmtree(base, ignore_errors=True)
    print("\n%s" % ("ALL PASSED" if not fails else "%d FAILED" % len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
