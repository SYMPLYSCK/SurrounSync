"""Latency benchmark for SurrounSyncBridge.exe over a simulated internet link.

Two bridges talk through a local proxy that behaves like a long-distance Steam P2P connection: one-way delay,
packet loss on the unreliable channel, and on the reliable channel lost packets are resent a round trip later
and hold up everything queued behind them (big messages are split into ~1200 byte packets, so they're more
likely to lose a piece). The host side writes game-like traffic (player poses at 30/s, a zombie snapshot at
15/s, small events at 10/s) and the guest side times how late each one arrives.

    python tools/bench-bridge.py <bridge.exe> [<other bridge.exe> ...] [--latency 70] [--loss 0.02] [--secs 30]
"""
import argparse, ctypes, heapq, os, random, socket, statistics, subprocess, tempfile, threading, time

MTU = 1200


class Proxy:
    """guest -> listen_port -> (impairment) -> host on host_port, and back"""

    def __init__(self, listen_port, host_port, latency, loss, seed):
        self.listen_port, self.host_port = listen_port, host_port
        self.latency, self.loss = latency / 1000.0, loss
        self.rng = random.Random(seed)
        self.bytes = [0, 0]
        self.stop = False

    def start(self):
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", self.listen_port)); srv.listen(1); srv.settimeout(0.5)
        while not self.stop:
            try:
                g, _ = srv.accept()
            except socket.timeout:
                continue
            h = socket.create_connection(("127.0.0.1", self.host_port))
            for a, b, i in ((g, h, 0), (h, g, 1)):
                threading.Thread(target=self.pipe, args=(a, b, i), daemon=True).start()

    def pipe(self, src, dst, direction):
        heap, lock, cv = [], threading.Lock(), threading.Condition()
        last_reliable = [0.0]
        seq = [0]

        def writer():
            while not self.stop:
                with cv:
                    while not heap and not self.stop:
                        cv.wait(0.05)
                    if not heap:
                        continue
                    t, _, frame = heap[0]
                    wait = t - time.perf_counter()
                    if wait > 0:
                        cv.wait(min(wait, 0.01)); continue
                    heapq.heappop(heap)
                try:
                    dst.sendall(frame)
                except OSError:
                    return
        threading.Thread(target=writer, daemon=True).start()

        def read(n):
            buf = b""
            while len(buf) < n:
                c = src.recv(n - len(buf))
                if not c:
                    raise OSError
                buf += c
            return buf
        try:
            while not self.stop:
                head = read(5)
                n, ch = int.from_bytes(head[:4], "little"), head[4]
                data = read(n)
                self.bytes[direction] += n
                now = time.perf_counter()
                if ch == 1:
                    packets = max(1, (n + MTU - 1) // MTU)
                    lost = any(self.rng.random() < self.loss for _ in range(packets))
                    t = now + self.latency + (2 * self.latency + 0.02 if lost else 0)
                    t = max(t, last_reliable[0])          # ordered: waits for anything still being resent
                    last_reliable[0] = t
                else:
                    if self.rng.random() < self.loss:
                        continue
                    t = now + self.latency
                with cv:
                    seq[0] += 1
                    heapq.heappush(heap, (t, seq[0], head + data))
                    cv.notify()
        except OSError:
            pass


def cpu_seconds(pid):
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)
    if not h:
        return 0.0
    c, e, kt, ut = (ctypes.c_ulonglong() for _ in range(4))
    k.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut))
    k.CloseHandle(h)
    return (kt.value + ut.value) / 1e7


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(text.replace("\n", "\r\n").encode())
    for _ in range(50):
        try:
            os.replace(tmp, path); return
        except PermissionError:
            time.sleep(0.001)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace").replace("\r\n", "\n")
    except OSError:
        return None


def snapshot(rng, t, zombies):
    """about what the host's zombie snapshot looks like (~9 KB for 25 zombies)"""
    out = ["D %d /Game/AI/Zombies/Type%d/BP_Zombie_Type%d.BP_Zombie_Type%d_C" % (i, i, i, i) for i in range(1, 9)]
    for z in zombies:
        z[0] += rng.uniform(-4, 4); z[1] += rng.uniform(-4, 4)
        out.append("L %d %s 100.0 3" % (z[3], " ".join(str(rng.randint(1, 8)) for _ in range(12))))
        out.append("Z %d 1 2 3 %.1f %.1f %.1f %.1f %.1f %.1f 0.0 %d %.3f 0" % (
            z[3], z[0], z[1], z[2], rng.uniform(0, 360), rng.uniform(-300, 300), rng.uniform(-300, 300),
            rng.randint(0, 8), rng.random()))
    out.append("T %.6f" % t)
    return "\n".join(out)


def run(exe, args, port):
    base = tempfile.mkdtemp(prefix="bench_bridge_")
    A, B = os.path.join(base, "host"), os.path.join(base, "guest")
    os.makedirs(A); os.makedirs(B)
    proxy = Proxy(port + 1, port, args.latency, args.loss, 7)
    proxy.start()
    common = ["--dir", None, "--no-game-check"]
    host = subprocess.Popen([exe, "--role", "host", "--dir", A, "--test-net", str(port), "--no-game-check"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    guest = subprocess.Popen([exe, "--role", "guest", "--dir", B, "--test-net", str(port + 1), "--no-game-check"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rng = random.Random(1)
    zombies = [[rng.uniform(0, 5000), rng.uniform(0, 5000), 100.0, i] for i in range(args.zombies)]
    lat = {"event": [], "snapshot": [], "pose": []}
    stop = [False]
    seen = {"event": "", "snapshot": "", "pose": ""}
    got_events = set()

    def reader():
        while not stop[0]:
            now = time.perf_counter()
            s = read(os.path.join(B, "mirror_ev_host.txt"))
            if s and s != seen["event"] and s.endswith("\nEND\n"):
                seen["event"] = s
                lat["event"].append(now - float(s.split("\n")[-3].split()[1]))
                got_events.update(line for line in s.split("\n") if line.startswith("E "))
            s = read(os.path.join(B, "mirror_zombies_host.txt"))
            if s and s != seen["snapshot"] and s.endswith("\nEND\n"):
                seen["snapshot"] = s
                lat["snapshot"].append(now - float(s.split("\n")[-3].split()[1]))
            s = read(os.path.join(B, "mirror_link_host.txt"))
            if s and s != seen["pose"]:
                seen["pose"] = s
                parts = s.split()
                if len(parts) > 3:
                    try:
                        lat["pose"].append(now - float(parts[2]))
                    except ValueError:
                        pass
            time.sleep(0.002)

    time.sleep(3.0)                               # connect
    threading.Thread(target=reader, daemon=True).start()
    cpu0 = cpu_seconds(host.pid) + cpu_seconds(guest.pid)
    t_end = time.perf_counter() + args.secs
    seq, events, next_pose, next_snap, next_ev = 0, [], 0.0, 0.0, 0.0
    sent = {"event": 0, "snapshot": 0, "pose": 0}
    while time.perf_counter() < t_end:
        now = time.perf_counter()
        if now >= next_pose:
            next_pose = now + 1 / 30
            seq += 1
            write(os.path.join(A, "mirror_link_host.txt"), "%d %d %.6f 1.0 2.0 3.0 4.0 5.0 6.0 0 END\n" % (seq, int(time.time()), now))
            sent["pose"] += 1
        if now >= next_snap:
            next_snap = now + 1 / 15
            write(os.path.join(A, "mirror_zombies_host.txt"), snapshot(rng, now, zombies) + "\nEND\n")
            sent["snapshot"] += 1
        if now >= next_ev:
            next_ev = now + 0.1
            events.append("E %.6f hit %d" % (now, seq))
            events = events[-16:]
            write(os.path.join(A, "mirror_ev_host.txt"), "\n".join(events) + "\nEND\n")
            sent["event"] += 1
        time.sleep(0.001)
    time.sleep(1.0)
    stop[0] = True
    cpu = cpu_seconds(host.pid) + cpu_seconds(guest.pid) - cpu0
    host.kill(); guest.kill(); proxy.stop = True
    lat["events_delivered"] = len(got_events)
    return lat, sent, proxy.bytes, cpu


def ms(v):
    return "%5.0f" % (v * 1000)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exes", nargs="+")
    ap.add_argument("--latency", type=float, default=70.0, help="one-way delay, ms")
    ap.add_argument("--loss", type=float, default=0.02, help="packet loss, 0..1")
    ap.add_argument("--secs", type=float, default=30.0)
    ap.add_argument("--zombies", type=int, default=25)
    args = ap.parse_args()
    print("link: %.0f ms one way, %.1f%% loss, %d zombies, %.0f s per run" % (args.latency, args.loss * 100, args.zombies, args.secs))
    port = 47600 + random.randint(0, 300)
    for i, exe in enumerate(args.exes):
        lat, sent, wire, cpu = run(exe, args, port + i * 10)
        print("\n%s" % exe)
        for k in ("event", "snapshot", "pose"):
            v = sorted(lat[k])
            if not v:
                print("  %-8s nothing arrived" % k); continue
            p95 = v[int(len(v) * 0.95) - 1]
            print("  %-8s median %s ms  p95 %s ms  max %s ms   arrived %d of %d" % (
                k, ms(statistics.median(v)), ms(p95), ms(v[-1]), len(v), sent[k]))
        print("  every event delivered: %d of %d" % (lat["events_delivered"], sent["event"]))
        print("  on the wire: %.0f KB/s host->guest, bridges' CPU %.1f%% of one core" % (
            wire[1] / 1024 / args.secs, cpu / args.secs * 100))


if __name__ == "__main__":
    main()
