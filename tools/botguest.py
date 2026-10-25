"""Fake guests for a 4-player test without 4 games: each bot is a real SurrounSyncBridge.exe (guest role on the
one-PC test network) plus this script writing the files a guest game would write - hello, where, life, look and
a pose walking a circle around the host. The host game (and a real guest game) see them as players 3 and 4.

    python tools/botguest.py                     (bots 1003 + 1004 on test port 47123, 300 s)
    python tools/botguest.py --ids 1003 --secs 60 --radius 600

Needs the host game in "bridgetest" mode (tools/mirror-mode.ps1 / the kit) hosting a co-op world. The bots accept
themselves through the host's devtest watcher (mirror_dev_Saved.txt "accept <id>"), like the kit's join does.
Prints each bot's roster and what it hears from the host and the other players.
"""
import argparse, math, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SD = os.path.join(os.environ.get("LOCALAPPDATA", ""), "SurrounDead")


def protocol():
    s = open(os.path.join(ROOT, "mod", "SurrounSync", "Scripts", "mirror", "version.lua"), encoding="utf-8").read()
    return re.search(r"PROTOCOL = (\d+)", s).group(1)


def write(path, text):
    # atomic, CRLF like the game's Lua io writes on Windows
    tmp = path + ".bot"
    with open(tmp, "wb") as f:
        f.write(text.replace("\n", "\r\n").encode("utf-8"))
    for _ in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:   # the bridge is reading it right now
            time.sleep(0.005)


def read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read().replace("\r", "")
    except OSError:
        return None


def roster(d):
    s = read(os.path.join(d, "mirror_roster.txt"))
    if not s or not s.endswith("END\n"):
        return None
    r = {"slot": None, "peers": []}
    for line in s.splitlines():
        f = line.split(" ", 6)
        if f[0] == "me" and len(f) >= 3:
            r["slot"] = f[1]
        elif f[0] == "peer" and len(f) >= 6:
            r["peers"].append({"out": f[1], "in": f[2], "slot": f[3], "id": f[4], "state": f[5],
                               "name": f[6] if len(f) > 6 else f[4]})
    return r


class Bot:
    def __init__(self, bid, exe, port, base, phase, radius):
        self.id, self.phase, self.radius = bid, phase, radius
        self.dir = os.path.join(base, str(bid))
        os.makedirs(self.dir, exist_ok=True)
        self.proc = subprocess.Popen([exe, "--role", "guest", "--peer", "1001", "--test-net", str(port),
                                      "--test-id", str(bid), "--dir", self.dir, "--no-game-check"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.seq, self.tags, self.heard, self.said = 0, ["guest"], {}, set()
        self.ride = None   # host's name of the car this bot rides in (see CMD)
        self.t0 = time.time()

    def log(self, m):
        print("[bot %d %5.1fs] %s" % (self.id, time.time() - self.t0, m), flush=True)

    def blobs(self, tag, look):
        hello = "SurrounSync protocol %s role guest" % protocol()
        for name, body in (("hello", hello), ("where", "joined"), ("life", "alive"), ("look", look)):
            if body is not None:
                write(os.path.join(self.dir, "mirror_%s_%s.txt" % (name, tag)), body + "\nEND\n")

    def host_sample(self):
        # the host's pose file: "<seq> <stamp> <sample>\t<seq> <sample>... END"; sample = x y z yaw ... clock
        s = read(os.path.join(self.dir, "mirror_link_host.txt"))
        m = s and re.match(r"^\d+ \d+ (.*?)(\t| END)", s.strip())
        return m.group(1).split(" ") if m else None

    def step(self):
        r = roster(self.dir)
        if r:
            tags = ["guest"] + [p["out"] for p in r["peers"] if p["out"] not in ("guest", "host")]
            if tags != self.tags:
                self.log("roster: me slot %s, peers %s" % (r["slot"], ", ".join(
                    "%s(%s %s %s)" % (p["name"], p["slot"], p["out"], p["state"]) for p in r["peers"])))
                self.tags = tags
        look = read(os.path.join(self.dir, "mirror_look_host.txt"))
        look = look and look.replace("\nEND\n", "").rstrip("\n")
        for tag in self.tags:
            if tag not in self.said or int(time.time()) % 5 == 0:
                self.blobs(tag, look)
                write(os.path.join(self.dir, "mirror_ride_%s.txt" % tag), "R %s\nEND\n" % (self.ride or "-"))
                self.said.add(tag)
        f = self.host_sample()
        if not f or len(f) < 5:
            return
        a = self.phase + (time.time() - self.t0) * 0.3
        if not self.ride:   # riding: stay on the host (the driver) - the ghost sits in its seat anyway
            f[0] = "%.1f" % (float(f[0]) + math.cos(a) * self.radius)
            f[1] = "%.1f" % (float(f[1]) + math.sin(a) * self.radius)
            f[3] = "%.1f" % ((math.degrees(a) + 90) % 360)
        f[-1 if "," not in f[-1] else -2] = "%.3f" % (time.time() - self.t0)
        self.seq += 1
        sample = " ".join(f)
        line = "%d %d %s END\n" % (self.seq, int(time.time()), sample)
        for tag in self.tags:
            write(os.path.join(self.dir, "mirror_link_%s.txt" % tag), line)
        # what we hear from the others
        for tag in self.tags:
            inn = {"guest": "host"}.get(tag, "from" + tag[2:])
            got = read(os.path.join(self.dir, "mirror_link_%s.txt" % inn))
            if got and inn not in self.heard:
                self.heard[inn] = True
                self.log("hearing %s: %s" % (inn, got[:80].replace("\t", " | ")))


# Commands while running (one per write): "ride <host's car name>" puts every bot in that car as a rider,
# "ride -" gets them out.
CMD = os.path.join(SD, "mirror_bots_cmd.txt")


def commands(bots):
    s = (read(CMD) or "").strip()
    if not s:
        return
    write(CMD, "")
    m = re.match(r"^ride (\S+)$", s)
    if not m:
        print("bots: unknown command %r" % s, flush=True)
        return
    for b in bots:
        b.ride = None if m.group(1) == "-" else m.group(1)
        b.said = set()   # resend the blobs (with the ride) now
        b.log("riding in %s" % b.ride if b.ride else "out of the car")


def accept_requests(done, host_dir):
    # host_dir: a bare host bridge's dir (self-test) - accept through its command file instead of the game
    s = read(os.path.join(host_dir or os.path.join(SD, "Link_Host"), "mirror_lobby.txt")) or ""
    for bid in re.findall(r"^request (\d+)", s, re.M):
        if bid not in done:
            cmd = os.path.join(host_dir, "mirror_bridge_cmd.txt") if host_dir else os.path.join(SD, "mirror_dev_Saved.txt")
            if (read(cmd) or "").strip():
                return   # the last command isn't read yet: don't overwrite it
            write(cmd, "accept %s\n" % bid)
            done.add(bid)
            print("host: accepted join request %s (devtest)" % bid, flush=True)
            return   # the watcher reads one command at a time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", default="1003,1004")
    ap.add_argument("--port", type=int, default=47123)
    ap.add_argument("--secs", type=float, default=300)
    ap.add_argument("--radius", type=float, default=400)
    ap.add_argument("--bridge", default=os.environ.get("SURROUNSYNC_BRIDGE",
                                                        os.path.join(ROOT, "mod", "SurrounSync", "bridge", "SurrounSyncBridge.exe")))
    ap.add_argument("--no-accept", action="store_true")
    ap.add_argument("--crash", action="store_true", help="vanish at the end (no goodbye), like a crashed game")
    ap.add_argument("--host-dir", help="accept through this host bridge dir (self-test without the game)")
    a = ap.parse_args()
    base = tempfile.mkdtemp(prefix="mirror_bots_")
    print("bots in " + base, flush=True)
    ids = [int(x) for x in a.ids.split(",") if x]
    bots = [Bot(b, a.bridge, a.port, base, i * 2.1, a.radius) for i, b in enumerate(ids)]
    accepted, end = set(), time.time() + a.secs
    try:
        while time.time() < end and all(b.proc.poll() is None for b in bots):
            if not a.no_accept:
                accept_requests(accepted, a.host_dir)
            commands(bots)
            for b in bots:
                b.step()
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        if not a.crash:
            # leave like a guest game does: back in its "own" world, then goodbye
            for b in bots:
                for tag in b.tags:
                    write(os.path.join(b.dir, "mirror_where_%s.txt" % tag), "own\nEND\n")
                    write(os.path.join(b.dir, "mirror_bye_%s.txt" % tag), "stop %d\nEND\n" % int(time.time()))
                b.log("leaving (said goodbye)")
            time.sleep(3.0)
        for b in bots:
            write(os.path.join(b.dir, "mirror_bridge_cmd.txt"), "stop\n")
        time.sleep(1.0)
        for b in bots:
            if b.proc.poll() is None:
                b.proc.kill()
            print("[bot %d] bridge exit %s; files in %s" % (b.id, b.proc.poll(), b.dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
