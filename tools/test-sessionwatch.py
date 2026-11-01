"""tools/sessionwatch.py: injected faults in fake host/guest installs are each noted once, counted, persisted and
reviewable; noise and normal play are not; the game folders are never written.

    python tools/test-sessionwatch.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "sessionwatch.py")
TMP = tempfile.mkdtemp(prefix="sessionwatch-test-")
os.environ["SESSIONWATCH_DIR"] = os.path.join(TMP, "notes")
spec = importlib.util.spec_from_file_location("sessionwatch", TOOL)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def append(path, *lines, newline=True):
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if newline else ""))


def mod(t, level, text):
    return f"{t} [SurrounSync][{level}] {text}"


def link(t, rtt=200, hb=0.0, failed=0, missing=0):
    return mod(t, "INFO", f"phase1[host]: rx 23.0/s, last 0.00s ago | death bags: sent 0, copies 0 (failed {failed}) | "
                          f"corpse loot: corpses checked 10 ({missing} items missing)") + "\n" + \
        mod(t, "INFO", f"phase1: link bridge host: me 1, peer P (2), last rx 0.0 s, peer_hb {hb} peer_game alive rtt {rtt} ms "
                       f"route direct queued 0 B slot 1") + "\n" + \
        mod(t, "INFO", f"phase1: net round trip {rtt} ms, poses 23/s (0% skipped, 0 recovered)")


def by_title(nb, part):
    return [f for f in nb.data["findings"].values() if part in f["title"]]


try:
    steam = os.path.join(TMP, "steam")
    local, app = os.path.join(TMP, "local", "SurrounDead"), os.path.join(TMP, "local", "SurrounSync")
    sw.STEAM, sw.LOCAL, sw.APPDIR = steam, local, app
    games = {}
    for side, folder in sw.INSTALLS.items():
        w = os.path.join(steam, folder, "SurrounDead", "Binaries", "Win64")
        os.makedirs(os.path.join(w, "ue4ss"))
        append(os.path.join(w, "mirror_log.txt"), mod("09:00:00", "ERROR", "old run error, before the watch started"))
        append(os.path.join(w, "ue4ss", "UE4SS.log"), "[2026-10-30 00:14:35.9] UWorld::bKismetScriptError = 0x18D")
        games[side] = w
    for d in ("Saved", "Saved_Guest"):
        os.makedirs(os.path.join(local, d, "Crashes"))
    os.makedirs(os.path.join(app, "hangs"))
    append(os.path.join(local, "mirror_bridge.log"), "09:00:00 bridge started")
    before = {p: os.path.getsize(os.path.join(dp, p)) for dp, _, fs in os.walk(steam) for p in fs}

    found = sw.find_games([])
    check([s for s, _ in found] == ["main", "guest-kit"], "both installs found (main + guest kit)")
    nb = sw.Notebook("test", quiet=True)
    w = sw.Watcher(nb, found, from_start=False)
    w.poll()
    check(not nb.data["findings"], "starts at the end: errors from before the watch are not reported")

    H, G = os.path.join(games["main"], "mirror_log.txt"), os.path.join(games["guest-kit"], "mirror_log.txt")
    append(H, link("10:00:00"), mod("10:00:01", "ERROR", "split: merge answer missing for epoch 3"))
    append(H, mod("10:00:02", "WARN", "builds: the other player's DA_Fence goes 12 cm from one of the same kind already here"),
           mod("10:00:03", "WARN", "builds: the other player's DA_Wall goes 40 cm from one of the same kind already here"))
    append(H, mod("10:00:04", "WARN", "safe() caught in session.recover: link_file.lua:60: attempt to concatenate a nil value (local 'who')"),
           mod("10:00:14", "WARN", "safe() caught in session.recover (x40 in 10 s): link_file.lua:60: attempt to concatenate a nil value (local 'who')"),
           mod("10:00:15", "WARN", "safe() caught in zombies.tick: zombies.lua:88: attempt to index a nil value (field 'mesh')"))
    append(G, mod("10:00:05", "WARN", "notify: Lost connection to K3YBOARD32."))
    w.poll()
    check(len(by_title(nb, "merge answer missing")) == 1 and by_title(nb, "merge answer")[0]["severity"] == "high",
          "mod ERROR line -> high finding")
    dup = by_title(nb, "Duplicate building")
    check(len(dup) == 1 and dup[0]["count"] == 2, "same known problem with different numbers/names -> one finding, count 2")
    lua = [f for f in nb.data["findings"].values() if f["category"] == "lua-error"]
    who = [f for f in lua if "'who'" in f["title"]]
    check(len(lua) == 2 and len(who) == 1, "two different Lua errors stay two findings, the repeated one stays one")
    check(who and who[0]["count"] == 41, "a collapsed '(x40 in 10 s)' line counts 40 occurrences")
    lost = by_title(nb, "Lost connection")
    check(len(lost) == 1 and lost[0]["severity"] == "critical" and lost[0]["side"] == "guest-kit",
          "Lost connection -> critical, attributed to the guest install")
    check(who and any("merge answer missing" in c for c in who[0]["context"]), "a finding keeps the lines that led up to it")

    append(H, link("10:00:20", rtt=700), link("10:00:25", rtt=720))
    w.poll()
    check(not by_title(nb, "round trip"), "two slow samples are not yet a finding")
    append(H, link("10:00:30", rtt=750, hb=9.0, failed=2, missing=3))
    w.poll()
    rtt = by_title(nb, "round trip")
    check(len(rtt) == 1 and rtt[0]["detail"] == "750 ms", "third slow sample in a row -> latency finding with the value")
    check(by_title(nb, "heartbeat stale") and by_title(nb, "heartbeat stale")[0]["severity"] == "high", "peer heartbeat 9 s -> high")
    rise = by_title(nb, "'failed' counter rising")
    check(len(rise) == 1 and rise[0]["detail"] == "0 -> 2", "a failure counter rising mid-session -> finding 0 -> 2")
    append(H, link("10:00:35", failed=5, missing=3))
    w.poll()
    check(by_title(nb, "'failed' counter rising")[0]["detail"] == "0 -> 5", "counter finding tracks from its first value")

    append(H, mod("10:01:30", "INFO", "split: answer 4"))
    w.poll()
    gap = [f for f in nb.data["findings"].values() if f["category"] == "freeze"]
    check(len(gap) == 1 and gap[0]["detail"] == "55 s", "55 s of silence right after link stats -> freeze finding")
    append(H, mod("10:05:00", "INFO", "menu: opened"))
    w.poll()
    check(len([f for f in nb.data["findings"].values() if f["category"] == "freeze"]) == 1 and
          [f for f in nb.data["findings"].values() if f["category"] == "freeze"][0]["count"] == 1,
          "a quiet stretch outside a session (no link stats before it) is not a freeze")
    append(G, link("23:59:50"), mod("00:00:05", "INFO", "after midnight"))
    w.poll()
    check(not [f for f in nb.data["findings"].values() if f["category"] == "freeze" and f["side"] == "guest-kit"],
          "15 s across midnight is not a 24 h gap")

    UL = os.path.join(games["main"], "ue4ss", "UE4SS.log")
    append(UL, "[2026-10-30 10:02:00.1] FArchiveState::ArIsCriticalError = 0x29",
           "[2026-10-30 10:02:01.1] [Lua] error in mirror/main.lua: stack traceback:",
           "[2026-10-30 10:02:02.1] Fatal Error: AOB scans could not be completed")
    w.poll()
    ue = [f for f in nb.data["findings"].values() if f["category"] == "ue4ss"]
    check(len(ue) == 2 and not any("0x29" in f["sample"] for f in ue), "UE4SS: errors caught, startup offset dumps ignored")
    check(any(f["severity"] == "critical" and "Fatal" in f["sample"] for f in ue), "UE4SS Fatal Error -> critical")

    append(H, mod("10:03:00", "INFO", "partial line wi"), newline=False)
    w.poll()
    check(not any("partial line" in f["sample"] for f in nb.data["findings"].values()), "a half-written line waits")
    append(H, "thout end", mod("10:03:01", "ERROR", "the end of a partial line"))
    w.poll()
    check(by_title(nb, "the end of a partial line"), "the rest of a line arriving later is read whole")

    with open(H, "w", encoding="utf-8") as f:  # the game restarted: the log starts over
        f.write(mod("11:00:00", "ERROR", "first error of the new run") + "\n")
    w.poll()
    check(by_title(nb, "first error of the new run") and any("restarted" in e for e in nb.data["events"]),
          "a restarted log is read from its first line and noted as a new game run")

    crash = os.path.join(local, "Saved", "Crashes", "UECC-Windows-ABC_0000")
    os.makedirs(crash)
    with open(os.path.join(crash, "CrashContext.runtime-xml"), "w", encoding="utf-8") as f:
        f.write("<x><ErrorMessage>Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x18</ErrorMessage></x>")
    with open(os.path.join(app, "hangs", "hang-20261030-110000-1.txt"), "w", encoding="utf-8") as f:
        f.write("frozen 30 s | mod step: 10:59:58 session")
    append(os.path.join(local, "mirror_bridge.log"),
           "11:00:00 watch: game 3000 MB private, 2000 MB in RAM | RAM 9.0/31.8 GB free, commit 30.0 of 50.0 GB used",
           "11:30:00 watch: game 6500 MB private, 5000 MB in RAM | RAM 1.5/31.8 GB free, commit 48.0 of 50.0 GB used",
           "11:30:05 watch: the game stopped responding (8 s)",
           "11:40:00 watch: the game stopped responding while the game starts - RAM 3.8/15.9 GB free")
    w.poll()
    append(os.path.join(local, "mirror_bridge_guest.log"), "11:31:00 P2P session failed, error 4")
    w.poll()
    check(any("P2P session failed" in f["sample"] for f in nb.data["findings"].values()),
          "a bridge log that appears after the start is read from its first line")
    cr = [f for f in nb.data["findings"].values() if f["category"] == "crash"]
    check(len(cr) == 1 and cr[0]["severity"] == "critical" and "ACCESS_VIOLATION" in cr[0]["sample"],
          "new crash folder -> critical with the game's error message")
    check(by_title(nb, "hang dump") and "frozen 30 s" in by_title(nb, "hang dump")[0]["sample"], "new hang note -> critical")
    check(by_title(nb, "stopped responding"), "GameWatch 'stopped responding' -> critical")
    check(not any("while the game starts" in f["sample"] for f in nb.data["findings"].values()),
          "a stall while the game starts is not a freeze")
    mem = by_title(nb, "memory grew")
    check(mem and mem[0]["detail"] == "3000 -> 6500 MB", "game memory growth over the session noted with values")
    check(by_title(nb, "out of free RAM") and by_title(nb, "commit limit"), "low free RAM and commit near limit -> high")

    nb.flush(force=True)
    base = os.path.join(nb.dir, nb.stamp)
    d = json.load(open(base + ".json", encoding="utf-8"))
    md = open(base + ".md", encoding="utf-8").read()
    check(len(d["findings"]) == len(nb.data["findings"]) and "Lost connection" in md and "| critical |" in md,
          "notes persisted: JSON + readable Markdown with the findings")
    after = {p: os.path.getsize(os.path.join(dp, p)) for dp, _, fs in os.walk(steam) for p in fs}
    check(set(after) == set(before), "read-only: no file created in the game folders")

    def run(*args):
        r = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, SESSIONWATCH_DIR=os.path.join(TMP, "notes")))
        return r.returncode, r.stdout + r.stderr
    rc, out = run("report", "--min", "critical")
    check(rc == 0 and "Lost connection" in out and "Duplicate building" not in out, "report lists unreviewed, filtered by severity")
    rc, out = run("ack", "all")
    check("marked 1 session" in out, "ack marks the session reviewed")
    rc, out = run("report")
    check("nothing to review" in out, "reviewed sessions drop out of the report")

    real = os.path.join(sw.STEAM.replace(steam, r"C:\Program Files (x86)\Steam\steamapps\common"), "SurrounDead",
                        "SurrounDead", "Binaries", "Win64", "mirror_log.txt")
    if os.path.exists(real):
        t0 = time.perf_counter()
        rc, out = run("replay", real, "--quiet")
        dt = time.perf_counter() - t0
        check(rc == 0 and "finding(s)" in out and "Traceback" not in out, f"replay of the real host log runs clean ({dt:.1f} s)")
    else:
        print("  skip real-log replay (no install on this PC)")
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{'ALL PASSED' if not fails else f'{len(fails)} FAILED: ' + '; '.join(fails)}")
sys.exit(1 if fails else 0)
