"""Session watch: follows a live SurrounSync co-op or Realm session and notes anything that goes wrong.

It tails every log a session writes on this PC (the mod's mirror_log.txt and UE4SS.log of each install, the
bridge log, the crash and hang folders), runs detectors over each new line, and keeps every problem once:
deduplicated by signature, counted, with the lines that led up to it. Notes are written as it goes, so a crash
of the game (or of this tool) loses nothing.

    python tools/sessionwatch.py                  watch live (Ctrl+C stops); --from-start also reads the current run
    python tools/sessionwatch.py replay FILE...   run the detectors over old logs (mirror_log.1.txt, UE4SS.log, ...)
    python tools/sessionwatch.py report [--all]   findings not reviewed yet, most severe first
    python tools/sessionwatch.py ack SESSION|all  mark findings reviewed

Read-only toward the game: it never writes into a game folder. Notes: %LOCALAPPDATA%\\SurrounSync\\watch\\
(SESSIONWATCH_DIR overrides; the tests use it).
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import time

STEAM = r"C:\Program Files (x86)\Steam\steamapps\common"
INSTALLS = {"main": "SurrounDead", "guest-kit": "SurrounDead_Guest"}  # the kit's second install (tools/ingame/t.sh)
LOCAL = os.path.join(os.environ.get("LOCALAPPDATA", ""), "SurrounDead")
APPDIR = os.path.join(os.environ.get("LOCALAPPDATA", ""), "SurrounSync")
NOTES = os.environ.get("SESSIONWATCH_DIR") or os.path.join(APPDIR, "watch")

POLL_S = 1.0             # file size checks per second; reads only what was appended
FLUSH_S = 2.0            # notes rewritten at most this often while something changed
CONTEXT_LINES = 6        # lines kept before a problem's first occurrence
READ_CAP = 4 << 20       # bytes read per file per poll (a huge backlog is read over several polls)
SAMPLE_CHARS = 300
LOG_GAP_S = 30           # mod log silent this long mid-session: the game froze or hitched
IN_SESSION_S = 15        # "mid-session" = a link stats line within this many seconds before the gap
RTT_MS = 500             # net round trip above this for RTT_RUN samples in a row
RTT_RUN = 3
STALE_RX_S = 3.0         # nothing received from the other game for this long while linked
PEER_HB_S = 5.0
RX_MIN = 5.0             # pose packets per second below this while linked
SKIP_PCT = 20
QUEUE_BYTES = 1 << 20
MEM_GROWTH_MB = 3000     # game private memory growth over the session
RAM_FREE_GB = 2.0
COMMIT_FRAC = 0.92
SEV_RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
# Deduped by normalized text, not title: generic lines, and Lua errors (each distinct error is its own finding).
GENERIC = ("mod-error", "mod-warn", "ue4ss", "bridge", "lua-error")

LINE_RE = re.compile(r"^(\d\d):(\d\d):(\d\d) \[SurrounSync\]\[(\w+)\] (.*)$")
BRIDGE_RE = re.compile(r"^(\d\d):(\d\d):(\d\d) (.*)$")

# Known problems (regex, severity, category, title). Wording comes from the mod's own messages; bridge/Diagnose.cs
# Known() explains the same signatures to players. First match wins.
KNOWN = [
    (r"Lost connection to", "critical", "link", "Lost connection to the other player"),
    (r"safe\(\) caught", "high", "lua-error", "Mod code raised an error (caught)"),
    (r"attempt to (?:index|call|compare|perform arithmetic)|stack traceback", "high", "lua-error", "Lua error"),
    (r"runs an OLDER SurrounSync", "high", "version", "Players run different SurrounSync versions"),
    (r"slotguard: refused|couldn'?t copy (?:your co-op |the )?character home", "high", "save", "Character copy home refused or failed"),
    (r"Couldn'?t back up your save", "high", "save", "Save backup failed"),
    (r"host could not export its world", "high", "join", "Host could not export its world for the join"),
    (r"could not hook", "high", "hooks", "A game hook could not be installed"),
    (r"Steam connection \(SurrounSyncBridge\) stopped", "high", "bridge", "Steam bridge stopped"),
    (r"never confirmed", "medium", "link", "Messages the other side never confirmed"),
    (r"no data from the other game", "medium", "link", "No data from the other game"),
    (r"isn'?t responding", "medium", "link", "The other game is not responding"),
    (r"game closed\. You keep playing in the Realm", "medium", "realm", "Realm host left: takeover countdown"),
    (r"Couldn'?t find solid ground", "medium", "teleport", "Teleport found no ground"),
    (r"Mod check:.*differ", "low", "mods", "Players run different mods"),
    (r"blocked damage from a zombie copy", "low", "guard", "Guard blocked damage from a zombie copy"),
    (r"cm from one of the same kind already here", "low", "builds", "Duplicate building placed next to an existing one"),
]
KNOWN = [(re.compile(rx, re.I), sev, cat, title) for rx, sev, cat, title in KNOWN]
UE4SS_BAD = re.compile(r"stack traceback|attempt to (?:index|call|compare|perform)|Fatal Error|AOB scans could not|"
                       r"\[Lua\].*\berror\b|failed to load|\bexception\b", re.I)
UE4SS_NOISE = re.compile(r"= 0x[0-9A-F]+\s*$", re.I)  # startup offset dumps (UWorld::bKismetScriptError = 0x18D)
BRIDGE_BAD = re.compile(r"\b(?:error|exception|failed|failure|timed? ?out|refused)\b", re.I)
# Counters in the mod's 5 s link stats that only rise when something went wrong (or a guard had to step in).
COUNTER_RE = re.compile(r"\b(failed|missing|not found|no answer|no room|not here|misses|corrected|blocked|refused|lost)\s+(\d+)\b")
COUNTER_PAREN_RE = re.compile(r"\((\d+) (items missing|failed)\)")
COUNTER_SEV = {"corrected": "low", "blocked": "low", "not here": "low", "misses": "low"}


def signature(text):
    """The same problem with different numbers, names or paths counts once (bridge/Diagnose.cs Signature)."""
    s = re.sub(r"\s*\(x\d+ in \d+ s\)", "", text)
    s = re.sub(r"\S*[\\/]Scripts[\\/]mirror[\\/]", "", s)
    s = re.sub(r"Lost connection to .+?\.$", "Lost connection to <player>.", s)
    s = re.sub(r"between you and .+? - ", "between you and <player> - ", s)
    s = re.sub(r"^\S+'s game", "<player>'s game", s)
    s = re.sub(r"-?\d+(\.\d+)?", "N", s)
    return re.sub(r"\s+", " ", s).strip()[:170]


def secs(h, m, s):
    return int(h) * 3600 + int(m) * 60 + int(s)


def now_s():
    return time.strftime("%H:%M:%S")


class Tail:
    """Reads what a log gained since the last poll. A shrunk file or a changed first line is a new game run."""

    def __init__(self, path, from_end):
        self.path, self.pos, self.head, self.buf = path, 0, b"", b""
        if from_end and os.path.exists(path):
            self.pos = os.path.getsize(path)
            self.head = self._head()

    def _head(self):
        try:
            with open(self.path, "rb") as f:
                return f.read(64)
        except OSError:
            return b""

    def read(self):
        """(new complete lines, rotated?)"""
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return [], False
        head = self._head()
        rotated = size < self.pos or (self.pos and head[:len(self.head)] != self.head)
        if rotated:
            self.pos, self.buf = 0, b""
        self.head = head
        if size <= self.pos:
            return [], bool(rotated)
        try:
            with open(self.path, "rb") as f:
                f.seek(self.pos)
                data = f.read(min(size - self.pos, READ_CAP))
        except OSError:
            return [], bool(rotated)
        self.pos += len(data)
        data = self.buf + data
        lines = data.split(b"\n")
        self.buf = lines.pop()
        return [ln.decode("utf-8", "replace").rstrip("\r") for ln in lines], bool(rotated)


class Notebook:
    """One session's findings: deduplicated, counted, written atomically as JSON plus a readable Markdown note."""

    def __init__(self, label, quiet=False, out_dir=None):
        self.dir = out_dir or os.path.join(NOTES, "sessions")
        self.stamp = time.strftime("%Y%m%d-%H%M%S")
        self.data = {"session": self.stamp, "label": label, "started": time.strftime("%Y-%m-%d %H:%M:%S"),
                     "ended": None, "sources": [], "events": [], "findings": {}, "reviewed": False}
        self.quiet, self.dirty, self.flushed, self.seq = quiet, True, 0.0, 0

    def hit(self, side, sev, cat, title, text, src, ctx, at, extra=None, n=1):
        # Unknown lines dedupe by their normalized text; a known problem (fixed title) once per side whatever its wording.
        key = f"{cat}|{side}|{signature(text) if cat in GENERIC else title}"
        f = self.data["findings"].get(key)
        if f is None:
            self.seq += 1
            f = self.data["findings"][key] = {
                "id": f"W{self.seq}", "severity": sev, "category": cat, "side": side, "title": title,
                "first": at, "last": at, "count": 0, "sample": text[:SAMPLE_CHARS], "source": src,
                "context": [c[:SAMPLE_CHARS] for c in ctx][-CONTEXT_LINES:], "detail": extra}
            self.say(f, "NEW")
        elif SEV_RANK[sev] > SEV_RANK[f["severity"]]:
            f["severity"] = sev
            self.say(f, "WORSE")
        f["count"] += n
        f["last"] = at
        if extra:
            f["detail"] = extra
        self.dirty = True
        return f

    def event(self, text):
        self.data["events"].append(f"{now_s()} {text}")
        self.data["events"] = self.data["events"][-200:]
        self.dirty = True
        if not self.quiet:
            print(f"[{now_s()}] {text}", flush=True)

    def say(self, f, what):
        if not self.quiet:
            print(f"[{now_s()}] {what} {f['severity'].upper():8} {f['category']:9} {f['side']:9} {f['id']}: {f['title']}"
                  + (f" - {f['detail']}" if f.get("detail") else ""), flush=True)

    def flush(self, force=False):
        if not (self.dirty and (force or time.time() - self.flushed >= FLUSH_S)):
            return
        os.makedirs(self.dir, exist_ok=True)
        base = os.path.join(self.dir, self.stamp)
        write_atomic(base + ".json", json.dumps(self.data, indent=1, ensure_ascii=False))
        write_atomic(base + ".md", render_md(self.data))
        self.dirty, self.flushed = False, time.time()

    def ranked(self):
        return sorted(self.data["findings"].values(), key=lambda f: (-SEV_RANK[f["severity"]], -f["count"]))


def write_atomic(path, text):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    for _ in range(20):  # Windows: a reader (editor, AV scan) may hold the target for a moment
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.05)
    os.replace(tmp, path)


def render_md(d):
    fs = sorted(d["findings"].values(), key=lambda f: (-SEV_RANK[f["severity"]], -f["count"]))
    out = [f"# Session watch {d['started']}" + (f" to {d['ended']}" if d.get("ended") else " (running)"),
           f"{d['label']} | reviewed: {'yes' if d.get('reviewed') else 'no'}", "",
           "Sources: " + ", ".join(d["sources"]), ""]
    if not fs:
        out.append("No problems seen.")
    else:
        out += ["| id | severity | count | first | last | side | category | finding |", "|---|---|---|---|---|---|---|---|"]
        for f in fs:
            title = f["title"] + (f" ({f['detail']})" if f.get("detail") else "")
            out.append(f"| {f['id']} | {f['severity']} | {f['count']} | {f['first']} | {f['last']} | {f['side']} | "
                       f"{f['category']} | {title.replace('|', '/')} |")
        out.append("")
        for f in fs:
            if SEV_RANK[f["severity"]] < SEV_RANK["medium"]:
                continue
            out += [f"## {f['id']} {f['severity'].upper()} {f['title']}", f"`{f['source']}` first {f['first']}, "
                    f"{f['count']}x, last {f['last']}", "", "```", *f["context"], "```", ""]
    if d["events"]:
        out += ["## Events", *[f"- {e}" for e in d["events"][-40:]]]
    return "\n".join(out) + "\n"


class Detectors:
    """Per-line checks. State is per side (main / guest-kit) so the two installs never mix."""

    def __init__(self, nb):
        self.nb = nb
        self.ctx = collections.defaultdict(lambda: collections.deque(maxlen=CONTEXT_LINES))
        self.last_t = {}        # side -> seconds of day of the last mod line
        self.last_link = {}     # side -> seconds of day of the last link stats line
        self.rtt_run = collections.Counter()
        self.counters = {}      # (side, key) -> last value
        self.mem0 = {}

    def hit(self, side, sev, cat, title, text, src, at, extra=None):
        rep = re.search(r"\(x(\d+) in \d+ s\)", text)  # the mod collapses repeats: one line = N occurrences
        return self.nb.hit(side, sev, cat, title, text, src, list(self.ctx[(side, src)]), at, extra,
                           int(rep.group(1)) if rep else 1)

    # ---- mod log (mirror_log.txt)
    def mod_line(self, side, src, raw):
        m = LINE_RE.match(raw)
        if not m:
            return
        h, mi, s, level, text = m.groups()
        t, at = secs(h, mi, s), f"{h}:{mi}:{s}"
        prev = self.last_t.get(side)
        if prev is not None:
            gap = (t - prev) % 86400
            if gap >= LOG_GAP_S and (prev - self.last_link.get(side, -10**6)) % 86400 <= IN_SESSION_S:
                self.hit(side, "high", "freeze", "Mod log went silent mid-session (game froze or hitched)",
                         f"gap {gap} s before {at}", src, at, f"{gap} s")
        self.last_t[side] = t
        if text.startswith("phase1"):
            self.last_link[side] = t
            self.link_stats(side, src, text, at)
        for rx, sev, cat, title in KNOWN:
            if rx.search(text):
                short = re.sub(r"\S*[\\/]Scripts[\\/]mirror[\\/]|\s*\(x\d+ in \d+ s\)", "", text)
                lua = re.search(r"safe\(\) caught in ([\w.]+):\s*(.*)$", short)
                if lua:  # lead with the error itself: "Lua error in session.recover: link_file.lua:60: ..."
                    short = f"in {lua.group(1)}: {lua.group(2)}"
                self.hit(side, sev, cat, (f"Lua error {short}" if lua else f"{title}: {short}")[:140]
                         if cat in GENERIC else title, text, src, at)
                break
        else:
            if level == "ERROR":
                self.hit(side, "high", "mod-error", text[:90], text, src, at)
            elif level == "WARN":
                self.hit(side, "medium", "mod-warn", text[:90], text, src, at)
        self.ctx[(side, src)].append(raw)

    def link_stats(self, side, src, text, at):
        def num(rx):
            m = re.search(rx, text)
            return float(m.group(1)) if m else None
        rtt = num(r"net round trip (\d+) ms")
        if rtt is not None:
            self.rtt_run[side] = self.rtt_run[side] + 1 if rtt > RTT_MS else 0
            if self.rtt_run[side] >= RTT_RUN:
                self.hit(side, "medium", "metric", "Network round trip high", text, src, at, f"{int(rtt)} ms")
        skip = num(r"poses \d+/s \((\d+)% skipped")
        if skip is not None and skip > SKIP_PCT:
            self.hit(side, "medium", "metric", "Many pose packets skipped", text, src, at, f"{int(skip)}%")
        last_rx = num(r"last rx ([\d.]+) s")
        if last_rx is not None and last_rx > STALE_RX_S:
            self.hit(side, "medium", "metric", "Nothing received from the other game", text, src, at, f"{last_rx:.1f} s")
        hb = num(r"peer_hb (-?[\d.]+)")
        if hb is not None and hb > PEER_HB_S:
            self.hit(side, "high", "metric", "Other game's heartbeat stale", text, src, at, f"{hb:.1f} s")
        q = re.search(r"queued (\d+) (B|KB|MB)", text)
        if q and int(q.group(1)) * {"B": 1, "KB": 1 << 10, "MB": 1 << 20}[q.group(2)] > QUEUE_BYTES:
            self.hit(side, "medium", "metric", "Send queue backing up", text, src, at, f"{q.group(1)} {q.group(2)}")
        rx = num(r"^phase1\[\w+\]: rx ([\d.]+)/s")
        if rx is not None and rx < RX_MIN:
            self.hit(side, "medium", "metric", "Low receive rate from the other game", text, src, at, f"{rx}/s")
        if text.startswith("phase1["):
            self.counters_rise(side, src, text, at)

    def counters_rise(self, side, src, text, at):
        head = "?"
        for seg in text.split(" | "):
            if ":" in seg.split(",")[0]:
                head = seg.split(":")[0].strip()[-30:]
            pairs = [(w, int(n)) for w, n in COUNTER_RE.findall(seg)] + [(w, int(n)) for n, w in COUNTER_PAREN_RE.findall(seg)]
            for word, n in pairs:
                key = (side, f"{head} {word}")
                old = self.counters.get(key)
                self.counters[key] = n
                if old is not None and n > old:
                    f = self.hit(side, COUNTER_SEV.get(word, "medium"), "counter", f"{head}: '{word}' counter rising",
                                 seg.strip(), src, at)
                    f.setdefault("from", old)  # where it stood when it first rose this session
                    f["detail"] = f"{f['from']} -> {n}"

    # ---- UE4SS.log
    def ue4ss_line(self, side, src, raw):
        if UE4SS_BAD.search(raw) and not UE4SS_NOISE.search(raw):
            text = re.sub(r"^\[[\d\-: .]+\]\s*", "", raw)
            sev = "critical" if re.search(r"Fatal Error|AOB scans could not", raw, re.I) else "high"
            self.hit(side, sev, "ue4ss", text[:90], text, src, now_s())
        self.ctx[(side, src)].append(raw)

    # ---- bridge log (mirror_bridge*.log)
    def bridge_line(self, src, raw):
        m = BRIDGE_RE.match(raw)
        at, text = (f"{m.group(1)}:{m.group(2)}:{m.group(3)}", m.group(4)) if m else (now_s(), raw)
        # (a stall in the game's first minute is the game starting: GameWatch.WhileStarting)
        if "watch: the game stopped responding" in text and "while the game starts" not in text:
            self.hit("bridge", "critical", "freeze", "Game stopped responding (GameWatch)", text, src, at)
        elif text.startswith("watch: game "):
            self.bridge_health(src, text, at)
        elif BRIDGE_BAD.search(text):
            self.hit("bridge", "medium", "bridge", text[:90], text, src, at)
        self.ctx[("bridge", src)].append(raw)

    def bridge_health(self, src, text, at):
        mem = re.search(r"game (\d+) MB private", text)
        if mem:
            mb = int(mem.group(1))
            base = self.mem0.setdefault(src, mb)
            if mb - base > MEM_GROWTH_MB:
                self.hit("bridge", "medium", "memory", "Game memory grew a lot this session", text, src, at,
                         f"{base} -> {mb} MB")
        ram = re.search(r"RAM ([\d.]+)/[\d.]+ GB free", text)
        if ram and float(ram.group(1)) < RAM_FREE_GB:
            self.hit("bridge", "high", "memory", "PC almost out of free RAM", text, src, at, f"{ram.group(1)} GB free")
        com = re.search(r"commit ([\d.]+) of ([\d.]+) GB used", text)
        if com and float(com.group(1)) / max(float(com.group(2)), 0.1) > COMMIT_FRAC:
            self.hit("bridge", "high", "memory", "Windows commit limit nearly reached", text, src, at,
                     f"{com.group(1)} of {com.group(2)} GB")


def crash_message(crash_dir):
    for name in ("CrashContext.runtime-xml",):
        try:
            with open(os.path.join(crash_dir, name), encoding="utf-8", errors="replace") as f:
                m = re.search(r"<ErrorMessage>([^<]*)</ErrorMessage>", f.read())
                if m:
                    return re.sub(r"\s+", " ", m.group(1)).strip()
        except OSError:
            pass
    return "(no error message in the crash folder)"


class Watcher:
    def __init__(self, nb, games, from_start):
        self.nb, self.det = nb, Detectors(nb)
        self.tails = []
        for side, win64 in games:
            self.tails.append(("mod", side, Tail(os.path.join(win64, "mirror_log.txt"), not from_start)))
            self.tails.append(("ue4ss", side, Tail(os.path.join(win64, "ue4ss", "UE4SS.log"), not from_start)))
        self.from_start, self.polled = from_start, False
        self.bridge = {}
        self.crash_dirs = [os.path.join(LOCAL, s, "Crashes") for s in ("Saved", "Saved_Guest")]
        self.hang_dir = os.path.join(APPDIR, "hangs")
        self.seen = {d: set(self.listing(d)) for d in self.crash_dirs + [self.hang_dir]}
        nb.data["sources"] = [t.path for _, _, t in self.tails] + [os.path.join(LOCAL, "mirror_bridge*.log")] \
            + self.crash_dirs + [self.hang_dir]

    @staticmethod
    def listing(d):
        try:
            return os.listdir(d)
        except OSError:
            return []

    def poll(self):
        for kind, side, tail in self.tails:
            lines, rotated = tail.read()
            if rotated:
                self.nb.event(f"{side}: {os.path.basename(tail.path)} restarted (new game run)")
                self.det.last_t.pop(side, None)
            for ln in lines:
                (self.det.mod_line if kind == "mod" else self.det.ue4ss_line)(side, os.path.basename(tail.path), ln)
        for p in glob.glob(os.path.join(LOCAL, "mirror_bridge*.log")):
            if p not in self.bridge:  # a log that appears later is read from its first line
                self.bridge[p] = Tail(p, not self.from_start and not self.polled)
            for ln in self.bridge[p].read()[0]:
                self.det.bridge_line(os.path.basename(p), ln)
        for d in self.crash_dirs:
            for name in set(self.listing(d)) - self.seen[d]:
                self.seen[d].add(name)
                msg = crash_message(os.path.join(d, name))
                self.det.hit("game", "critical", "crash", "The game crashed", f"{name}: {msg}", d, now_s(), name)
        for name in set(self.listing(self.hang_dir)) - self.seen[self.hang_dir]:
            self.seen[self.hang_dir].add(name)
            if name.endswith(".txt"):
                try:
                    with open(os.path.join(self.hang_dir, name), encoding="utf-8", errors="replace") as f:
                        note = f.read().strip()
                except OSError:
                    note = name
                self.det.hit("game", "critical", "freeze", "The game froze (hang dump written)", note, self.hang_dir,
                             now_s(), name)
        self.polled = True
        self.nb.flush()


def find_games(extra):
    games = [(side, os.path.join(STEAM, folder, "SurrounDead", "Binaries", "Win64")) for side, folder in INSTALLS.items()]
    games += [(os.path.basename(os.path.normpath(g)), os.path.join(g, "SurrounDead", "Binaries", "Win64")) for g in extra]
    return [(s, w) for s, w in games if os.path.isdir(w)]


def cmd_watch(a):
    games = find_games(a.game or [])
    if not games:
        sys.exit(f"no SurrounDead install found under {STEAM} (pass --game <game folder>)")
    nb = Notebook("live: " + ", ".join(s for s, _ in games))
    w = Watcher(nb, games, a.from_start)
    nb.event(f"watching {len(w.tails)} game logs + bridge, crash and hang folders; notes: "
             f"{os.path.join(nb.dir, nb.stamp)}.md")
    t0 = time.time()
    try:
        while True:
            w.poll()
            if a.seconds and time.time() - t0 >= a.seconds:
                break
            time.sleep(POLL_S)
    except KeyboardInterrupt:
        pass
    finish(nb)


def finish(nb):
    nb.data["ended"] = time.strftime("%Y-%m-%d %H:%M:%S")
    nb.flush(force=True)
    fs = nb.ranked()
    by = collections.Counter(f["severity"] for f in fs)
    print(f"\n{len(fs)} finding(s): " + (", ".join(f"{by[s]} {s}" for s in ("critical", "high", "medium", "low") if by[s]) or "none")
          + f"\nnotes: {os.path.join(nb.dir, nb.stamp)}.md")


def cmd_replay(a):
    nb = Notebook("replay: " + ", ".join(os.path.basename(p) for p in a.files), quiet=a.quiet)
    det = Detectors(nb)
    nb.data["sources"] = list(a.files)
    for p in a.files:
        name = os.path.basename(p)
        det.last_t.clear()  # each file is its own game run: no "gap" across files
        det.last_link.clear()
        kind = "bridge" if "bridge" in name else "ue4ss" if "ue4ss" in name.lower() else "mod"
        with open(p, encoding="utf-8", errors="replace") as f:
            for ln in f:
                ln = ln.rstrip("\r\n")
                if kind == "mod":
                    det.mod_line("replay", name, ln)
                elif kind == "ue4ss":
                    det.ue4ss_line("replay", name, ln)
                else:
                    det.bridge_line(name, ln)
    finish(nb)
    if not a.quiet:
        for f in nb.ranked()[:25]:
            print(f"  {f['id']:4} {f['severity']:8} {f['count']:5}x {f['category']:9} {f['title']}"
                  + (f" ({f['detail']})" if f.get("detail") else ""))


def sessions():
    out = []
    for p in sorted(glob.glob(os.path.join(NOTES, "sessions", "*.json"))):
        try:
            with open(p, encoding="utf-8") as f:
                out.append((p, json.load(f)))
        except (OSError, ValueError):
            continue
    return out


def cmd_report(a):
    shown = 0
    for p, d in sessions():
        if d.get("reviewed") and not a.all:
            continue
        fs = sorted(d["findings"].values(), key=lambda f: (-SEV_RANK[f["severity"]], -f["count"]))
        fs = [f for f in fs if SEV_RANK[f["severity"]] >= SEV_RANK[a.min]]
        if not fs:
            continue
        shown += 1
        print(f"{d['session']}  {d['label']}  {d['started']} - {d.get('ended') or 'running'}"
              f"{'  (reviewed)' if d.get('reviewed') else ''}\n  notes: {p[:-5]}.md")
        for f in fs:
            print(f"  {f['id']:4} {f['severity']:8} {f['count']:5}x {f['side']:9} {f['category']:9} {f['title']}"
                  + (f" ({f['detail']})" if f.get("detail") else ""))
    if not shown:
        print("nothing to review" + ("" if a.all else " (--all includes reviewed sessions)"))


def cmd_ack(a):
    n = 0
    for p, d in sessions():
        if a.session in ("all", d["session"]) and not d.get("reviewed"):
            d["reviewed"] = True
            write_atomic(p, json.dumps(d, indent=1, ensure_ascii=False))
            write_atomic(p[:-5] + ".md", render_md(d))
            n += 1
    print(f"marked {n} session(s) reviewed")


def main():
    p = argparse.ArgumentParser(description="watch a live SurrounSync session and note anything wrong")
    sp = p.add_subparsers(dest="cmd")
    w = sp.add_parser("watch", help="follow the live logs (default)")
    for q in (p, w):
        q.add_argument("--game", action="append", help="extra game folder (contains SurrounDead\\Binaries)")
        q.add_argument("--from-start", action="store_true", help="also read what the current logs already hold")
        q.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl+C)")
    r = sp.add_parser("replay", help="run the detectors over old log files")
    r.add_argument("files", nargs="+")
    r.add_argument("--quiet", action="store_true")
    rp = sp.add_parser("report", help="findings not reviewed yet")
    rp.add_argument("--all", action="store_true")
    rp.add_argument("--min", default="low", choices=list(SEV_RANK))
    ak = sp.add_parser("ack", help="mark a session (or all) reviewed")
    ak.add_argument("session")
    a = p.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    {"replay": cmd_replay, "report": cmd_report, "ack": cmd_ack}.get(a.cmd, cmd_watch)(a)


if __name__ == "__main__":
    main()
