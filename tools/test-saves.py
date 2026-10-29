"""Save-safety tests. Runs the mod's real Lua (savefs, backups, slotguard, session) against a temp
SaveGames folder, including simulated crashes and failed file operations.

    pip install --target <dir> lupa, set PYTHONPATH=<dir>, then: python tools/test-saves.py [name-prefix]
"""
import os, shutil, sys, tempfile, time

try:
    from lupa import lua54
except ImportError:
    print("needs lupa (Lua 5.4 for Python): pip install --target <dir> lupa, then set PYTHONPATH=<dir>")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
fails = []
TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


RUNTIME_LUA = r'''
        local scripts, tmp = ...
        package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
        TMP = tmp
        LOG = {}
        local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
        package.preload["mirror.log"] = function()
            return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end,
                     trace = function() end, configure = function() end }
        end
        function log_has(lvl, pat)
            for _, l in ipairs(LOG) do if l:find("^" .. lvl) and l:find(pat, 1, true) then return true end end
            return false
        end
        REAL = { open = io.open, rename = os.rename, remove = os.remove }
        CALLS = 0
        -- the n-th call of io.open/os.rename/os.remove fails ("fail") or raises ("die"); n = 0: just count
        function inject(n, mode)
            CALLS = 0
            local function wrap(name, real)
                return function(...)
                    CALLS = CALLS + 1
                    if CALLS == n then
                        if mode == "die" then error("CRASH") end
                        return nil, "Permission denied"
                    end
                    return real(...)
                end
            end
            io.open = wrap("open", REAL.open)
            os.rename = wrap("rename", REAL.rename)
            os.remove = wrap("remove", REAL.remove)
        end
        function uninject() io.open, os.rename, os.remove = REAL.open, REAL.rename, REAL.remove end
        savefs = require("mirror.savefs")
        savefs.set_dir_backend(DIRS)
'''


def dir_backend(L):
    def mkdir(p):
        os.makedirs(p, exist_ok=True)
        return True

    def list_dirs(p):
        if not os.path.isdir(p):
            return None
        return L.table_from(sorted(d for d in os.listdir(p) if os.path.isdir(os.path.join(p, d))))

    def rmdir(p):
        shutil.rmtree(p, ignore_errors=True)
        return not os.path.exists(p)

    def rmdir_empty(p):
        try:
            os.rmdir(p)          # fails on a folder with anything in it, like UE's DeleteDirectory(p, false, false)
        except OSError:
            return False
        return True
    return L.table_from({"mkdir": mkdir, "list_dirs": list_dirs, "rmdir": rmdir, "rmdir_empty": rmdir_empty})


def fresh(tmp):
    L = lua54.LuaRuntime(unpack_returned_tuples=True)
    L.globals().DIRS = dir_backend(L)
    L.execute(RUNTIME_LUA, SCRIPTS, tmp)
    return L


def read(p):
    with open(p, "rb") as f:
        return f.read()


def write(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)


def leftovers(path):
    return [x for x in (path + ".mirror-new", path + ".mirror-old") if os.path.exists(x)]


@test
def savefs_crc32(L, tmp):
    check(L.eval('savefs.crc32("123456789")') == "cbf43926", "crc32 of the standard check string")
    check(L.eval('savefs.crc32("")') == "00000000", "crc32 of nothing")
    big = bytes(range(256)) * 600
    t = time.time()
    L.globals().BIG = big
    L.eval('savefs.crc32(BIG)')
    ms = (time.time() - t) * 1000
    check(ms < 200, "crc32 of 150 KB in %.0f ms" % ms)


@test
def savefs_write_new_and_overwrite(L, tmp):
    p = os.path.join(tmp, "SaveGames", "S", "Level.sav")
    os.makedirs(os.path.dirname(p))
    ok = L.eval('savefs.write(...)', p, b"one")
    check(ok is True and read(p) == b"one", "write creates a new file")
    ok = L.eval('savefs.write(...)', p, b"two")
    check(ok is True and read(p) == b"two" and not leftovers(p), "overwrite replaces it, no temp files left")


def every_call(L, tmp, body):
    """Run body(L, p) with the n-th file call failing / dying for every n; return list of problems."""
    p = os.path.join(tmp, "SaveGames", "S", "Player.sav")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    write(p, b"OLD")
    L.execute('inject(0)')
    body(L, p)
    total = L.eval('CALLS')
    L.execute('uninject()')
    bad = []
    for mode in ("fail", "die"):
        for n in range(1, total + 1):
            write(p, b"OLD")
            for x in leftovers(p):
                os.remove(x)
            L.execute('inject(...)', n, mode)
            try:
                body(L, p)
            except Exception:
                pass
            L.execute('uninject()')
            if mode == "die":
                L.eval('savefs.repair(...)', p)
            got = read(p) if os.path.exists(p) else None
            if got not in (b"OLD", b"NEW") or (mode == "die" and leftovers(p)):
                bad.append("%s at call %d -> %r %s" % (mode, n, got, leftovers(p)))
    return total, bad


@test
def savefs_crash_at_every_step(L, tmp):
    total, bad = every_call(L, tmp, lambda L, p: L.eval('savefs.write(...)', p, b"NEW"))
    check(total >= 5 and not bad, "write: every failing/dying file call leaves old or new (%d calls) %s" % (total, bad[:3]))


@test
def savefs_fail_returns_false_and_keeps_old(L, tmp):
    p = os.path.join(tmp, "SaveGames", "S", "Player.sav")
    write(p, b"OLD")
    L.execute('inject(0)'); L.eval('savefs.write(...)', p, b"NEW"); total = L.eval('CALLS'); L.execute('uninject()')
    results = []
    for n in range(1, total + 1):
        write(p, b"OLD")
        L.execute('inject(...)', n, "fail")
        ok = L.eval('savefs.write(...)', p, b"NEW")
        L.execute('uninject()')
        ok = ok[0] if isinstance(ok, tuple) else ok
        results.append((ok, read(p)))
    check(all((ok is True and d == b"NEW") or (ok is False and d == b"OLD") for ok, d in results),
          "a failed call returns false with the old file, a true return means the new file")


@test
def savefs_short_write_rejected(L, tmp):
    p = os.path.join(tmp, "SaveGames", "S", "Player.sav")
    write(p, b"OLD")
    L.execute(r'''
        io.open = function(path, mode)
            local f, e = REAL.open(path, mode)
            if not f or not mode:find("w") then return f, e end
            return { write = function(self, d) f:write(d:sub(1, #d // 2)) return self end,
                     close = function() f:close() end }
        end
    ''')
    ok = L.eval('savefs.write(...)', p, b"NEWNEWNEW")
    L.execute('uninject()')
    ok = ok[0] if isinstance(ok, tuple) else ok
    check(ok is False and read(p) == b"OLD" and not leftovers(p), "short write: false, original intact, no temp files")


@test
def savefs_repair_table(L, tmp):
    d = os.path.join(tmp, "SaveGames", "S")
    a = os.path.join(d, "A.sav"); write(a, b"new"); write(a + ".mirror-old", b"old")
    b = os.path.join(d, "B.sav"); write(b + ".mirror-old", b"old")
    c = os.path.join(d, "C.sav"); write(c, b"cur"); write(c + ".mirror-new", b"half")
    for x in (a, b, c):
        L.eval('savefs.repair(...)', x)
    check(read(a) == b"new" and not leftovers(a), "X + old: old removed")
    check(read(b) == b"old" and not leftovers(b), "old only: renamed back to X")
    check(read(c) == b"cur" and not leftovers(c), "new: removed")


@test
def fs_refuses_save_folders(L, tmp):
    p = os.path.join(tmp, "SaveGames", "S", "Level.sav")
    os.makedirs(os.path.dirname(p))
    ok = L.eval('require("mirror.fs").write(...)', p, b"x")
    check(ok is False and not os.path.exists(p) and L.eval('log_has("ERROR", "save folder")'),
          "fs.write refuses a path in SaveGames and logs an error")
    q = os.path.join(tmp, "MirrorBackups", "x.txt")
    os.makedirs(os.path.dirname(q))
    ok = L.eval('require("mirror.fs").copy(...)', p, q)
    check(ok is False, "fs.copy refuses the backup store")
    q2 = os.path.join(tmp, "SurrounSyncBackups", "x.txt")
    os.makedirs(os.path.dirname(q2))
    check(L.eval('require("mirror.fs").write(...)', q2, b"x") is False and not os.path.exists(q2),
          "fs.write refuses the backup store under its new name too")
    r = os.path.join(tmp, "mirror_link_host.txt")
    check(L.eval('require("mirror.fs").write(...)', r, b"ok") is True, "fs.write still works elsewhere")


@test
def savefs_dirs(L, tmp):
    p = os.path.join(tmp, "MirrorBackups", "S", "x y")
    check(L.eval('savefs.mkdir(...)', p) is True and os.path.isdir(p), "mkdir makes the whole tree")
    names = L.eval('savefs.list_dirs(...)', os.path.join(tmp, "MirrorBackups", "S"))
    check(names is not None and list(names.values()) == ["x y"], "list_dirs lists folder names")
    check(L.eval('savefs.rmdir(...)', p) is True and not os.path.exists(p), "rmdir removes it")


@test
def savefs_non_ascii_user_name(L, tmp):
    # report 2026-10-25: user "C:\Users\<cyrillic>" - Lua hands UE ANSI bytes, MakeDirectory fails, no join
    ansi, ue = b"C:\\Users\\\xc0\xf0\\AppData\\Local", "C:\\Users\\Ар\\AppData\\Local".encode("utf-8")
    L.execute('''
        SEEN = {}
        savefs.set_dir_backend{ mkdir = function(p) SEEN[#SEEN + 1] = p; return true end,
            list_dirs = function(p) SEEN[#SEEN + 1] = p; return {} end,
            rmdir = function(p) SEEN[#SEEN + 1] = p; return true end }''')
    L.eval('require("mirror.uepath").set_map(...)', ansi, ue)
    L.eval('savefs.mkdir(...)', ansi + b"\\SurrounDead\\Saved\\SurrounSyncBackups")
    L.eval('savefs.list_dirs(...)', ansi + b"\\SurrounDead\\Saved\\SurrounSyncBackups")
    L.eval('savefs.mkdir(...)', b"C:\\plain\\dir")
    seen = [L.eval('SEEN[%d]' % i) for i in (1, 2, 3)]
    seen = [s if isinstance(s, bytes) else s.encode("utf-8", "surrogateescape") for s in seen]
    check(seen[0] == ue + b"\\SurrounDead\\Saved\\SurrounSyncBackups", "mkdir gets UE's spelling of LOCALAPPDATA")
    check(seen[1] == ue + b"\\SurrounDead\\Saved\\SurrounSyncBackups", "list_dirs gets UE's spelling too")
    check(seen[2] == b"C:\\plain\\dir", "ASCII paths pass through unchanged")
    L.execute('savefs.set_dir_backend{ mkdir = function() return false end }')
    odd = os.path.join(tmp, "\u00c0\u00f0", "b")
    made = L.eval('savefs.mkdir(...)', odd.encode("mbcs"))
    check(made is True and os.path.isdir(odd), "a failing UE mkdir falls back to cmd mkdir for non-ASCII paths")


@test
def localdir_reaches_saves_whatever_the_user_name(L, tmp):
    # a user name the ANSI code page can't spell comes out as "?" - every Lua file call on the saves would fail
    good = os.path.join(tmp, "alias")
    os.makedirs(good)
    af = os.path.join(tmp, "mirror_localdir.txt")
    L.execute('ld = require("mirror.localdir")')
    g = L.globals()
    g.ENV = "C:\\Users\\plain\\AppData\\Local"
    L.execute('ld.configure{ getenv = function() return ENV end, alias_file = "nope.txt" }')
    check(L.eval('ld.get()') == "C:\\Users\\plain\\AppData\\Local\\SurrounDead" and not L.eval('ld.broken()'), "an ASCII path is used as it is")
    g.ENV, g.AF = "C:\\Users\\??\\AppData\\Local", af
    L.execute('ld.configure{ alias_file = AF }')
    check(L.eval('ld.broken()') is True, "a '?' path without an alias is reported broken (Setup FIX makes one)")
    with open(af, "w") as f:
        f.write(good + "\r\n")
    L.execute('ld.configure{}')   # (resets the cache - the 5 s retry in-game)
    check(L.eval('ld.get()') == good and not L.eval('ld.broken()') and L.eval('ld.how()') == "alias",
          "the alias file the bridge/setup writes is used")
    g.ENV = "C:\\Users\\plain2\\AppData\\Local"
    L.execute('ld.configure{}')
    check(L.eval('ld.get()') == "C:\\Users\\plain2\\AppData\\Local\\SurrounDead", "an ASCII path wins over a leftover alias file")
    L.execute('ld.configure{ getenv = os.getenv }')


EMSH = b"EMSH\x01\x00\x00\x00\n\x02\x00\x00"
JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF"


def saves(tmp, sub="Saved"):
    return os.path.join(tmp, "SurrounDead", sub, "SaveGames")


def broot(tmp, sub="Saved"):
    return os.path.join(tmp, "SurrounDead", sub, "SurrounSyncBackups")


def make_slot(tmp, slot, tag=b"own", sub="Saved", world=True):
    """A stand-in save: EMSH files with distinct bodies, a JPEG thumb, quest + skill sidecars."""
    d = os.path.join(saves(tmp, sub), slot)
    files = {}
    names = (["Level.sav", "General.sav", "Difficulties.sav", "Slot.sav"] if world else []) + ["Player.sav", "PlayerInfo.sav"]
    for n in names:
        files[os.path.join(d, n)] = EMSH + tag + b" " + n.encode() * 50
    if world:
        files[os.path.join(d, "Thumb.sav")] = JPEG + tag
    files[os.path.join(saves(tmp, sub), slot + "_SDQuests.sav")] = EMSH + tag + b" quests"
    files[os.path.join(saves(tmp, sub), slot + "_SkillTree.sav")] = EMSH + tag + b" skills"
    for p, data in files.items():
        write(p, data)
    return files


def configure_backups(L, tmp, sub="Saved", kept=10):
    L.execute('local d, k = ... ; backups = require("mirror.backups"); '
              'backups.configure{ saves_dir = d, kept = k, version = "0.7.0" }', saves(tmp, sub), kept)


def fixed_clock(L, stamp="2026-10-16 15.29.00"):
    L.execute('local s = ... ; local real = os.date; os.date = function(f, t) '
              'if f == "%Y-%m-%d %H.%M.%S" then return s elseif f == "%Y-%m-%d %H:%M:%S" then return (s:gsub("%.", ":")) end '
              'return real(f, t) end', stamp)


def first(r):
    return r[0] if isinstance(r, tuple) else r


def bump(tmp, slot, i, sub="Saved"):
    """the game saved again: a new Slot.sav (else backups.take sees an identical save and skips it)"""
    write(os.path.join(saves(tmp, sub), slot, "Slot.sav"), EMSH + b"save %d" % i)


@test
def backups_old_folder_name_moves(L, tmp):
    """Backups taken under the old name (MirrorBackups) move to SurrounSyncBackups and are still listed."""
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    folder = take(L, "S1")
    old = os.path.join(tmp, "SurrounDead", "Saved", "MirrorBackups")
    os.rename(broot(tmp), old)
    configure_backups(L, tmp)
    check(os.path.isdir(os.path.join(broot(tmp), "S1", folder)) and not os.path.exists(old),
          "the whole MirrorBackups folder renamed to SurrounSyncBackups")
    check([e["folder"] for e in listing(L, "S1")] == [folder], "...and its backups listed as before")
    make_slot(tmp, "S2")
    os.makedirs(os.path.join(old, "S2", "2026-01-01 00.00.00 before joining"))
    configure_backups(L, tmp)
    check(os.path.isdir(os.path.join(broot(tmp), "S2", "2026-01-01 00.00.00 before joining")),
          "both exist: the old folder's save backups the new one lacks move over")


def take(L, slot, reason="before joining", kind="full", frm=None):
    return first(L.eval('(function(s, r, k, f) return backups.take{ slot = s, reason = r, kind = k, from = f } end)(...)',
                        slot, reason, kind, frm))


def listing(L, slot):
    t = L.eval('require("mirror.backups").list(...)', slot)
    return [dict(e.items()) for e in t.values()] if t else []


def manifest_text(tmp, slot, folder, sub="Saved"):
    return read(os.path.join(broot(tmp, sub), slot, folder, "backup.txt")).decode()


@test
def backups_take_full(L, tmp):
    import re, zlib
    files = make_slot(tmp, "S1")
    configure_backups(L, tmp)
    folder = take(L, "S1")
    check(folder is not None and re.match(r"^\d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d before joining$", folder) is not None,
          "folder named '<date time> before joining' (%s)" % folder)
    bdir = os.path.join(broot(tmp), "S1", folder or "?")
    same = all(os.path.exists(os.path.join(bdir, os.path.basename(p))) and read(os.path.join(bdir, os.path.basename(p))) == data
               for p, data in files.items())
    check(same, "every slot file and both sidecars copied byte-exact, sidecars under their real names")
    m = manifest_text(tmp, "S1", folder) if folder else ""
    lv = files[os.path.join(saves(tmp), "S1", "Level.sav")]
    check("pinned=1" in m and "kind=full" in m and "slot=S1" in m and "version=0.7.0" in m, "manifest header")
    check(("file Level.sav %d %08x\n" % (len(lv), zlib.crc32(lv))) in m, "manifest lists Level.sav with size and CRC32")
    check("file S1_SDQuests.sav " in m and m.split("file S1_SDQuests.sav ")[1].split("\n")[0].endswith(" sidecar"),
          "sidecars marked in the manifest")
    check(os.path.exists(os.path.join(broot(tmp), "README.txt")), "README.txt written")


@test
def backups_retention_and_same_second(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    fixed_clock(L)
    names = []
    for i in range(12):
        bump(tmp, "S1", i); names.append(take(L, "S1"))
    check(names[1] == "2026-10-16 15.29.00 before joining (2)", "same second twice -> ' (2)' (%s)" % names[1])
    lst = listing(L, "S1")
    check(len(lst) == 11 and sum(1 for e in lst if e["pinned"]) == 1, "pinned + newest 10 kept (%d)" % len(lst))
    check(len(lst) == 11 and lst[0]["folder"] == names[-1] and lst[-1]["folder"] == names[0], "newest first, the pinned first one last")
    d = os.path.join(broot(tmp), "S1")
    on_disk = [x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x))] if os.path.isdir(d) else []
    check(len(on_disk) == 11 and names[1] not in on_disk, "pruned folders removed from disk")


@test
def backups_orphans_and_verify(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    folder = take(L, "S1")
    orphan = os.path.join(broot(tmp), "S1", "2026-01-01 00.00.00 before joining")
    write(os.path.join(orphan, "Level.sav"), b"half")
    check(len(listing(L, "S1")) == 1, "a folder without backup.txt isn't listed")
    L.eval('backups.cleanup_orphans(...)', "S1")
    check(not os.path.exists(orphan), "cleanup_orphans removes it")
    check(first(L.eval('backups.verify(...)', "S1", folder)) is True, "verify passes on an intact backup")
    p = os.path.join(broot(tmp), "S1", folder, "Player.sav")
    data = bytearray(read(p)); data[-1] ^= 1; write(p, bytes(data))
    check(first(L.eval('backups.verify(...)', "S1", folder)) is False, "verify fails after one flipped bit")


@test
def backups_character_from_coop(L, tmp):
    make_slot(tmp, "S1")
    coop = make_slot(tmp, "SurrounSync_Session_1", tag=b"coop")
    configure_backups(L, tmp)
    folder = take(L, "S1", "co-op character not applied", "character", "SurrounSync_Session_1")
    bdir = os.path.join(broot(tmp), "S1", folder or "?")
    got = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    check(got == ["Player.sav", "PlayerInfo.sav", "S1_SDQuests.sav", "S1_SkillTree.sav", "backup.txt"],
          "character backup: player files + sidecars under the OWN save's names (%s)" % got)
    check(got != [] and read(os.path.join(bdir, "S1_SDQuests.sav")) == coop[os.path.join(saves(tmp), "SurrounSync_Session_1_SDQuests.sav")],
          "contents come from the co-op save")
    m = manifest_text(tmp, "S1", folder) if folder else ""
    check("slot=S1" in m and "kind=character" in m, "manifest: slot = own save, kind = character")


@test
def backups_spaces_and_guest_root(L, tmp):
    make_slot(tmp, "My Save 1", sub="Saved_Guest")
    configure_backups(L, tmp, sub="Saved_Guest")
    check(L.eval('backups.root()') == broot(tmp, "Saved_Guest"), "one-PC guest install: backups next to Saved_Guest\\SaveGames")
    folder = take(L, "My Save 1")
    lst = listing(L, "My Save 1")
    check(folder is not None and len(lst) == 1 and first(L.eval('backups.verify(...)', "My Save 1", folder)) is True,
          "a save name with spaces round-trips (take, list, verify)")


@test
def backups_failing_file_call(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    fixed_clock(L)
    L.execute('inject(0)'); take(L, "S1"); total = L.eval('CALLS'); L.execute('uninject()')
    shutil.rmtree(os.path.join(broot(tmp), "S1"), ignore_errors=True)
    bad = []
    for n in range(1, total + 1):
        L.execute('inject(...)', n, "fail")
        folder = take(L, "S1")
        L.execute('uninject()')
        lst = listing(L, "S1")
        ok_backup = folder is not None and len(lst) == 1 and first(L.eval('backups.verify(...)', "S1", folder)) is True
        none = folder is None and len(lst) == 0
        if not (ok_backup or none):
            bad.append("call %d: folder=%s listed=%d" % (n, folder, len(lst)))
        shutil.rmtree(os.path.join(broot(tmp), "S1"), ignore_errors=True)
    check(total > 10 and not bad, "a failing file call -> a complete, verified backup or none (%d calls) %s" % (total, bad[:3]))


@test
def backups_lost_index_is_rebuilt(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    fixed_clock(L)
    a = take(L, "S1"); bump(tmp, "S1", 1); b = take(L, "S1")
    os.remove(os.path.join(broot(tmp), "S1", "index.txt"))
    bump(tmp, "S1", 2); c = take(L, "S1")
    lst = listing(L, "S1")
    check([e["folder"] for e in lst] == [c, b, a] and lst[-1]["pinned"] and not lst[0]["pinned"],
          "a lost index.txt is rebuilt from the manifests: old backups stay listed, the first stays pinned")
    L.eval('backups.cleanup_orphans(...)', "S1")
    check(all(os.path.isdir(os.path.join(broot(tmp), "S1", x)) for x in (a, b, c)), "cleanup never removes a complete backup")


@test
def backups_restore_request(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    folder = take(L, "S1")
    L.eval('backups.request_restore(...)', "S1", folder)
    r = L.eval('backups.pending_restore()')
    check(r is not None and r["slot"] == "S1" and r["folder"] == folder, "pending_restore returns the request")
    L.eval('backups.cancel_restore()')
    check(L.eval('backups.pending_restore()') is None, "cancel removes it")


COOP = "SurrounSync_Session_1"


def guard(L, tmp, sub="Saved"):
    configure_backups(L, tmp, sub)
    L.execute('local d = ... ; slotguard = require("mirror.slotguard"); '
              'slotguard.configure{ saves_dir = d, coop_base = "SurrounSync_Session", legacy_base = "MirrorCoop_Session" }', saves(tmp, sub))
    os.makedirs(os.path.join(saves(tmp, sub), COOP), exist_ok=True)


def world_files(tag=b"host"):
    return {"Level.sav": EMSH + tag + b" level" * 40, "General.sav": EMSH + tag + b" general",
            "Difficulties.sav": EMSH + tag + b" diff", "Slot.sav": EMSH + tag + b" slot", "Thumb.sav": JPEG + tag * 8}


def lua_files(L, files):
    t = L.table()
    for k, v in files.items():
        t[k] = v
    return t


def log_write(L, **kw):
    L.eval('slotguard.log_write(...)', L.table_from(kw))


def snapshot(tmp, slot, sub="Saved"):
    """every file of a save (folder + sidecars) -> bytes"""
    out = {}
    d = os.path.join(saves(tmp, sub), slot)
    if os.path.isdir(d):
        for n in os.listdir(d):
            if os.path.isfile(os.path.join(d, n)):
                out[n] = read(os.path.join(d, n))
    for x in ("_SDQuests.sav", "_SkillTree.sav", "_Quests.sav"):
        p = os.path.join(saves(tmp, sub), slot + x)
        if os.path.exists(p):
            out[x] = read(p)
    return out


@test
def guard_drops_only_an_empty_new_save(L, tmp):
    # a guest's Save menu "new save" in co-op: the game wrote only Thumb.sav there, the save went to the co-op slot
    guard(L, tmp)
    d = saves(tmp, "Saved")
    write(os.path.join(d, "NewSave", "Thumb.sav"), JPEG + b"thumb")
    check(first(L.eval('slotguard.drop_stray("NewSave")')) is True and not os.path.exists(os.path.join(d, "NewSave")),
          "a thumbnail-only new save is removed (it showed in the load list and couldn't load)")
    make_slot(tmp, "S1")
    before = snapshot(tmp, "S1")
    check(not first(L.eval('slotguard.drop_stray("S1")')) and snapshot(tmp, "S1") == before, "a real save is never touched")
    write(os.path.join(d, COOP, "Thumb.sav"), JPEG)
    check(not first(L.eval('slotguard.drop_stray(...)', COOP)) and os.path.exists(os.path.join(d, COOP, "Thumb.sav")),
          "a co-op save is refused")
    write(os.path.join(d, "Odd", "Thumb.sav"), JPEG)
    write(os.path.join(d, "Odd", "notes.txt"), b"mine")
    check(not first(L.eval('slotguard.drop_stray("Odd")')) and os.path.exists(os.path.join(d, "Odd", "notes.txt")),
          "a folder with anything else in it stays")
    check(not first(L.eval('slotguard.drop_stray("../x")')), "a path is refused")


@test
def guard_names(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    bad = [n for n in ("", "..", "a/b", "a\\b", "C:x", "x*", "a..b") if L.eval('slotguard.valid_name(...)', n)]
    check(not bad, "names with .. / \\ : * are invalid %s" % bad)
    check(L.eval('slotguard.is_coop(...)', COOP) and not L.eval('slotguard.is_coop("S1")'), "is_coop")
    check(L.eval('slotguard.is_own("S1")') and not L.eval('slotguard.is_own(...)', COOP)
          and not L.eval('slotguard.is_own("Nope")'), "is_own: a real save with Player.sav, never a co-op save")


@test
def guard_validate_world(L, tmp):
    guard(L, tmp)
    ready = {"nonce": "17", "expect_nonce": "17", "slot": "QuickSave1_Host", "count": 5}

    def ok(files, **over):
        r = dict(ready); r.update(over)
        return first(L.eval('slotguard.validate_world(...)', lua_files(L, files), L.table_from(r))) is True
    good = world_files()
    check(ok(good), "a normal host world passes")
    f = dict(good); f["Evil.sav"] = EMSH + b"x" * 20
    check(not ok(f), "unknown file name rejected")
    f = dict(good); del f["Level.sav"]
    check(not ok(f, count=4), "missing Level.sav rejected")
    f = dict(good); f["Level.sav"] = b"GVAS" + b"x" * 40
    check(not ok(f), "Level.sav without the EMSH header rejected")
    f = dict(good); f["Thumb.sav"] = EMSH + b"x" * 20
    check(not ok(f), "Thumb.sav that isn't a JPEG rejected")
    f = dict(good); f["Level.sav"] = EMSH + b"x" * (17 * 1024 * 1024)
    check(not ok(f), "17 MB file rejected")
    check(not ok(good, nonce="16"), "wrong nonce rejected")
    check(not ok(good, count=6), "file count 6 rejected")
    check(not ok(good, slot="..\\x"), "host slot name with .. rejected")


@test
def guard_refusal_reason_reaches_caller(L, tmp):
    guard(L, tmp)
    r = L.eval('slotguard.import_world(...)', "SurrounSync_Session_2", lua_files(L, world_files()))
    check(isinstance(r, tuple) and r[0] is None and "co-op save" in (r[1] or ""), "a refusal returns nil plus the reason (%s)" % (r,))


@test
def structure_only_guard_uses_savefs(L, tmp):
    import re
    mods = os.path.join(SCRIPTS, "mirror")
    users = sorted(f[:-4] for f in os.listdir(mods) if f.endswith(".lua")
                   and re.search(r'require\("mirror\.savefs"\)', open(os.path.join(mods, f), encoding="utf-8").read()))
    # (realm: atomic writes in its own SurrounSyncRealms folder only; Realm saves go through slotguard)
    check(users == ["backups", "devtest", "realm", "slotguard"],
          "only backups, slotguard, realm (and devtest's probe) require savefs: %s" % users)
    realm_src = open(os.path.join(mods, "realm.lua"), encoding="utf-8").read()
    check("SaveGames" not in realm_src and "saves_dir" not in realm_src, "realm.lua never names a save folder")


@test
def guard_refusals(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    before = snapshot(tmp, "S1")
    log_write(L, step="building", own="S1", coop=COOP)
    r = L.eval('slotguard.import_world(...)', "S1", lua_files(L, world_files()))
    check(first(r) is None and snapshot(tmp, "S1") == before and L.eval('log_has("ERROR", "slotguard: refused")'),
          "world files into an own save: refused, logged, nothing written")
    os.makedirs(os.path.join(saves(tmp), "SurrounSync_Session_2"))
    check(first(L.eval('slotguard.import_world(...)', "SurrounSync_Session_2", lua_files(L, world_files()))) is None,
          "import into a co-op save that isn't the session log's: refused")
    L.eval('slotguard.purge("S1")')
    check(snapshot(tmp, "S1") == before, "purge of an own save: refused")
    check(first(L.eval('slotguard.copy_character_home(...)', COOP, "..\\S1")) is None, "names with .. refused")
    make_slot(tmp, COOP, tag=b"coop", world=False)
    log_write(L, step="leaving", own="Nope", coop=COOP)
    os.makedirs(os.path.join(saves(tmp), "Nope"))
    check(first(L.eval('slotguard.copy_character_home(...)', COOP, "Nope")) is None, "copy home into a save without Player.sav: refused")


@test
def guard_foreign_coop_named_save(L, tmp):
    """A save the PLAYER named like a co-op slot (no SurrounSync marker, no session log) is never emptied or reused."""
    guard(L, tmp)
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"players")
    before = snapshot(tmp, COOP)
    check(L.eval('slotguard.foreign(...)', COOP) is True, "co-op-named folder with an unmarked save: foreign")
    L.eval('slotguard.purge(...)', COOP)
    check(snapshot(tmp, COOP) == before, "purge of a foreign co-op-named save: refused, nothing deleted")
    check(first(L.eval('slotguard.seed_character(...)', "S1", COOP)) is None and snapshot(tmp, COOP) == before,
          "building a co-op session into it: refused, nothing written")
    check(L.eval('slotguard.is_coop("SurrounSync_Session_x2")') is False and L.eval('slotguard.is_coop("SurrounSync_Session_12")') is True
          and L.eval('slotguard.is_coop("SurrounSync_Session")') is True and L.eval('slotguard.is_coop("SurrounSync_Sessions")') is False,
          "co-op names: only <base> or <base>_<number>")
    os.makedirs(os.path.join(saves(tmp), "SurrounSync_Session_2"))
    L.eval('slotguard.seed_character(...)', "S1", "SurrounSync_Session_2")
    check(L.eval('slotguard.foreign("SurrounSync_Session_2")') is False, "a co-op save the mod built: not foreign")
    L.eval('slotguard.purge("SurrounSync_Session_2")')
    check(os.listdir(os.path.join(saves(tmp), "SurrounSync_Session_2")) == [], "...emptied, marker included")


@test
def guard_copy_home_fingerprint(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    coop = make_slot(tmp, COOP, tag=b"coop")
    own_world = {k: v for k, v in snapshot(tmp, "S1").items() if k in ("Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav")}
    stamp = L.eval('slotguard.stamp("S1")')
    log_write(L, step="leaving", own="S1", coop=COOP, own_stamp=stamp)
    r = first(L.eval('slotguard.copy_character_home(...)', COOP, "S1"))
    after = snapshot(tmp, "S1")
    cs = snapshot(tmp, COOP)
    check(r == "copied", "matching fingerprint -> copied (%s)" % r)
    check(all(after[k] == cs[k] for k in ("Player.sav", "PlayerInfo.sav", "_SDQuests.sav", "_SkillTree.sav")),
          "player files and sidecars now come from the co-op save")
    check(all(after[k] == v for k, v in own_world.items()), "own world files byte-identical (never the host's)")
    check(any(e["reason"] == "before going home" for e in listing(L, "S1")), "a 'before going home' backup was taken first")

    make_slot(tmp, "S2")
    write(os.path.join(saves(tmp), "S2", "Slot.sav"), EMSH + b"original")
    log_write(L, step="leaving", own="S2", coop=COOP, own_stamp=L.eval('slotguard.stamp("S2")'))
    write(os.path.join(saves(tmp), "S2", "Slot.sav"), EMSH + b"saved later")
    before = snapshot(tmp, "S2")
    r = first(L.eval('slotguard.copy_character_home(...)', COOP, "S2"))
    kept = [e for e in listing(L, "S2") if e["reason"] == "co-op character not applied"]
    check(r == "kept" and snapshot(tmp, "S2") == before and len(kept) == 1 and kept[0]["kind"] == "character",
          "changed fingerprint -> 'kept': own save untouched, co-op character stored as a character backup")


@test
def guard_failing_backup_blocks_copy(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    log_write(L, step="leaving", own="S1", coop=COOP, own_stamp=L.eval('slotguard.stamp("S1")'))
    before = snapshot(tmp, "S1")
    L.execute('backups.take = function() return nil, "disk full" end')
    r = L.eval('slotguard.copy_character_home(...)', COOP, "S1")
    check(first(r) is None and snapshot(tmp, "S1") == before, "no backup -> no copy, own save untouched")


@test
def guard_log_formats(L, tmp):
    guard(L, tmp)
    m = os.path.join(saves(tmp), "mirror_coop_session.txt")
    write(m, b"own=S1\ncoop=MirrorCoop_Session_3\nhome=1.0 2.0 3.0 4.0\nphase=leaving\n")
    t = L.eval('slotguard.log_read()')
    t = first(t)
    check(t is not None and t["step"] == "home" and t["own"] == "S1" and t["coop"] == "MirrorCoop_Session_3"
          and t["own_stamp"] is None, "0.6.0 marker with phase=leaving -> step home")
    write(m, b"own=S1\ncoop=MirrorCoop_Session_3\n")
    check(first(L.eval('slotguard.log_read()'))["step"] == "joined", "0.6.0 marker without phase -> step joined")
    write(m, b"\x00\x01garbage")
    r = L.eval('slotguard.log_read()')
    check(isinstance(r, tuple) and r[0] is None and r[1] == "bad", "garbage -> nil, 'bad'")
    L.eval('slotguard.log_quarantine()')
    check(not os.path.exists(m) and os.path.exists(m + ".mirror-bad"), "quarantine renames it to .mirror-bad")
    log_write(L, step="joined", own="S1", coop=COOP, home="1 2 3 4", own_stamp="abcd0123", host="Host Name", version="0.7.0")
    t = first(L.eval('slotguard.log_read()'))
    check(t["step"] == "joined" and t["host"] == "Host Name" and t["own_stamp"] == "abcd0123", "new format round-trips")
    L.eval('slotguard.log_clear()')
    check(L.eval('slotguard.log_read()') is None, "log_clear removes it")


@test
def guard_apply_restore(L, tmp):
    guard(L, tmp)
    files = make_slot(tmp, "S1")
    folder = take(L, "S1")
    write(os.path.join(saves(tmp), "S1", "Player.sav"), EMSH + b"broken later")
    write(os.path.join(saves(tmp), "S1_SDQuests.sav"), EMSH + b"broken later")
    r = first(L.eval('slotguard.apply_restore(...)', "S1", folder))
    now = snapshot(tmp, "S1")
    check(r is True and now["Player.sav"] == files[os.path.join(saves(tmp), "S1", "Player.sav")]
          and now["_SDQuests.sav"] == files[os.path.join(saves(tmp), "S1_SDQuests.sav")], "restore puts every file back")
    check(any(e["reason"] == "before restore" for e in listing(L, "S1")), "the state before the restore was backed up")
    p = os.path.join(broot(tmp), "S1", folder, "Level.sav")
    data = bytearray(read(p)); data[-1] ^= 1; write(p, bytes(data))
    check(first(L.eval('slotguard.apply_restore(...)', "S1", folder)) is None, "a corrupt backup is refused")
    log_write(L, step="joined", own="S1", coop=COOP)
    check(first(L.eval('slotguard.apply_restore(...)', "S1", folder)) is None, "no restore while a co-op session is open")


SESSION_FAKES = r'''
local saves, own = ...
CURRENT, SAVING, SAVES, LOADS, NOTES = own, 0, 0, {}, {}
BLOBS_IN, BLOBS_OUT, FILES_IN, FILES_OUT = {}, {}, {}, {}
LEVEL = "LongdownValley"
local function obj(t)
    t.IsValid = t.IsValid or function() return true end
    t.GetAddress = t.GetAddress or function() return t.addr or 1 end
    return t
end
-- (util.class_name valid-checks the class: a fake class needs IsValid too)
local function cls(name) return function() return obj{ GetFName = function() return { ToString = function() return name end } end } end end
-- the game saving into the current slot, the way EMS does: Slot.sav (save time) + the player files change
function GAME_SAVE()
    SAVES, SAVING = SAVES + 1, 2
    local d = saves .. "\\" .. CURRENT
    for _, n in ipairs({ "Slot.sav", "Player.sav", "PlayerInfo.sav" }) do
        local f = REAL.open(d .. "\\" .. n, "wb")
        if f then f:write("EMSH " .. n .. " of " .. CURRENT .. " save " .. SAVES); f:close() end
    end
end
PLAYER = obj{ addr = 7, BP_JigMultiplayer = {},
    K2_GetActorLocation = function() return { X = 1, Y = 2, Z = 3 } end,
    K2_GetActorRotation = function() return { Pitch = 0, Yaw = 10, Roll = 0 } end,
    K2_TeleportTo = function() return true end, ClearUI = function() end, DestroyActors = function() end,
    Event_LoadPlayer = function() end }
PC = obj{ SaveGameToSlot = function() GAME_SAVE() end }
WORLD = obj{}
local function exists_dir(n) local f = REAL.open(saves .. "\\" .. n .. "\\.p", "wb"); if f then f:close(); REAL.remove(saves .. "\\" .. n .. "\\.p"); return true end return false end
EMSLIB = obj{
    IsSavingOrLoading = function() return SAVING > 0 end,
    SetCurrentSaveGameName = function(_, _, s) CURRENT = s end,
    DoesSaveSlotExist = function(_, _, n) return exists_dir(n) end,
    GetSortedSaveSlots = function() return {} end,
    GetNamedSlotInfo = function() error("no") end,
    GetSlotInfoSaveGame = function() error("no") end,
}
EMSOBJ = setmetatable(obj{ GetClass = cls("EMSObject"), CachedCustomSaves = { ForEach = function() end } },
    { __index = function(_, k) if k == "CurrentSaveGameName" then return CURRENT end end })
GI = obj{ GetClass = cls("SD_GameInstance_C"), Event_LoadLevel = function(_, l) LOADS[#LOADS + 1] = CURRENT end }
GI.CurrentLevel = LEVEL
function StaticFindObject(p) if p:find("EMSFunctionLibrary", 1, true) then return EMSLIB end end
function FindAllOf(c) if c == "EMSObject" then return { EMSOBJ } end return {} end
function FindFirstOf(c) if c == "SD_GameInstance_C" then return GI end end
ModifierKey = { CONTROL = 1 }
TICKS, NEW_PLAYER = {}, {}
package.loaded["mirror.game"] = {
    player = function() return PLAYER end, controller = function() return PC end, world = function() return WORLD end,
    on_tick = function(fn) TICKS[#TICKS + 1] = fn end, on_ready = function(fn) end,
    player_hook = function() end, keybind = function() end,
    on_new_player = function(fn) NEW_PLAYER[#NEW_PLAYER + 1] = fn end,
}
package.loaded["mirror.link"] = {
    kind = function() return "file" end,
    put_blob = function(n, t) BLOBS_OUT[n] = t end, get_blob = function(n) return BLOBS_IN[n] end,
    reset_blob = function(n) BLOBS_IN[n] = nil end,
    put_file = function(n, d, tag) FILES_OUT[n] = { d, tag } end,
    get_file = function(n) local x = FILES_IN[n]; if x then return x[1], x[2] end end,
    peer_name = function() return "Host" end, peer_age = function() return 0 end,
}
package.loaded["mirror.ghost"] = { exists = function() return false end, destroy = function() end,
    location = function() return nil end, is = function() return false end, get = function() return nil end }
package.loaded["mirror.notify"] = { show = function(m) NOTES[#NOTES + 1] = m end, clear = function() end }
ASKS = {}
package.loaded["mirror.names"] = { ask = function(o) ASKS[#ASKS + 1] = o; return true end,
    asking = function() return false end }
package.loaded["mirror.invdiag"] = { snapshot = function() end, live_containers = function() return 3 end }
package.loaded["mirror.jig"] = { contents_of = function() return {} end }
CFG = { diagnostics = false,
    phase2 = { coop_slot = "SurrounSync_Session", legacy_coop_slot = "MirrorCoop_Session", coop_slots = 8, saved_override = "Saved", saved_dir = {},
               teleport_settle = 3.0, teleport_tolerance = 2000 },
    save = { backups_kept = 10, checkpoints = true, checkpoint_delay = 5.0, checkpoint_min_interval = 20.0,
             host_gone_countdown = 30, peer_gone_after = 15, file_link_gone_after = 45, guest_gone_reset = 30 } }
session = require("mirror.session")
function TICK(n, dt)
    for _ = 1, n or 1 do
        require("mirror.util").new_frame()   -- one game frame each, like game.lua
        session.tick(dt or 0.5)
        if SAVING > 0 then SAVING = SAVING - 1 end
    end
end
function note_has(s) for _, m in ipairs(NOTES) do if m:find(s, 1, true) then return true end end return false end
'''


def session_rt(L, tmp, own="S1"):
    for i in range(1, 9):
        os.makedirs(os.path.join(saves(tmp), "SurrounSync_Session_%d" % i), exist_ok=True)
    L.execute(SESSION_FAKES, saves(tmp), own)


def host_answers(L, files=None, count=None, slot="QuickSave1_Host"):
    """Play the host: answer the guest's join request with these world files."""
    req = L.eval('BLOBS_OUT["req"]') or ""
    nonce = req.split(" ")[1] if " " in req else "0"
    files = world_files() if files is None else files
    for n, d in files.items():
        L.eval('(function(n, d, t) FILES_IN["world_" .. n] = { d, t } end)(...)', n, d, nonce)
    L.eval('(function(s) BLOBS_IN["world"] = s end)(...)', "ready %s %s %d" % (nonce, slot, count or len(files)))


def joined_session(L, tmp):
    """own save S1, join the host, return (own files before, host world)"""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    before = snapshot(tmp, "S1")
    host_answers(L)
    L.execute('TICK(4)')
    return before


@test
def session_join_builds_coop_save(L, tmp):
    before = joined_session(L, tmp)
    coop = snapshot(tmp, COOP)
    hw = world_files()
    check(L.eval('session.state()') == "joined", "joined (%s)" % L.eval('session.state()'))
    check(all(coop.get(k) == v for k, v in hw.items()), "co-op save holds the host's world files")
    check(coop.get("Player.sav") == before["Player.sav"] and coop.get("_SDQuests.sav") == before["_SDQuests.sav"],
          "co-op save holds the guest's own character + sidecars")
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t is not None and t["step"] == "joined" and t["own"] == "S1" and t["coop"] == COOP and t["own_stamp"],
          "session log: step joined with own, coop and the own fingerprint")
    check(any(e["reason"] == "before joining" for e in listing(L, "S1")), "own save backed up before joining")
    check(L.eval('LOADS[#LOADS]') == COOP, "the co-op save was loaded")


@test
def session_firewall_save_menu_while_joined(L, tmp):
    """The game's Save menu / new-slot autosave while joined points EMS at another slot: the save goes to the co-op save."""
    before = joined_session(L, tmp)
    os.makedirs(os.path.join(saves(tmp), "MenuSlot"))
    L.execute('CURRENT = "MenuSlot"; require("mirror.save_guard").run_before_save(); PC:SaveGameToSlot()')
    check(L.eval('CURRENT') == COOP, "save pointed back at the co-op save (%s)" % L.eval('CURRENT'))
    check(os.listdir(os.path.join(saves(tmp), "MenuSlot")) == [], "nothing written into the slot the menu picked")
    check(snapshot(tmp, "S1") == before, "own save untouched")
    L.execute('TICK(4)')
    check(L.eval('session.state()') == "joined", "still in co-op (the save isn't taken for leaving)")


@test
def session_firewall_coop_slot_outside_session(L, tmp):
    """Not in a session, EMS pointed at a co-op save: the save goes to the slot the world was loaded from."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('for _, fn in ipairs(NEW_PLAYER) do fn() end')
    L.execute('CURRENT = "%s"; require("mirror.save_guard").run_before_save()' % COOP)
    check(L.eval('CURRENT') == "S1", "save sent back to the world's own save (%s)" % L.eval('CURRENT'))


def stray_rt(L, tmp, coop_files=True):
    """report 2026-10-26: own save S1, but the game's current save (Continue) is a leftover co-op slot"""
    make_slot(tmp, "S1")
    if coop_files:
        make_slot(tmp, COOP, tag=b"coop")
    session_rt(L, tmp, own=COOP)
    L.execute('EMSLIB.GetSortedSaveSlots = function() return { "%s", "S1" } end' % COOP)


def run_ticks(L, n=12):
    L.execute('for _ = 1, %d do require("mirror.util").new_frame(); for _, fn in ipairs(TICKS) do fn(0.5) end; session.tick(0.5) end' % n)


@test
def stray_startup_points_continue_at_own_save(L, tmp):
    stray_rt(L, tmp, coop_files=False)
    L.execute('local p = PLAYER; PLAYER = nil; session.preinit(CFG); PLAYER = p')  # mod start: no world yet
    check(L.eval('CURRENT') == "S1", "startup: Continue no longer loads the co-op slot (%s)" % L.eval('CURRENT'))
    L.execute('CURRENT = "S1"; session.preinit(CFG)')
    check(L.eval('CURRENT') == "S1", "an own save stays the current save")


@test
def stray_startup_without_any_own_save_points_at_a_free_name(L, tmp):
    """report 2026-10-28: no own save at all (new player / saves deleted) - Continue stayed on the co-op slot, New Game
    saved into it, and Realms / hosting said 'leftover co-op save' for every new world"""
    session_rt(L, tmp, own=COOP)
    L.execute('EMSLIB.GetSortedSaveSlots = function() return { "%s" } end' % COOP)
    L.execute('local p = PLAYER; PLAYER = nil; session.preinit(CFG); PLAYER = p')
    check(L.eval('CURRENT') == "SaveSlot", "startup: the current save is a fresh own name (%s)" % L.eval('CURRENT'))
    os.makedirs(os.path.join(saves(tmp, "Saved"), "SaveSlot"))   # a folder the game left, no Player.sav
    L.execute('CURRENT = "%s"; local p = PLAYER; PLAYER = nil; session.preinit(CFG); PLAYER = p' % COOP)
    check(L.eval('CURRENT') == "SaveSlot2", "a name whose folder exists is never used (%s)" % L.eval('CURRENT'))


@test
def stray_startup_leaves_an_open_session_alone(L, tmp):
    stray_rt(L, tmp, coop_files=False)
    guard(L, tmp)
    L.eval('slotguard.log_write(...)', L.table_from({"step": "joined", "own": "S1", "coop": COOP}))
    L.execute('slotguard.log_quarantine()')
    L.execute('session.preinit(CFG)')
    check(L.eval('CURRENT') == COOP, "a kept session log: the current save isn't moved")


@test
def stray_join_saves_nothing_and_offers_own_save(L, tmp):
    stray_rt(L, tmp)
    before = snapshot(tmp, COOP)
    L.execute('session.init(CFG, "guest", function() return true end)')
    # (startup already fixed Continue - this player got in anyway, e.g. picked the slot in Load Game)
    L.execute('CURRENT = "%s"; for _, fn in ipairs(NEW_PLAYER) do fn() end' % COOP)
    L.execute('session.request_toggle()')
    run_ticks(L)
    check(L.eval('SAVES') == 0 and snapshot(tmp, COOP) == before, "no save into the co-op slot before refusing")
    check(L.eval('session.state()') == "idle" and L.eval('BLOBS_OUT["req"]') is None, "no join from the co-op slot")
    check(L.eval('#ASKS') >= 1, "the player is offered their own save")


@test
def stray_world_offers_one_click_load(L, tmp):
    stray_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    # (startup already fixed Continue - this player got in anyway, e.g. picked the slot in Load Game)
    L.execute('CURRENT = "%s"; for _, fn in ipairs(NEW_PLAYER) do fn() end' % COOP)
    check(L.eval('session.stray_coop()') is True, "the loaded world is a leftover co-op save")
    run_ticks(L)
    check(L.eval('#ASKS') == 1, "one offer (not one per tick): %d" % L.eval('#ASKS'))
    L.execute('ASKS[1].done()')
    run_ticks(L, 2)
    check(L.eval('LOADS[#LOADS]') == "S1", "the button loads the player's own save (%s)" % L.eval('LOADS[#LOADS]'))


@test
def stray_main_menu_load_fixes_continue_only_there(L, tmp):
    # the save system may not exist at mod start: the main menu's map load is the second chance
    stray_rt(L, tmp, coop_files=False)
    L.execute('MAP_HOOKS = {}; function RegisterLoadMapPostHook(fn) MAP_HOOKS[#MAP_HOOKS + 1] = fn end')
    L.execute('session.preinit(CFG); for _, fn in ipairs(NEW_PLAYER) do fn() end')
    check(L.eval('#MAP_HOOKS') == 1, "one map-load hook")
    L.execute('local function world(n) return { get = function() return { GetFullName = function() return n end } end } end '
              'WORLD_AT = world')
    L.execute('CURRENT = "%s"; MAP_HOOKS[1](nil, WORLD_AT("World /Game/Levels/LongdownValley.LongdownValley"))' % COOP)
    check(L.eval('CURRENT') == COOP, "a loaded world: its current save is never re-pointed (its saves would hit S1)")
    L.execute('MAP_HOOKS[1](nil, WORLD_AT("World /Game/Levels/MainMenu.MainMenu"))')
    check(L.eval('CURRENT') == "S1", "main menu: Continue points at the own save again (%s)" % L.eval('CURRENT'))


@test
def i18n_messages(L, tmp):
    L.execute('i18n = require("mirror.i18n")')
    check(L.eval('i18n.t("load_own_first")') == "Load one of your own saves first, then join.", "English by default")
    check(L.eval('i18n.set("ru")') is True and L.eval('i18n.t("peer_older", "Akiyame")').startswith("У Akiyame"),
          "Russian with the friend's name")
    check(L.eval('i18n.set("xx")') is False and L.eval('i18n.lang()') == "en", "an unknown language is refused")
    check(L.eval('i18n.t("stray_msg", "50% off")').find("50% off") > 0, "a % in a name doesn't break the text")
    keys = set(L.eval('(function() local k = {} for n in pairs(i18n.LANGS.en) do k[#k + 1] = n end return table.concat(k, " ") end)()').split())
    for lang in ("ru", "de", "es", "fr", "pt"):
        got = set(L.eval('(function(l) local k = {} for n in pairs(i18n.LANGS[l]) do k[#k + 1] = n end return table.concat(k, " ") end)(...)', lang).split())
        check(got == keys, "%s has every message" % lang)
        for k in keys:
            n_en = L.eval('select(2, i18n.LANGS.en[...]:gsub("%%%%s", ""))', k)
            n_l = L.eval('(function(l, k) return select(2, i18n.LANGS[l][k]:gsub("%%%%s", "")) end)(...)', lang, k)
            if n_en != n_l:
                check(False, "%s.%s has %d %%s, English %d" % (lang, k, n_l, n_en))


@test
def stray_not_in_a_real_session(L, tmp):
    joined_session(L, tmp)
    L.execute('for _, fn in ipairs(NEW_PLAYER) do fn() end')
    run_ticks(L)
    check(L.eval('session.stray_coop()') is False and L.eval('#ASKS') == 0, "joined: the co-op world is no stray")


@test
def session_leave_copies_character_home(L, tmp):
    before = joined_session(L, tmp)
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    own = snapshot(tmp, "S1")
    check(own["Player.sav"].startswith(b"EMSH Player.sav of " + COOP.encode()), "own save got the co-op character")
    check(all(own[k] == before[k] for k in ("Level.sav", "General.sav", "Difficulties.sav", "Thumb.sav")),
          "own world files untouched (never the host's)")
    check(not os.path.exists(os.path.join(saves(tmp), COOP, "Level.sav")), "co-op save emptied after going home")
    check(L.eval('LOADS[#LOADS]') == "S1" and L.eval('session.state()') == "idle", "own save loaded, idle")
    check(any(e["reason"] in ("before going home", "before joining") for e in listing(L, "S1")),
          "own save backed up before the copy (unchanged since joining: the 'before joining' copy is that backup)")


@test
def session_leave_clears_own_cached_player_before_home_load(L, tmp):
    # DBG-20261027-007: the home load reads EMS's cached PlayerInfo, not the copied file - the own slot's
    # entry still held the pre-join inventory, so co-op takes were lost and put-ins came home again
    joined_session(L, tmp)
    L.execute('''
        local function save(name) return { name = name, IsValid = function() return true end } end
        local entries = { { k = "PlayerInfo@cso@S1", o = save("own") }, { k = "PlayerInfo@cso@''' + COOP + '''", o = save("coop") },
                          { k = "General@cso@S1", o = save("general") } }
        EMSOBJ.CachedCustomSaves = { ForEach = function(_, fn)
            for _, e in ipairs(entries) do fn(e.k, { get = function() return e.o end }) end
        end }
        RESETS = {}
        EMSLIB.ResetCustomSave = function(_, _, obj, kind) RESETS[#RESETS + 1] = { name = obj.name, kind = kind, loads = #LOADS } end''')
    loads0 = L.eval('#LOADS')
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    check(L.eval('LOADS[#LOADS]') == "S1", "went home")
    check(L.eval('#RESETS') == 1 and L.eval('RESETS[1].name') == "own" and L.eval('RESETS[1].kind') == 1,
          "only the own slot's cached PlayerInfo is cleared (ClearMemory) (%s)" % L.eval('#RESETS'))
    check(L.eval('RESETS[1].loads') == loads0, "cleared before the home load")
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")).startswith(b"EMSH Player.sav of " + COOP.encode()),
          "the file the load will read is the co-op character")


HOME_BED = "1 100.0 200.0 300.0 0.000000 0.000000 0.000000 1.000000"
HOST_BED = "1 5000.0 6000.0 700.0 0.000000 0.000000 0.000000 1.000000"
WORLD_BED = "1 8000.0 9000.0 100.0 0.000000 0.000000 0.000000 1.000000"


def bed_session(L, tmp):
    """own save S1 with a bed at home; joined, arrived (teleport done) and the host-world bed applied"""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('PC.RespawnPointEnabled = true; PC.RespawnLoc = { Translation = { X = 100, Y = 200, Z = 300 }, '
              'Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }')
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.set_peer_locator(function() return { X = 0, Y = 0, Z = 0 } end)')
    join_and_arrive(L)


def join_and_arrive(L):
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    L.eval('(function(s) BLOBS_IN["hostbed"] = s end)(...)', HOST_BED)
    host_answers(L)
    L.execute('TICK(30)')


def bed_now(L): return L.eval('require("mirror.beds").read()')


def beds_file(tmp):
    p = os.path.join(os.path.dirname(saves(tmp)), "mirror_coop_beds.txt")
    return read(p).decode() if os.path.exists(p) else ""


@test
def session_respawn_points(L, tmp):
    bed_session(L, tmp)
    check(L.eval('session.in_world()'), "joined and arrived")
    check(bed_now(L) == HOST_BED, "no bed of my own in this world yet: the host's bed (%s)" % bed_now(L))
    check(("home|S1=" + HOME_BED) in beds_file(tmp), "home bed noted until it's back at home")
    L.execute('PC.RespawnLoc = { Translation = { X = 8000, Y = 9000, Z = 100 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }')
    L.execute('TICK(6)')
    check(("world|Host|QuickSave1_Host|S1=" + WORLD_BED) in beds_file(tmp), "a bed set in the host's world is remembered")
    L.execute('session.request_toggle()')
    L.execute('TICK(1)')
    check(bed_now(L) == HOME_BED, "the leave save carries the home bed (%s)" % bed_now(L))
    L.execute('TICK(30)')
    check(L.eval('session.state()') == "idle" and "home|S1" not in beds_file(tmp), "home: nothing left to restore")
    check(bed_now(L) == HOME_BED, "home bed on the character at home")
    join_and_arrive(L)
    check(L.eval('session.in_world()') and bed_now(L) == WORLD_BED, "rejoin: the bed I set there (%s)" % bed_now(L))


@test
def session_respawn_point_after_menu_exit(L, tmp):
    bed_session(L, tmp)
    check(bed_now(L) == HOST_BED, "host's bed while joined")
    L.execute('CURRENT = "S1"; session.on_load_level()')
    L.execute('TICK(30)')
    check(L.eval('session.state()') == "idle" and bed_now(L) == HOME_BED, "home bed back after a menu exit (%s)" % bed_now(L))
    check("home|S1" not in beds_file(tmp), "restored: no longer pending")


@test
def session_join_refused_without_backup(L, tmp):
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('require("mirror.backups").take = function() return nil, "disk full" end')
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    check(L.eval('session.state()') == "idle" and L.eval('BLOBS_OUT["req"]') is None, "no backup -> no join request")
    check(L.eval('note_has(...)', "Your disk is full"), "player told the real cause (disk full)")
    check(L.eval('session.backup_problem(...)', "can't write x.mirror-new: Permission denied") == "files_blocked", "permission denied -> blocked message")
    check(L.eval('session.backup_problem(...)', "can't create C:\\x") == "backup_failed", "anything else -> the general message")


@test
def session_bad_host_world_refused(L, tmp):
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    bad = world_files(); bad["Level.sav"] = b"GVAS not ours" * 4
    host_answers(L, bad)
    L.execute('TICK(4)')
    check(L.eval('session.state()') == "idle" and not os.path.exists(os.path.join(saves(tmp), COOP, "Level.sav")),
          "bad host world: not joined, nothing written")
    check(L.eval('note_has(...)', "arrived damaged. Please try again."), "player told")


def crash_state(L, tmp, step, half=False):
    """S1 + a co-op save with the co-op character, and a session log at `step`; then a fresh start."""
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    session_rt(L, tmp)
    L.execute('local d = ... ; require("mirror.backups").configure{ saves_dir = d }; '
              'require("mirror.slotguard").configure{ saves_dir = d, coop_base = "SurrounSync_Session" }', saves(tmp))
    stamp = L.eval('require("mirror.slotguard").stamp("S1")')
    L.eval('require("mirror.slotguard").log_write(...)', L.table_from(
        {"step": step, "own": "S1", "coop": COOP, "own_stamp": stamp, "home": "1.0 2.0 3.0 4.0"}))
    if half:
        p = os.path.join(saves(tmp), "S1", "Player.sav")
        os.replace(p, p + ".mirror-old")
    return snapshot(tmp, "S1"), snapshot(tmp, COOP)


@test
def session_recovery_by_step(L, tmp):
    import tempfile as tf
    results = {}
    for step, half in (("building", False), ("joined", False), ("leaving", True), ("home", False)):
        t2 = tf.mkdtemp(prefix="mirror_rec_")
        os.environ["LOCALAPPDATA"] = t2
        L2 = fresh(t2)
        own0, coop0 = crash_state(L2, t2, step, half)
        L2.execute('session.preinit(CFG)')
        own = snapshot(t2, "S1")
        log_left = os.path.exists(os.path.join(saves(t2), "mirror_coop_session.txt"))
        purged = not os.path.exists(os.path.join(saves(t2), COOP, "Player.sav"))
        if step in ("building", "home"):
            ok = all(own.get(k) == v for k, v in own0.items() if not k.endswith(".mirror-old"))
        else:
            ok = all(own.get(k) == coop0[k] for k in ("Player.sav", "PlayerInfo.sav", "_SDQuests.sav", "_SkillTree.sav")) \
                and own["Level.sav"] == own0["Level.sav"] and not os.path.exists(os.path.join(saves(t2), "S1", "Player.sav.mirror-old"))
        results[step] = (ok, log_left, purged)
        shutil.rmtree(t2, ignore_errors=True)
    os.environ["LOCALAPPDATA"] = tmp
    check(results["building"] == (True, False, True), "building: own untouched, co-op emptied, log gone %s" % (results["building"],))
    check(results["joined"] == (True, False, True), "joined: co-op character copied home, co-op emptied %s" % (results["joined"],))
    check(results["leaving"] == (True, False, True), "leaving (died mid copy): whole set redone, no leftovers %s" % (results["leaving"],))
    check(results["home"] == (True, False, True), "home: nothing copied again %s" % (results["home"],))


REALM = "4R5BJRNGWF"


def realm_character(tag=b"realmchar"):
    return {"Player.sav": EMSH + tag + b" player" * 20, "PlayerInfo.sav": EMSH + tag + b" info",
            "_SDQuests.sav": EMSH + tag + b" quests", "_SkillTree.sav": EMSH + tag + b" skills"}


@test
def guard_realm_build_read_and_never_home(L, tmp):
    """A Realm session's co-op save: world + Realm character in, read back out; the character never goes into the own save."""
    guard(L, tmp)
    make_slot(tmp, "S1")
    own0 = snapshot(tmp, "S1")
    hw, ch = world_files(b"realm"), realm_character()
    log_write(L, step="building", own="S1", coop=COOP, realm=REALM, gen="3", own_stamp="x")
    r = L.eval('slotguard.build_realm(...)', COOP, lua_files(L, hw), lua_files(L, ch))
    check(first(r) is True, "Realm save built: %s" % (r,))
    coop = snapshot(tmp, COOP)
    check(all(coop.get(k) == v for k, v in hw.items()), "co-op save holds the Realm's world")
    check(all(coop.get(k) == v for k, v in ch.items()), "co-op save holds the Realm character + sidecars")
    t = L.eval('{ slotguard.read_realm(...) }', COOP)
    w2, c2 = t[1], t[2]
    check(w2 is not None and all(w2[k] == v.decode("latin-1") or w2[k] == v for k, v in hw.items() if k != "Thumb.sav"),
          "read_realm returns the world")
    check(c2 is not None and c2["_SDQuests.sav"] is not None, "read_realm returns the character")
    r = L.eval('slotguard.copy_character_home(...)', COOP, "S1")
    check(first(r) is None, "copy_character_home refuses a Realm session")
    check(snapshot(tmp, "S1") == own0, "own save untouched")
    L.eval('slotguard.purge(...)', COOP)
    r = L.eval('slotguard.build_realm(...)', COOP, lua_files(L, hw), None)
    check(first(r) is True and "Player.sav" not in snapshot(tmp, COOP), "no Realm character yet: world only (fresh character)")
    log_write(L, step="joined", own="S1", coop=COOP, own_stamp="x")
    r = L.eval('slotguard.build_realm(...)', COOP, lua_files(L, hw), None)
    check(first(r) is None, "build_realm refuses a log that isn't a Realm session")
    log_write(L, step="building", own="S1", coop=COOP, realm=REALM, own_stamp="x")
    r = L.eval('slotguard.build_realm(...)', COOP, lua_files(L, {"Level.sav": b"junk"}), None)
    check(first(r) is None, "a broken world isn't built")


@test
def session_startup_leaves_realm_session_to_realms(L, tmp):
    """A crash in a Realm: the session code must not copy the Realm character into the own save or purge it."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    guard(L, tmp)
    own0 = snapshot(tmp, "S1")
    log_write(L, step="joined", own="S1", coop=COOP, realm=REALM, gen="2", own_stamp="x")
    L.eval('slotguard.build_realm(...)', COOP, lua_files(L, world_files(b"realm")), lua_files(L, realm_character()))
    L.execute('session.preinit(CFG)')
    check(snapshot(tmp, "S1") == own0, "own save untouched")
    check(os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "the Realm session log is kept")
    check(snapshot(tmp, COOP).get("Player.sav") == realm_character()["Player.sav"], "the Realm save is kept")


REALM_FAKES = r'''
local dir = ...
REALM_ID = "4R5BJRNGWF"
SENT, ROLE, HOSTED, RESPAWNS = {}, nil, 0, 0
local lk = package.loaded["mirror.link"]
lk.dir = function() return dir end
lk.bridge_cmd = function(t) SENT[#SENT + 1] = t; return true end
package.loaded["mirror.menu"] = { role = function() return ROLE end, realm_host = function() HOSTED = HOSTED + 1 end,
    realm_join = function(s, w) JOINED = s end, realm_stop = function() ROLE = nil end }
PC.Svr_RequestRespawn_Random = function() RESPAWNS = RESPAWNS + 1 end
CFG.realms = { enabled = true }
realmplay = require("mirror.realmplay")
OPS = {}
function ANSWER(verb, text)
    for i = #SENT, 1, -1 do
        local seq, v = SENT[i]:match("^realm (%d+) (%S+)")
        if v == verb and not OPS[seq] then
            OPS[seq] = verb .. " " .. text
            local out = { "realms on 1", "lease " .. REALM_ID .. " held" }
            for s, x in pairs(OPS) do out[#out + 1] = "op " .. s .. " " .. x end
            out[#out + 1] = "END\n"
            local f = REAL.open(dir .. "\\mirror_realms.txt", "wb")
            f:write(table.concat(out, "\n"))
            f:close()
            return true
        end
    end
    return false
end
function LAST(verb) for i = #SENT, 1, -1 do if SENT[i]:match("^realm %d+ (%S+)") == verb then return SENT[i] end end end
function RTICK(n, dt)
    for _ = 1, n or 1 do
        require("mirror.util").new_frame()
        for _, fn in ipairs(TICKS) do fn(dt or 0.5) end
        session.tick(dt or 0.5)
        if SAVING > 0 then SAVING = SAVING - 1 end
    end
end
'''


@test
def realmplay_host_session(L, tmp):
    """Open a Realm nobody hosts: claim, download, own save kept, Realm save built and loaded, fresh character
    respawned, saves uploaded with the Realm character stored, firewall keeps saves in the Realm, leave goes home."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('realmplay.init(CFG)')
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    L.execute('realmplay.start(...)', REALM)
    check(L.eval('LAST("claim")') is not None, "lease claimed")
    L.eval('ANSWER("claim", "ok won 2")')
    L.execute('RTICK(1)')
    check(L.eval('LAST("download")') is not None, "newest world asked for")
    hw = world_files(b"realm")
    for n, d in hw.items():
        write(os.path.join(rdir, "down", n), d)
    write(os.path.join(rdir, "down", "mirror_coop_bed_names.txt"), b"1 2 3|Realm bed\n")
    write(os.path.join(rdir, "down", "mirror_host_settings.txt"), b"pvp on\n")
    L.eval('ANSWER("download", "ok 2 5")')
    L.execute('RTICK(1)')
    check(L.eval('SAVES') == 1 and L.eval('CURRENT') == "S1", "own world saved first")
    own_after_save = snapshot(tmp, "S1")
    L.execute('RTICK(5)')
    coop = snapshot(tmp, COOP)
    check(L.eval('LOADS[#LOADS]') == COOP and L.eval('CURRENT') == COOP, "the Realm save was loaded")
    check(all(coop.get(k) == v for k, v in hw.items() if k != "Slot.sav"), "Realm save holds the Realm's world")
    check("Player.sav" not in coop, "no Realm character yet: fresh")
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t is not None and t["realm"] == REALM and t["gen"] == "2" and t["own"] == "S1", "session log names the Realm + generation")
    L.execute('RTICK(8)')
    check(L.eval('RESPAWNS') == 1 and L.eval('HOSTED') == 1, "fresh character respawned, hosting started")
    check(L.eval('(realmplay.state())') == "playing", "playing (%s)" % L.eval('(realmplay.state())'))
    os.makedirs(os.path.join(saves(tmp), "MenuSlot"), exist_ok=True)
    L.execute('CURRENT = "MenuSlot"; require("mirror.save_guard").run_before_save(); PC:SaveGameToSlot()')
    check(L.eval('CURRENT') == COOP and os.listdir(os.path.join(saves(tmp), "MenuSlot")) == [], "firewall: saves stay in the Realm save")
    live = os.path.join(rdir, "live")
    bags = L.eval('session.data_file("mirror_coop_bags.txt")')
    check(os.path.normcase(bags) == os.path.normcase(os.path.join(live, "mirror_coop_bags.txt")), "bag owners go to the Realm: %s" % bags)
    check(read(os.path.join(live, "mirror_coop_bed_names.txt")) == b"1 2 3|Realm bed\n", "the Realm's bed names are in use")
    check(L.eval('require("mirror.hostrules").my_value("pvp")') == "on", "the Realm's host rules apply")
    write(bags, b"4 5 6|Ann's bag\n")
    L.execute('RTICK(130)')
    up = L.eval('LAST("upload")')
    check(up is not None and up.endswith(" 3"), "an upload of generation 3 after a save: %s" % up)
    staged = {n: read(os.path.join(rdir, "up", n)) for n in os.listdir(os.path.join(rdir, "up"))}
    check(staged.get("Level.sav") == hw["Level.sav"] and "Player.sav" not in staged, "upload holds the world, not the character")
    check(staged.get("mirror_coop_bags.txt") == b"4 5 6|Ann's bag\n" and staged.get("mirror_host_settings.txt", b"").startswith(b"pvp on"),
          "upload carries the Realm's sidecars")
    stored = os.path.join(rdir, "character", "Player.sav")
    check(os.path.exists(stored) and read(stored).startswith(b"EMSH Player.sav of " + COOP.encode()),
          "Realm character stored from the Realm save")
    L.eval('ANSWER("upload", "ok 3 1234")')
    L.execute('RTICK(1)')
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t["gen"] == "3", "session log follows the generation")
    L.execute('realmplay.leave()')
    L.execute('RTICK(6)')
    check(L.eval('LAST("upload")').endswith(" 4"), "final upload at the end")
    L.eval('ANSWER("upload", "ok 4 1234")')
    L.execute('RTICK(4)')   # (the home load runs 2 frames after go_home)
    check(L.eval('LAST("release")') is not None, "lease released")
    check(L.eval('LOADS[#LOADS]') == "S1", "back in the own save")
    check(not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "session log gone")
    check("Player.sav" not in snapshot(tmp, COOP), "Realm save emptied")
    check(snapshot(tmp, "S1") == own_after_save, "own save untouched after its pre-Realm save")
    L.execute('RTICK(4)')
    check(L.eval('(realmplay.state())') == "idle", "Realm session over")
    check(read(os.path.join(rdir, "world", "head.txt")) == b"gen=4\n", "local world copy at generation 4")
    check(read(os.path.join(rdir, "world", "mirror_coop_bags.txt")) == b"4 5 6|Ann's bag\n", "local world copy keeps the sidecars")
    check("SurrounSyncRealms" not in L.eval('session.data_file("mirror_coop_bags.txt")'), "home: the own files again")
    check(L.eval('require("mirror.hostrules").my_value("pvp")') == "off", "home: my own host rules again")


@test
def realmplay_tab_model(L, tmp):
    """The REALMS tab's model: one row per listed Realm with the right button (OPEN / JOIN / START / none) and info,
    free only without a Realm or co-op session; inside a Realm the current one with its step text."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('realmplay.init(CFG)')
    write(os.path.join(link_dir, "mirror_realms.txt"), (
        "realms on 1\n"
        "realm 4R5BJRNGWF owner - 3 2 - Our Farm\n"
        "realm 7K2M9P4Q1Z member 76561197960266730 5 3 Ann_B Ann's Base\n"
        "realm 8ABCDEFGHJ owner - 0 1 - Empty One\n"
        "realm 9ABCDEFGHK offline - 0 0 - Old Copy\n"
        "END\n").encode())
    L.execute('RTICK(5)')
    L.execute('M = realmplay.model()')
    check(L.eval('#M.rows') == 4 and L.eval('M.service') == "on" and L.eval('M.free') is True, "4 rows, service on, free")
    check(L.eval('M.rows[1].open') == "OPEN" and "2 members" in L.eval('M.rows[1].info') and "save" not in L.eval('M.rows[1].info'),
          "nobody hosts: OPEN (%s)" % L.eval('M.rows[1].info'))
    check(L.eval('M.rows[2].open') == "JOIN" and L.eval('M.rows[2].live') is True and "Ann B is playing" in L.eval('M.rows[2].info'),
          "hosted: JOIN + live (%s)" % L.eval('M.rows[2].info'))
    check(L.eval('M.rows[3].open') == "START", "owner of an empty Realm: START")
    check(L.eval('M.rows[4].open') is None and "out of reach" in L.eval('M.rows[4].info'), "offline copy: no button")
    check(L.eval('M.current') is None and L.eval('M.hosting') is False, "no current Realm")
    L.execute('ROLE = "host"; M = realmplay.model()')
    check(L.eval('M.free') is False, "hosting co-op: not free to open a Realm")
    L.execute('ROLE = nil; realmplay.start(REALM_ID); M = realmplay.model()')
    check(L.eval('M.current and M.current.name') == "Our Farm" and L.eval('M.free') is False, "opening: current Realm shown")
    check(L.eval('M.state') == "Asking the Realm who's playing..." and L.eval('M.rows[1].here') is True, "step text + here mark")
    n = L.eval('#SENT')
    L.execute('realmplay.refresh_list(false)')
    check(L.eval('#SENT') == n, "list refresh rate-limited")


@test
def realmplay_card_name_from_late_list(L, tmp):
    """Opened before the list came in (dev/KEY path): the card shows the code, then the Realm's name once listed."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('realmplay.init(CFG)')
    L.execute('realmplay.start(REALM_ID); M = realmplay.model()')
    code = L.eval('require("mirror.realm").code(REALM_ID)')
    check(L.eval('M.current.name') == code, "no list yet: card shows the code (%s)" % L.eval('M.current.name'))
    write(os.path.join(link_dir, "mirror_realms.txt"), b"realms on 1\nrealm 4R5BJRNGWF owner - 3 2 - Our Farm\nEND\n")
    L.execute('RTICK(5); M = realmplay.model()')
    check(L.eval('M.current.name') == "Our Farm", "list arrived: card shows the name (%s)" % L.eval('M.current.name'))


@test
def realmplay_members_and_left_guest(L, tmp):
    """A guest who left a world (link role still "guest", session idle) may open Realms; a visiting member gets the
    card with every member listed, the ones playing first (hosting / here)."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('realmplay.init(CFG)')
    write(os.path.join(link_dir, "mirror_realms.txt"), (
        "realms on 1\n"
        "realm 7K2M9P4Q1Z member 76561197960266730 5 3 Ann_B Ann's Base\n"
        "member 7K2M9P4Q1Z member - 0 Cy\n"
        "member 7K2M9P4Q1Z owner 76561197960266730 1790000000 Ann B\n"
        "member 7K2M9P4Q1Z member 76561197960266731 1790000000 Test-guest\n"
        "member 4R5BJRNGWF owner - 0 Stray\n"
        "END\n").encode())
    L.execute('RTICK(5)')
    L.execute('ROLE = "guest"; M = realmplay.model()')
    check(L.eval('M.free') is True and L.eval('M.current') is None, "left guest (role guest, idle): free to open")
    L.execute('package.loaded["mirror.link"].lobby = function() return { name = "Test-guest", peer = { name = "Ann B", connected = true } } end')
    L.execute('session.realm_joined = function() return "7K2M9P4Q1Z" end; M = realmplay.model()')
    check(L.eval('M.visiting') is True and L.eval('M.current.id') == "7K2M9P4Q1Z", "visiting member: card shown")
    people = L.eval('M.current.people')
    check(people == "Ann B (owner) - hosting     Test-guest - here     Cy", "who's in, playing first: %r" % people)
    check(L.eval('#require("mirror.realm").find("7K2M9P4Q1Z").people') == 3, "a member line of another Realm is not attached")
    L.execute('ROLE = "host"; session.realm_joined = function() return nil end; M = realmplay.model()')
    check(L.eval('M.free') is False, "hosting: not free")


@test
def realmplay_first_list_waits_for_the_bridge(L, tmp):
    """The bridge deletes its command file at start: the first list waits until its Realms file was written this
    run (an old file doesn't count), then goes once; the page asking early doesn't lose it."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    write(os.path.join(link_dir, "mirror_realms.txt"), b"realms on 1\nEND\n")   # last run's file
    L.execute('realmplay.init(CFG); RTICK(5); realmplay.refresh_list(true); RTICK(3)')
    lists = lambda: L.eval('(function() local n = 0; for _, s in ipairs(SENT) do if s:match("^realm %d+ list") then n = n + 1 end end; return n end)()')
    check(lists() == 0, "bridge not up yet (old Realms file): no list sent (%d)" % lists())
    write(os.path.join(link_dir, "mirror_realms.txt"), ("realms on %d\nEND\n" % int(time.time())).encode())
    L.execute('RTICK(5)')
    check(lists() == 1, "bridge wrote its file this run: the waiting list goes once (%d)" % lists())


@test
def current_slot_when_ems_never_confirms(L, tmp):
    """In-game EMS DoesSaveSlotExist never said yes: the current save must still count (its folder is on disk),
    not the newest save - after a Realm that was the Realm's co-op slot and START refused."""
    make_slot(tmp, "S1")
    make_slot(tmp, "SurrounSync_Session_1", b"coop")
    session_rt(L, tmp)
    L.execute('EMSLIB.DoesSaveSlotExist = function() return false end; CURRENT = "S1"; session.preinit(CFG)')
    cur = L.eval('(session.current_slot())')
    check(cur == "S1", "current slot = the EMS current save on disk (%s)" % cur)
    L.execute('CURRENT = "..\\\\x"')
    check(L.eval('require("mirror.slotguard").on_disk(CURRENT)') is False, "a name with path characters is never a slot")


@test
def realmplay_hosted_realm_joins_host(L, tmp):
    """Someone already hosts the Realm: the claim answer sends us to them as a normal join; nothing is saved or built."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    L.execute(REALM_FAKES, os.path.join(tmp, "SurrounDead"))
    L.execute('realmplay.init(CFG)')
    L.execute('realmplay.start(...)', REALM)
    L.eval('ANSWER("claim", "ok hosted 76561197960266730 Ann B")')
    L.execute('RTICK(2)')
    check(L.eval('LAST("download")') is not None and L.eval('JOINED') is None, "first visit: the world (with its starter) comes first")
    L.eval('ANSWER("download", "ok none")')
    L.execute('RTICK(2)')
    check(L.eval('JOINED') == "76561197960266730", "joined the lease holder")
    check(L.eval('SAVES') == 0 and L.eval('(realmplay.state())') == "idle", "nothing saved, no Realm session")


@test
def realmplay_crash_rescue(L, tmp):
    """A crash inside a Realm: next start stores the Realm character and keeps the world for the next upload."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    guard(L, tmp)
    own0 = snapshot(tmp, "S1")
    log_write(L, step="joined", own="S1", coop=COOP, realm=REALM, gen="5", own_stamp="x")
    L.eval('slotguard.build_realm(...)', COOP, lua_files(L, world_files(b"crash")), lua_files(L, realm_character(b"crashchar")))
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('realmplay.init(CFG)')
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    check(read(os.path.join(rdir, "character", "Player.sav")) == realm_character(b"crashchar")["Player.sav"], "Realm character rescued")
    check(read(os.path.join(rdir, "pending", "base.txt")) == b"gen=5\n" and
          read(os.path.join(rdir, "pending", "Level.sav")) == world_files(b"crash")["Level.sav"], "world kept as pending on generation 5")
    check(not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "session log cleared")
    check("Player.sav" not in snapshot(tmp, COOP), "Realm save emptied")
    check(snapshot(tmp, "S1") == own0, "own save untouched")


def create_rt(L, tmp):
    """own save S1, Realms on; the New Game Play hook and the main-menu callback captured for the test"""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('HOOKS = {}; require("mirror.util").ensure_hook = function(p, pre) HOOKS[p] = pre; return true end; '
              'session.on_main_menu = function(fn) MAIN_MENU = fn end')
    L.execute('realmplay.init(CFG)')
    L.execute('realmplay.create("Our Realm")')
    check(L.eval('LAST("create")').endswith(" create Our Realm"), "Realm created on the server: %s" % L.eval('LAST("create")'))
    L.eval('ANSWER("create", "ok %s Our Realm")' % REALM)
    L.execute('RTICK(1)')
    check(L.eval('(realmplay.state())') == "armed", "waiting for a New Game (%s)" % L.eval('(realmplay.state())'))
    return os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)


def press_play(L):
    L.execute('MAIN_MENU(); WORLD_PLAYER = PLAYER; PLAYER = nil')
    L.execute('for p, fn in pairs(HOOKS) do if p:find("PlayButton", 1, true) then fn() end end')


@test
def realmplay_create_new_world(L, tmp):
    """CREATE: the New Game's world saves only into a fresh co-op save, becomes generation 1, its character the starter."""
    rdir = create_rt(L, tmp)
    own0 = snapshot(tmp, "S1")
    press_play(L)
    check(L.eval('(realmplay.state())') == "new_game" and L.eval('CURRENT') == COOP, "Play: EMS points at the co-op save")
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t is not None and t["realm"] == REALM and t["gen"] == "0" and t["own"] == "S1", "session log: Realm at generation 0")
    nw = world_files(b"newgame")
    for n in ("Level.sav", "General.sav", "Difficulties.sav"):
        write(os.path.join(saves(tmp), COOP, n), nw[n])
    L.execute('PLAYER = WORLD_PLAYER; CURRENT = "S1"')   # (a stale current save, as in experiment E8)
    L.execute('RTICK(16)')
    check(L.eval('LAST("claim")') is not None, "lease claimed after the first save")
    check(snapshot(tmp, "S1") == own0, "the new world never saved into the own save")
    L.eval('ANSWER("claim", "ok won 0")')
    L.execute('RTICK(1)')
    check(L.eval('(realmplay.state())') == "playing" and L.eval('HOSTED') == 1, "hosting the new Realm")
    up = L.eval('LAST("upload")')
    check(up is not None and up.endswith(" 1"), "generation 1 uploaded: %s" % up)
    staged = {n: read(os.path.join(rdir, "up", n)) for n in os.listdir(os.path.join(rdir, "up"))}
    coop_player = read(os.path.join(saves(tmp), COOP, "Player.sav"))
    check(staged.get("Level.sav") == nw["Level.sav"] and staged.get("starter_Player.sav") == coop_player,
          "the upload holds the new world + the starter character")
    check(read(os.path.join(rdir, "character", "Player.sav")) == coop_player, "creator's Realm character stored")


AUTO_FAKES = r'''
LEVELS, ASYNC, PRESSED_NEW = {}, nil, 0
function ExecuteInGameThread(fn) fn() end
function LoopAsync(ms, fn) ASYNC = fn end
function FName(s) return s end
local gi_load = GI.Event_LoadLevel
GI.Event_LoadLevel = function(self, l) LEVELS[#LEVELS + 1] = l; return gi_load(self, l) end
MENU_UP = false
MENU_W = { IsValid = function() return true end, IsInViewport = function() return MENU_UP end,
    BndEvt__Play_K2Node_ComponentBoundEvent_11_OnButtonClickedEvent__DelegateSignature = function() PRESSED_NEW = PRESSED_NEW + 1 end }
KEY_UP, KEY_RUN = false, nil
KEY_W = { IsValid = function() return true end, IsInViewport = function() return KEY_UP end,
    ExecuteUbergraph_PressAnyKeyWidget = function(_, at) KEY_RUN = at; KEY_UP = false; MENU_UP = true end }
-- (in-game the main menu from the game's start is still around, off the screen: it comes first)
STALE_MENU = { IsValid = function() return true end, IsInViewport = function() return false end }
local ffo, fao = FindFirstOf, FindAllOf
function FindFirstOf(c)
    if c == "MenuWidget_C" then return STALE_MENU end
    if c == "PressAnyKeyWidget_C" then return KEY_W end
    return ffo(c)
end
function FindAllOf(c) if c == "MenuWidget_C" then return { STALE_MENU, MENU_W } end return fao(c) end
function POLL(n) for _ = 1, n do if ASYNC and ASYNC() then ASYNC = nil end end end
'''


@test
def realmplay_create_takes_player_to_new_game(L, tmp):
    """CREATE goes to the main menu by itself after a moment, waits there until the menu is up, then presses NEW
    GAME once; CANCEL before leaving keeps the player in their world."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.preinit(CFG)')
    L.execute(REALM_FAKES, os.path.join(tmp, "SurrounDead"))
    L.execute(AUTO_FAKES)
    L.execute('HOOKS = {}; require("mirror.util").ensure_hook = function(p, pre) HOOKS[p] = pre; return true end; '
              'session.on_main_menu = function(fn) MAIN_MENU = fn end')
    L.execute('realmplay.init(CFG)')
    L.execute('realmplay.create("Our Realm")')
    L.eval('ANSWER("create", "ok %s Our Realm")' % REALM)
    L.execute('RTICK(2)')
    check(L.eval('(realmplay.state())') == "armed" and L.eval('#LEVELS') == 0, "armed, still in the world for a moment (CANCEL)")
    L.execute('RTICK(6)')
    check(L.eval('LEVELS[1]') == "MainMenu", "then to the main menu: %s" % L.eval('LEVELS[1]'))
    L.execute('RTICK(6)')
    check(L.eval('#LEVELS') == 1, "only once")
    # (session.loading() stays true at the main menu in-game: no world player clears it)
    L.execute('MAIN_MENU(); PLAYER = nil; local real = session.loading; session.loading = function() return true end; UNLOAD = real')
    L.execute('POLL(20)')
    check(L.eval('PRESSED_NEW') == 0, "the menu isn't up yet: nothing pressed")
    L.execute('KEY_UP = true; POLL(4)')
    check(L.eval('KEY_RUN') is None, "PRESS ANY KEY just faded in: waits")
    L.execute('POLL(5)')
    check(L.eval('KEY_RUN') == 167, "then runs what a key press does (ubergraph 167): %s" % L.eval('KEY_RUN'))
    L.execute('POLL(5)')
    check(L.eval('PRESSED_NEW') == 0, "menu just came up: waits for its fade-in")
    L.execute('POLL(20)')
    check(L.eval('PRESSED_NEW') == 1 and L.eval('ASYNC') is None, "NEW GAME pressed once, polling stopped")
    check(L.eval('(realmplay.state())') == "armed", "still waiting for the New Game's PLAY")
    # CANCEL in the world before leaving
    L.execute('realmplay.cancel_create(); PLAYER = PC; session.loading = UNLOAD')
    L.execute('realmplay.create("Second")')
    L.eval('ANSWER("create", "ok %s Second")' % REALM)
    L.execute('RTICK(2); realmplay.cancel_create(); RTICK(10)')
    check(L.eval('#LEVELS') == 1 and L.eval('(realmplay.state())') == "idle", "CANCEL: stays in the world")


@test
def realmplay_create_cancelled_by_a_load(L, tmp):
    create_rt(L, tmp)
    L.execute('MAIN_MENU(); RTICK(1)')
    check(L.eval('(realmplay.state())') == "armed", "the world being left ticks once more: still armed (in-game bug)")
    # a save loaded from the menu: a new player of that world
    L.execute('PLAYER = setmetatable({ addr = 99, GetAddress = function() return 99 end }, { __index = PLAYER }); RTICK(2)')
    check(L.eval('(realmplay.state())') == "idle", "a save loaded instead of New Game: nothing made")
    check(not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "no session log")


@test
def realm_starter_travels_and_is_used(L, tmp):
    """The starter character comes in the bundle (a damaged one is left out, not the world) and is a newcomer's first."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    sc = realm_character(b"starter")
    for n, d in world_files(b"w").items():
        write(os.path.join(rdir, "down", n), d)
    write(os.path.join(rdir, "down", "starter_Player.sav"), b"junk that is no save")
    check(L.eval('require("mirror.realm").accept_download(...)', REALM, 3) == 3, "a damaged starter doesn't sink the world")
    check(L.eval('require("mirror.realm").starter(...)', REALM) is None, "damaged starter left out")
    for n, d in sc.items():
        write(os.path.join(rdir, "down", "starter_" + n), d)
    L.eval('require("mirror.realm").accept_download(...)', REALM, 4)
    check(L.eval('require("mirror.realm").starter(...)', REALM) is not None, "starter kept with the world")
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.realm_guest(...); session.request_toggle(); TICK(6)', REALM)
    host_answers(L, world_files(b"realmhost"))
    L.execute('TICK(4)')
    check(snapshot(tmp, COOP).get("Player.sav") == sc["Player.sav"], "first visit: the starter character")


@test
def realm_add_to_realm_over_the_link(L, tmp):
    """ADD TO REALM: the host's bridge makes an invite code, it crosses the co-op link, the friend's bridge redeems it once."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute(REALM_FAKES, os.path.join(tmp, "SurrounDead"))
    L.execute('package.loaded["mirror.link"].peer_state = function() return "ok" end; realmplay.init(CFG)')
    L.execute('require("mirror.realmmembers").add(...)', REALM, "Our Realm")
    check(L.eval('LAST("invite")') is not None, "host asks its bridge for an invite code")
    L.eval('ANSWER("invite", "ok ABCDEFGHJKMNPQRS")')
    L.execute('RTICK(1)')
    sent = L.eval('BLOBS_OUT["realm_invite"]')
    check(sent == REALM + " ABCDEFGHJKMNPQRS Our Realm", "the code goes over the link: %s" % sent)
    L.execute('ROLE = "guest"; BLOBS_IN["realm_invite"] = BLOBS_OUT["realm_invite"]; RTICK(3)')
    check((L.eval('LAST("redeem")') or "").endswith(" redeem ABCDEFGHJKMNPQRS"), "the guest redeems it")
    L.eval('ANSWER("redeem", "ok %s Our Realm")' % REALM)
    L.execute('RTICK(3)')
    check(L.eval('note_has("member of the Realm Our Realm")') is True, "the guest is told")
    n = L.eval('(function() local n = 0 for _, s in ipairs(SENT) do if s:find(" redeem ", 1, true) then n = n + 1 end end return n end)()')
    check(n == 1, "redeemed once, not every poll (%d)" % n)


def realm_guest_session(L, tmp, character=None):
    """own save S1, Realm member (with this stored Realm character or none), joins the Realm's host"""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    if character:
        check(first(L.eval('require("mirror.realm").store_character(...)', REALM, lua_files(L, character))) is True,
              "Realm character stored before the visit")
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.realm_guest(...)', REALM)
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    before = snapshot(tmp, "S1")
    host_answers(L, world_files(b"realmhost"))
    L.execute('TICK(4)')
    return before, rdir


@test
def realm_character_held_after_an_empty_arrival(L, tmp):
    # K3YBOARD32 2026-10-29: the stored Realm character loaded without its inventory (EMS cache, DBG-20261028-001),
    # the mod gave it empty pockets, and the next saves wrote the empty character over the good one for good.
    # Held, the good one stays on disk and the next Realm load brings it back.
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    rc, empty = realm_character(b"member"), realm_character(b"empty")
    L.execute('rm = require("mirror.realm")')
    check(first(L.eval('rm.store_character(...)', REALM, lua_files(L, rc))) is True, "(setup) the good character is stored")
    L.eval('rm.hold_character(..., "arrived without its inventory")', REALM)
    r = L.eval('(function(...) local a, b = rm.store_character(...); return tostring(a) .. " " .. tostring(b) end)(...)',
               REALM, lua_files(L, empty))
    check(r == "true held", "held: storing reports done without writing (%s)" % r)
    with open(os.path.join(rdir, "character", "Player.sav"), "rb") as f:
        check(f.read() == rc["Player.sav"], "the good character is still on disk")
    check(os.path.exists(os.path.join(rdir, "character_hold.txt")), "the hold is a file (a restart keeps it)")
    L.execute('session.init(CFG, "guest", function() return true end); session.realm_guest(...)', REALM)
    L.execute('session.request_toggle(); TICK(6)')
    host_answers(L, world_files(b"realmhost"))
    L.execute('TICK(4)')
    check(L.eval('rm.character_held(...)', REALM) is False, "the next Realm join clears the hold")
    check(snapshot(tmp, COOP).get("Player.sav") == rc["Player.sav"], "...and plays the kept character, items and all")


@test
def realm_guest_plays_realm_character(L, tmp):
    """Joining a Realm's host: the co-op save gets my Realm character (never my own), leaving stores it in the Realm."""
    rc = realm_character(b"member")
    before, rdir = realm_guest_session(L, tmp, rc)
    coop = snapshot(tmp, COOP)
    check(L.eval('session.state()') == "joined", "joined (%s)" % L.eval('session.state()'))
    check(coop.get("Player.sav") == rc["Player.sav"] and coop.get("Player.sav") != before["Player.sav"],
          "co-op save holds the Realm character, not the own one")
    check(coop.get("Level.sav") == world_files(b"realmhost")["Level.sav"], "co-op save holds the host's world")
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t is not None and t["realm"] == REALM and t["realm_role"] == "guest", "session log: Realm guest")
    check(L.eval('session.realm_joined()') == REALM, "session reports the Realm")
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    stored = read(os.path.join(rdir, "character", "Player.sav"))
    check(stored.startswith(b"EMSH Player.sav of " + COOP.encode()), "the played Realm character went back to the Realm store")
    check(snapshot(tmp, "S1") == before, "own save untouched by the Realm visit")
    check(L.eval('LOADS[#LOADS]') == "S1" and L.eval('session.state()') == "idle", "own save loaded, idle")
    check("Player.sav" not in snapshot(tmp, COOP), "co-op save emptied")
    # the next join is a normal one again (after the trip home)
    L.execute('TICK(30)')
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    host_answers(L)
    L.execute('TICK(4)')
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    check(t is not None and t["realm"] is None, "normal session log has no Realm")
    check(t is not None and snapshot(tmp, t["coop"]).get("Player.sav") == snapshot(tmp, "S1")["Player.sav"],
          "a later normal join carries the own character")


@test
def realm_guest_load_reads_the_realm_character_not_emss_cache(L, tmp):
    """Player report 2026-10-28: EMS caches a PlayerInfo for every slot folder at game start (an emptied co-op slot
    gets an empty one); a Realm join wrote the Realm character's PlayerInfo.sav and loaded the slot, the game took the
    cached empty one - 0 containers, empty pockets saved, and the empty character stored on leave."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    rc = realm_character(b"member")
    check(first(L.eval('require("mirror.realm").store_character(...)', REALM, lua_files(L, rc))) is True, "(setup) stored")
    L.execute('''
        local function save(name) return { name = name, IsValid = function() return true end } end
        local entries = { { k = "PlayerInfo@cso@S1", o = save("own") } }
        for i = 1, 8 do entries[#entries + 1] = { k = "PlayerInfo@cso@SurrounSync_Session_" .. i, o = save("coop" .. i) } end
        EMSOBJ.CachedCustomSaves = { ForEach = function(_, fn)
            for _, e in ipairs(entries) do fn(e.k, { get = function() return e.o end }) end
        end }
        RESETS = {}
        EMSLIB.ResetCustomSave = function(_, _, obj, kind) RESETS[#RESETS + 1] = { name = obj.name, kind = kind, loads = #LOADS } end''')
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.execute('session.realm_guest(...)', REALM)
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    loads0 = L.eval('#LOADS')
    host_answers(L, world_files(b"realmhost"))
    L.execute('TICK(4)')
    t = first(L.eval('require("mirror.slotguard").log_read()'))
    coop = t and t["coop"]
    want = "coop" + coop.rsplit("_", 1)[1] if coop else None
    resets = [(L.eval('RESETS[%d].name' % i), L.eval('RESETS[%d].kind' % i), L.eval('RESETS[%d].loads' % i))
              for i in range(1, L.eval('#RESETS') + 1)]
    check(L.eval('#LOADS') > loads0 and L.eval('LOADS[#LOADS]') == coop, "(setup) the Realm's co-op save was loaded (%s)" % coop)
    check(resets == [(want, 1, loads0)],
          "only that co-op slot's cached PlayerInfo is dropped (ClearMemory), before its load: %s" % resets)


@test
def load_runs_frames_after_animation_leaves_the_workers(L, tmp):
    """Report 2026-10-29 12:00:43 (ending a Realm while running): the cvars only stop new parallel animation tasks;
    destroying + loading in the same call waited for one already running in a hooked function -> deadlock on the Lua
    lock. The save name is set at once, the destroy + load LOAD_FRAMES frames later."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    n0 = L.eval('#LOADS')
    check(L.eval('session.load_slot("S1")') is True, "load_slot accepts the load")
    check(L.eval('CURRENT') == "S1", "the save name is set at once")
    check(L.eval('#LOADS') == n0, "no load in the same call")
    L.execute('TICK(1)')
    check(L.eval('#LOADS') == n0, "...nor the next frame")
    L.execute('TICK(1)')
    check(L.eval('#LOADS') == n0 + 1 and L.eval('LOADS[#LOADS]') == "S1", "the load runs 2 frames later")
    L.execute('TICK(3)')
    check(L.eval('#LOADS') == n0 + 1, "and only once")


@test
def save_before_a_pending_load_never_reaches_the_next_save(L, tmp):
    """Hardening 2026-10-28: load_slot sets the next save's name at once, the old world runs 2 more frames. A save then
    holds the OLD world (the co-op world, when leaving) and went into the next save - the own one. It goes to the
    scratch slot; the load still reads the slot it was asked for."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    before = snapshot(tmp, "S1")
    n0 = L.eval('#LOADS')
    L.execute('session.load_slot("S1"); require("mirror.save_guard").run_before_save(); PC:SaveGameToSlot()')
    check(snapshot(tmp, "S1") == before, "the own save is untouched by the old world's save")
    check(L.eval('CURRENT') == L.eval('CFG.phase2.coop_slot'), "the save went to the scratch slot (%s)" % L.eval('CURRENT'))
    L.execute('TICK(4)')
    check(L.eval('#LOADS') == n0 + 1 and L.eval('LOADS[#LOADS]') == "S1", "the load still runs, of S1")
    check(L.eval('CURRENT') == "S1", "and the game is pointed at S1 again (%s)" % L.eval('CURRENT'))


@test
def realm_guest_first_visit_is_fresh(L, tmp):
    """No Realm character yet: the co-op save has none (the game makes one); leaving stores the new one."""
    before, rdir = realm_guest_session(L, tmp)
    check(L.eval('session.state()') == "joined", "joined (%s)" % L.eval('session.state()'))
    check("Player.sav" not in snapshot(tmp, COOP), "no character in the co-op save: fresh")
    L.execute('session.request_toggle()')
    L.execute('TICK(6)')
    check(os.path.exists(os.path.join(rdir, "character", "Player.sav")), "the new Realm character is stored")
    check(snapshot(tmp, "S1") == before, "own save untouched")


@test
def realm_guest_crash_rescue(L, tmp):
    """A crash while visiting a Realm: the character is rescued into the Realm, the guest's world copy is not uploaded."""
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    guard(L, tmp)
    own0 = snapshot(tmp, "S1")
    log_write(L, step="joined", own="S1", coop=COOP, realm=REALM, realm_role="guest", own_stamp="x")
    L.eval('slotguard.build_realm(...)', COOP, lua_files(L, world_files(b"visit")), lua_files(L, realm_character(b"visitchar")))
    L.execute('session.preinit(CFG)')
    link_dir = os.path.join(tmp, "SurrounDead")
    L.execute(REALM_FAKES, link_dir)
    L.execute('CFG.realms.enabled = false')   # (rescued even with Realms off: the log would block joins)
    L.execute('realmplay.init(CFG)')
    rdir = os.path.join(link_dir, "Saved", "SurrounSyncRealms", REALM)
    check(read(os.path.join(rdir, "character", "Player.sav")) == realm_character(b"visitchar")["Player.sav"], "Realm character rescued")
    check(not os.path.exists(os.path.join(rdir, "pending")), "the guest's world copy is never kept for upload")
    check(not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "session log cleared")
    check(snapshot(tmp, "S1") == own0, "own save untouched")


@test
def realm_needs_an_unused_coop_slot(L, tmp):
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    n = L.eval('CFG.phase2.coop_slots or 1')
    names = [L.eval('session.next_coop_slot()') for _ in range(n)]
    check(all(names) and len(set(names)) == n, "each slot once: %s" % names)
    check(L.eval('session.next_coop_slot()') is None, "no reuse for a Realm (EMS keeps its cache)")


@test
def session_garbage_log_quarantined(L, tmp):
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    session_rt(L, tmp)
    m = os.path.join(saves(tmp), "mirror_coop_session.txt")
    write(m, b"\x00garbage\x01")
    before = snapshot(tmp, "S1")
    L.execute('session.preinit(CFG)')
    closed = [f for f in os.listdir(saves(tmp)) if f.startswith("mirror_coop_session.txt.closed-")]
    bk = os.path.join(tmp, "SurrounDead", "Saved", "SurrounSyncBackups", COOP)
    rescued = os.path.isdir(bk) and any(os.path.exists(os.path.join(bk, d, "Player.sav")) for d in os.listdir(bk))
    check(snapshot(tmp, "S1") == before and not os.path.exists(m) and not os.path.exists(m + ".mirror-bad") and len(closed) == 1,
          "garbage session log: own save untouched, log archived (no longer blocks joins)")
    check(rescued, "...the co-op character it may have held is kept in Backups")
    check(not L.eval('require("mirror.slotguard").log_exists()'), "joining is possible again")


@test
def session_unfinishable_never_blocks_for_good(L, tmp):
    # the own save was renamed/deleted while a session was open: copying home can never work -> rescue, close
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    session_rt(L, tmp)
    L.execute('local d = ... ; require("mirror.backups").configure{ saves_dir = d }; '
              'require("mirror.slotguard").configure{ saves_dir = d, coop_base = "SurrounSync_Session" }', saves(tmp))
    stamp = L.eval('require("mirror.slotguard").stamp("S1")')
    L.eval('require("mirror.slotguard").log_write(...)', L.table_from(
        {"step": "joined", "own": "S1", "coop": COOP, "own_stamp": stamp, "home": "1.0 2.0 3.0 4.0"}))
    shutil.move(os.path.join(saves(tmp), "S1"), os.path.join(saves(tmp), "S1renamed"))
    L.execute('session.preinit(CFG)')
    bk = os.path.join(tmp, "SurrounDead", "Saved", "SurrounSyncBackups", COOP)
    check(os.path.isdir(bk) and len(os.listdir(bk)) >= 1, "own save gone: the co-op character is kept in Backups")
    check(not L.eval('require("mirror.slotguard").log_exists()'), "...and the session no longer blocks joins")
    # a quarantine an older version left behind blocked every join for good
    m = os.path.join(saves(tmp), "mirror_coop_session.txt")
    write(m + ".mirror-bad", b"\x00old garbage")
    L.execute('session.preinit(CFG)')
    check(not os.path.exists(m + ".mirror-bad") and not L.eval('require("mirror.slotguard").log_exists()'),
          "an old .mirror-bad is closed at the next start")


@test
def session_restore_at_start(L, tmp):
    files = make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('local d = ... ; local b = require("mirror.backups"); b.configure{ saves_dir = d }; '
              'FOLDER = b.take{ slot = "S1", reason = "before joining" }; b.request_restore("S1", FOLDER)', saves(tmp))
    write(os.path.join(saves(tmp), "S1", "Player.sav"), EMSH + b"later")
    L.execute('session.preinit(CFG)')
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")) == files[os.path.join(saves(tmp), "S1", "Player.sav")],
          "a pending restore is applied at start")
    check(any(e["reason"] == "before restore" for e in listing(L, "S1"))
          and L.eval('require("mirror.backups").pending_restore()') is None
          and not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "backed up first, request + log cleared")


def joined_and_played(L, tmp):
    joined_session(L, tmp)
    L.execute('TICK(1); GAME_SAVE(); TICK(3)')
    return read(os.path.join(saves(tmp), COOP, "Player.sav"))


@test
def exit_menu_load_of_own_save(L, tmp):
    coop_char = joined_and_played(L, tmp)
    loads = L.eval('#LOADS')
    L.execute('CURRENT = "S1"; for _, f in ipairs(NEW_PLAYER) do f() end; TICK(1)')
    check(L.eval('session.state()') == "idle" and not L.eval('session.in_world()') and L.eval('session.where()') != "joined",
          "loading the own save from the game menu ends the session at once (%s)" % L.eval('session.where()'))
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")) == coop_char, "the co-op character went home")
    check(L.eval('#LOADS') == loads, "no reload in the first frame of the new level (in-game it hung the game, 2026-10-16)")
    L.execute('SAVING = 4; TICK(3)')
    check(L.eval('#LOADS') == loads, "...nor while the game is still loading/saving")
    L.execute('TICK(8)')
    check(L.eval('#LOADS') == loads + 1 and L.eval('LOADS[#LOADS]') == "S1", "own save reloaded once the level has settled")
    check(L.eval('note_has(...)', "Bringing your co-op character home..."), "player told")


@test
def join_waits_for_the_trip_home(L, tmp):
    joined_session(L, tmp)
    L.execute('session.request_toggle(); TICK(4)')
    check(L.eval('session.state()') == "idle", "(setup) back home, trip home still pending")
    L.execute('session.request_toggle(); TICK(1)')
    L.execute('BLOBS_OUT["req"] = nil; TICK(2)')
    check(L.eval('BLOBS_OUT["req"]') is None, "no join request while the trip home is pending")
    L.execute('TICK(30)')
    check(L.eval('BLOBS_OUT["req"]') is not None, "the join goes ahead once the player is home")


@test
def trip_home_keeps_a_new_session_log(L, tmp):
    joined_session(L, tmp)
    L.execute('session.request_toggle(); TICK(4)')
    L.eval('require("mirror.slotguard").log_write(...)', L.table_from({"step": "building", "own": "S1", "coop": COOP, "own_stamp": "x"}))
    L.execute('TICK(30)')
    check(os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "finishing a trip home never deletes another session's log")


@test
def exit_caught_before_the_load(L, tmp):
    coop_char = joined_and_played(L, tmp)
    loads = L.eval('#LOADS')
    L.execute('CURRENT = "S1"; session.on_load_level()')
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")) == coop_char, "character copied home before the load starts")
    check(L.eval('session.state()') == "idle" and L.eval('session.where()') != "joined", "sync stopped")
    L.execute('for _, f in ipairs(NEW_PLAYER) do f() end; TICK(12)')
    check(L.eval('#LOADS') == loads, "no second load by the mod")
    L.execute('session.request_toggle(); TICK(1)')


@test
def exit_menu_load_of_other_save(L, tmp):
    coop_char = joined_and_played(L, tmp)
    make_slot(tmp, "S2")
    loads = L.eval('#LOADS')
    L.execute('CURRENT = "S2"; for _, f in ipairs(NEW_PLAYER) do f() end; TICK(1)')
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")) == coop_char and L.eval('#LOADS') == loads,
          "another save loaded: character copied into the own save, nothing reloaded")
    check(L.eval('note_has(...)', "Your co-op character was saved to S1."), "player told")
    check(not os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "session log cleared")


@test
def exit_seen_by_the_periodic_check(L, tmp):
    joined_and_played(L, tmp)
    L.execute('CURRENT = "S1"; TICK(3)')
    check(L.eval('session.state()') == "idle", "detected within a few ticks even without a new-player event")


@test
def exit_not_on_own_loads(L, tmp):
    joined_session(L, tmp)
    L.execute('for _, f in ipairs(NEW_PLAYER) do f() end; TICK(3)')
    check(L.eval('session.state()') == "joined", "the mod's own load of the co-op save is not an exit")


def host_state(L, s):
    L.execute('PS = ... ; session.set_peer_state(function() return PS end)', s)


@test
def hostgone_countdown_then_home(L, tmp):
    joined_session(L, tmp)
    host_state(L, "gone")
    L.execute('TICK(1)')
    check(L.eval('note_has(...)', "Host's game closed. You go home with your character in 30 seconds."), "countdown message")
    check(L.eval('session.host_gone()') == 30, "host_gone() = seconds left (%s)" % L.eval('session.host_gone()'))
    L.execute('TICK(58)')
    check(L.eval('session.state()') == "joined", "still there at 29 s")
    check(L.eval('note_has(...)', "in 2 seconds."), "the live card counted down every second")
    L.execute('TICK(10)')
    check(L.eval('session.state()') == "idle" and L.eval('LOADS[#LOADS]') == "S1", "after 30 s the normal leave ran: home")


@test
def hostgone_host_back_cancels(L, tmp):
    joined_session(L, tmp)
    host_state(L, "gone")
    L.execute('TICK(24)')
    host_state(L, "ok")
    L.execute('TICK(1)')
    check(L.eval('note_has(...)', "Host is back.") and L.eval('session.host_gone()') is None, "host back: countdown cancelled")
    L.execute('TICK(70)')
    check(L.eval('session.state()') == "joined", "and the guest stays")


@test
def hostgone_paused_and_wait(L, tmp):
    joined_session(L, tmp)
    host_state(L, "paused")
    L.execute('TICK(70)')
    check(L.eval('note_has(...)', "Host's game isn't responding (paused, loading or frozen).") and L.eval('session.state()') == "joined",
          "paused host: a message, no countdown")
    host_state(L, "gone")
    L.execute('TICK(2); session.wait_for_host(); TICK(70)')
    check(L.eval('session.state()') == "joined" and L.eval('session.host_gone()') is None, "Wait: no automatic leave")
    L.execute('session.go_home_now(); TICK(8)')
    check(L.eval('session.state()') == "idle", "Go home now leaves")


def settled(L, tmp):
    """joined, teleport next to the host done (in_world true)"""
    joined_session(L, tmp)
    L.execute('session.set_peer_locator(function() return { X = 1, Y = 2, Z = 3 } end); TICK(12)')
    check(L.eval('session.in_world()') is True, "(setup) joined and settled")


@test
def checkpoint_debounce_and_interval(L, tmp):
    settled(L, tmp)
    s0 = L.eval('SAVES')
    L.execute('session.checkpoint("drop"); TICK(2); session.checkpoint("drop"); TICK(9)')
    check(L.eval('SAVES') == s0, "no save yet 4.5 s after the second hand-over")
    L.execute('TICK(2)')
    check(L.eval('SAVES') == s0 + 1, "one save 5 s after the last of two hand-overs")
    L.execute('TICK(6); session.checkpoint("loot"); TICK(16)')
    check(L.eval('SAVES') == s0 + 1, "a hand-over 3 s later waits for the 20 s minimum interval")
    L.execute('TICK(20)')
    check(L.eval('SAVES') == s0 + 2, "then saves, 20 s after the first")
    check(L.eval('CURRENT') == COOP, "a joined guest's checkpoint saves go into the co-op save")


@test
def checkpoint_postponed_and_off(L, tmp):
    settled(L, tmp)
    s0 = L.eval('SAVES')
    L.execute('PLAYER["PlayerDead?"] = true; session.checkpoint("drop"); TICK(40)')
    check(L.eval('SAVES') == s0, "no checkpoint save while dead")
    L.execute('PLAYER["PlayerDead?"] = false; TICK(2)')
    check(L.eval('SAVES') == s0 + 1, "it happens once alive again")
    L.execute('CFG.save.checkpoints = false; session.checkpoint("drop"); TICK(60)')
    check(L.eval('SAVES') == s0 + 1, "save.checkpoints = false: never")


@test
def page_picks_newest_five_and_pinned(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    fixed_clock(L)
    names = []
    for i in range(9):
        bump(tmp, "S1", i); names.append(take(L, "S1"))
    got = L.eval('(function() local r = {} for i, e in ipairs(require("mirror.menu_backups").pick(require("mirror.backups").list("S1"))) do r[i] = e.folder end return r end)()')
    got = list(got.values())
    check(got == list(reversed(names[-5:])) + [names[0]], "newest 5, then the pinned first backup (%s)" % got)
    few = L.eval('#require("mirror.menu_backups").pick(require("mirror.backups").list("S1"), 20)')
    check(few == 9, "fewer than the limit: all of them, the pinned one not twice")


PLAYER_SET = ("Player.sav", "PlayerInfo.sav", "_SDQuests.sav", "_SkillTree.sav")


@test
def review_c1_copy_home_all_or_nothing(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    log_write(L, step="leaving", own="S1", coop=COOP, own_stamp=L.eval('slotguard.stamp("S1")'))
    own0, coop0 = snapshot(tmp, "S1"), snapshot(tmp, COOP)
    L.execute('inject(0)'); L.eval('slotguard.copy_character_home(...)', COOP, "S1"); total = L.eval('CALLS'); L.execute('uninject()')
    bad = []
    for n in range(1, total + 1):
        for k, v in own0.items():
            write(os.path.join(saves(tmp), "S1", k) if not k.startswith("_") else os.path.join(saves(tmp), "S1" + k), v)
        for k in list(snapshot(tmp, "S1")):
            if k.endswith(".mirror-old") or k.endswith(".mirror-new"):
                os.remove(os.path.join(saves(tmp), "S1", k))
        L.execute('inject(...)', n, "fail")
        r = first(L.eval('slotguard.copy_character_home(...)', COOP, "S1"))
        L.execute('uninject()')
        now = snapshot(tmp, "S1")
        all_old = all(now.get(k) == own0[k] for k in PLAYER_SET)
        all_new = all(now.get(k) == coop0[k] for k in PLAYER_SET)
        if not (all_old or all_new) or (r == "copied" and not all_new) or (r is None and not all_old):
            bad.append("call %d -> %s old=%s new=%s" % (n, r, all_old, all_new))
    check(total > 10 and not bad, "copy home with any failing file call: the whole set old or the whole set new (%d calls) %s" % (total, bad[:2]))


@test
def review_c1_no_purge_while_log(L, tmp):
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    session_rt(L, tmp)
    L.execute('local d = ... ; require("mirror.backups").configure{ saves_dir = d }; '
              'require("mirror.slotguard").configure{ saves_dir = d, coop_base = "SurrounSync_Session" }', saves(tmp))
    L.eval('require("mirror.slotguard").log_write(...)', L.table_from({"step": "leaving", "own": "S1", "coop": COOP,
                                                                        "own_stamp": L.eval('require("mirror.slotguard").stamp("S1")')}))
    L.execute('require("mirror.slotguard").copy_character_home = function() return nil, "locked" end')
    L.execute('session.preinit(CFG)')
    check(os.path.exists(os.path.join(saves(tmp), COOP, "Player.sav")), "copy failed at start: the co-op save is NOT emptied")
    check(os.path.exists(os.path.join(saves(tmp), "mirror_coop_session.txt")), "...and the session log stays for the next start")
    t2 = os.path.join(tmp, "b"); os.makedirs(t2)
    os.environ["LOCALAPPDATA"] = t2
    L2 = fresh(t2)
    make_slot(t2, "S1"); make_slot(t2, COOP, tag=b"coop")
    session_rt(L2, t2)
    write(os.path.join(saves(t2), "mirror_coop_session.txt"), b"\x00garbage")
    L2.execute('session.preinit(CFG)')
    check(os.path.exists(os.path.join(saves(t2), COOP, "Player.sav")), "garbage log: the co-op saves are left alone too")
    os.environ["LOCALAPPDATA"] = tmp


@test
def review_i1_no_duplicate_backups(L, tmp):
    make_slot(tmp, "S1")
    configure_backups(L, tmp)
    fixed_clock(L)
    a = take(L, "S1"); b = take(L, "S1", "before going home")
    check(a is not None and b == a and len(listing(L, "S1")) == 1, "an identical save isn't backed up twice (%s / %s)" % (a, b))
    make_slot(tmp, COOP, tag=b"coop")
    keep = take(L, "S1", "co-op character not applied", "character", COOP)
    for i in range(14):
        write(os.path.join(saves(tmp), "S1", "Slot.sav"), EMSH + b"save %d" % i)
        take(L, "S1", "before joining")
    check(any(e["folder"] == keep for e in listing(L, "S1")), "a 'co-op character not applied' backup is never pruned")


@test
def review_i2_failed_restore_retried(L, tmp):
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('local d = ... ; local b = require("mirror.backups"); b.configure{ saves_dir = d }; '
              'FOLDER = b.take{ slot = "S1", reason = "before joining" }; b.request_restore("S1", FOLDER)', saves(tmp))
    write(os.path.join(saves(tmp), "S1", "Player.sav"), EMSH + b"later")
    L.execute('local sg = require("mirror.slotguard"); local real = sg.apply_restore; '
              'sg.apply_restore = function() return nil, "locked", false end')
    L.execute('session.preinit(CFG)')
    check(L.eval('require("mirror.backups").pending_restore()') is not None, "an I/O failure keeps the restore request for the next start")
    check(read(os.path.join(saves(tmp), "S1", "Player.sav")) == EMSH + b"later", "and the save is unchanged")


@test
def review_i3_no_join_while_log(L, tmp):
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "guest", function() return true end)')
    L.eval('require("mirror.slotguard").log_write(...)', L.table_from({"step": "leaving", "own": "S1", "coop": COOP}))
    L.execute('session.request_toggle(); TICK(6)')
    check(L.eval('BLOBS_OUT["req"]') is None and L.eval('session.state()') == "idle", "an unfinished session blocks a new join")


@test
def review_i4_unreadable_stamp_is_a_retry(L, tmp):
    guard(L, tmp)
    make_slot(tmp, "S1")
    make_slot(tmp, COOP, tag=b"coop")
    log_write(L, step="leaving", own="S1", coop=COOP, own_stamp=L.eval('slotguard.stamp("S1")'))
    os.remove(os.path.join(saves(tmp), "S1", "Slot.sav"))
    r = first(L.eval('slotguard.copy_character_home(...)', COOP, "S1"))
    check(r is None, "own Slot.sav unreadable: retry later, not 'kept' (%s)" % r)


@test
def review_i5_countdown_keeps_going(L, tmp):
    joined_session(L, tmp)
    host_state(L, "gone")
    L.execute('TICK(10)')
    host_state(L, "unknown")
    L.execute('TICK(30)')
    host_state(L, "paused")
    L.execute('TICK(30)')
    check(L.eval('session.state()') == "idle", "once gone, only 'ok' stops the countdown (unknown/paused don't stall it)")


@test
def review_i6_host_checkpoints_only_with_guest(L, tmp):
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('session.init(CFG, "host", function() return true end); GUEST_IN = false; '
              'session.set_guest_in(function() return GUEST_IN end)')
    s0 = L.eval('SAVES')
    L.execute('session.checkpoint("drop"); TICK(30)')
    check(L.eval('SAVES') == s0, "host alone: no checkpoint saves")
    L.execute('GUEST_IN = true; session.checkpoint("drop"); TICK(30)')
    check(L.eval('SAVES') == s0 + 1, "host with a guest in its world: checkpoint save")


@test
def join_kind_must_match_the_hosts_world(L, tmp):
    # 2026-10-28: a co-op request still waiting when the friend opened a Realm was auto-accepted (Realm member)
    # and the guest walked into the Realm with its own character and gear. The guest says which join it is; the
    # host refuses the wrong kind before sending any world.
    make_slot(tmp, "S1")
    session_rt(L, tmp)
    L.execute('package.loaded["mirror.phase1"] = { stop = function() STOPPED = true end }')
    L.execute('session.init(CFG, "guest", function() return true end); session.request_toggle(); TICK(6)')
    req = L.eval('BLOBS_OUT["req"]') or ""
    check(req.startswith("join ") and req.endswith(" coop"), "a co-op join says so (%s)" % req)
    nonce = req.split(" ")[1]
    L.eval('(function(n) BLOBS_IN["joinwhy"] = n .. " realm"; BLOBS_IN["world"] = "fail " .. n end)(...)', nonce)
    L.execute('TICK(2)')
    check(L.eval('session.state()') == "idle" and L.eval('STOPPED') is True,
          "refused because the host plays a Realm: stays home and drops the link")
    check(L.eval('note_has(...)', "is playing a Realm right now"), "and is told to use the REALMS tab")

    L2 = fresh(tmp)
    session_rt(L2, tmp)
    L2.execute('HOSTING = 7; package.loaded["mirror.realmplay"] = { hosting_id = function() return HOSTING end, '
               'hosting = function() return HOSTING and "Camp" end }')
    L2.execute('session.init(CFG, "host", function() return true end)')
    L2.execute('BLOBS_IN["req"] = "join 100 coop"; TICK(1)')
    check(L2.eval('BLOBS_OUT["world"]') == "fail 100" and L2.eval('BLOBS_OUT["joinwhy"]') == "100 realm",
          "hosting a Realm: a co-op join is refused before any world is sent")
    L2.execute('BLOBS_OUT = {}; BLOBS_IN["req"] = "join 101 realm 7"; TICK(1)')
    check(L2.eval('BLOBS_OUT["world"]') is None and L2.eval('note_has(...)', "is joining Camp"),
          "a join to this Realm goes ahead")
    L2.execute('BLOBS_OUT = {}; HOSTING = nil; BLOBS_IN["req"] = "join 102 realm 7"; TICK(1)')
    check(L2.eval('BLOBS_OUT["joinwhy"]') == "102 notrealm", "a Realm join to a host not running that Realm is refused")
    L2.execute('BLOBS_OUT = {}; BLOBS_IN["req"] = "join 103"; TICK(1)')
    check(L2.eval('BLOBS_OUT["world"]') is None, "an older guest's plain co-op request still joins a co-op host")


@test
def review_i7_leave_waits_for_respawn(L, tmp):
    joined_session(L, tmp)
    L.execute('PLAYER["PlayerDead?"] = true; session.request_toggle(); TICK(20)')
    check(L.eval('session.state()') == "joined", "dead: the leave waits")
    check(L.eval('note_has(...)', "once you respawn"), "player told")
    L.execute('PLAYER["PlayerDead?"] = false; TICK(30)')
    check(L.eval('session.state()') == "idle", "respawned: the leave happens")


@test
def notify_paced_deduped_keyed(L, tmp):
    L.execute(r'''
        SHOWN = {}
        function FText(s) return s end
        package.loaded["mirror.game"] = { player = function() return {
            IsValid = function() return true end,
            CreateNotificationUI = function(_, text, img, color, delay) SHOWN[#SHOWN + 1] = { text = text, delay = delay } end } end }
        notify = require("mirror.notify")
        notify.configure({})
        function RUN(s) for _ = 1, math.floor(s / 0.1 + 0.5) do notify.tick(0.1) end end
    ''')
    L.execute('T = notify._test; function N() return #T.cards() end; function C(i) return T.cards()[i] end')
    L.execute('notify.show("joined the host", "good"); notify.show("joined the host", "good"); RUN(0.1)')
    check(L.eval('N()') == 1 and L.eval('C(1).count') == 2, "the same message twice: one card, counted x2")
    check(L.eval('C(1).text') == "Joined the host", "first letter capitalized (%s)" % L.eval('C(1).text'))
    L.execute('RUN(30); T.reset(); for _, s in ipairs({ "a", "b", "c", "d", "e" }) do notify.show(s) end; RUN(0.1)')
    check(L.eval('N()') == 4 and L.eval('#T.waiting()') == 1, "four cards at once, the moment they happen; the fifth waits")
    L.execute('notify.show("e"); RUN(5.2)')
    check(L.eval('N()') == 1 and L.eval('C(1).text') == "E", "the fifth shows as soon as a card is free")
    check(L.eval('C(1).count') == 2, "...counted x2: it came again while it waited (kit: the repeat was lost)")
    L.execute('T.reset(); notify.show("x"); notify.show("home in 30 s", "bad", "cd", nil, { progress = 1, sticky = true }); '
              'notify.show("y"); notify.show("home in 25 s", "bad", "cd", nil, { progress = 0.8, sticky = true }); RUN(0.1)')
    check(L.eval('N()') == 3 and L.eval('C(2).text') == "Home in 25 s" and L.eval('C(2).progress') == 0.8,
          "a keyed message changes its card in place (same spot, new text and bar)")
    L.execute('RUN(20)')
    check(L.eval('N()') == 1 and L.eval('C(1).key') == "cd", "a sticky card stays while the others time out")
    L.execute('notify.show("they let you in", "good", "cd")')
    L.execute('notify.clear("cd", true)')
    check(L.eval('N()') == 1, "clear(key, only_sticky) leaves a card that shows how it ended")
    L.execute('notify.clear("cd")')
    check(L.eval('N()') == 0, "clear(key) takes it away")
    L.execute('T.reset(); for _, s in ipairs({ "a", "b", "c", "d" }) do notify.show(s) end; notify.show("disk full", "bad"); RUN(0.1)')
    check(L.eval('N()') == 4 and L.eval('C(4).text') == "Disk full" and L.eval('C(1).text') == "B",
          "a problem never waits behind info: the oldest info card makes room")
    L.execute('T.reset(); notify.show("bad thing", "bad"); notify.show("fine thing", "good"); RUN(0.1)')
    check(L.eval('C(1).till') > L.eval('C(2).till'), "problems stay on screen longer")
    check(L.eval('#notify.history()') >= 2 and L.eval('notify.history()[#notify.history()].text') == "Fine thing",
          "every message goes into the history")
    L.execute('T.reset(); for s = 30, 1, -1 do notify.show("home in " .. s, "bad", "cd") end; notify.show("other"); '
              'notify.show("home in 0", "bad", "cd")')
    check(L.eval('#notify.history()') == 2 and L.eval('notify.history()[2].text') == "Home in 0",
          "a live card's updates are one history entry, its newest state (a countdown isn't 30 lines)")
    # no cards here (the widget can't be built): the game's pop-up, one at a time, with the heading
    L.execute('T.reset(); SHOWN = {}; T.view.broken = true; notify.show("a"); notify.show("b"); RUN(0.1)')
    check(L.eval('#SHOWN') == 1 and L.eval('SHOWN[1].text') == "SURROUNSYNC: A", "fallback: the game's pop-up (%s)"
          % (L.eval('SHOWN[1] and SHOWN[1].text')))
    L.execute('RUN(2)')
    check(L.eval('#SHOWN') == 2, "...one after the other")


@test
def util_callsite_tells_callers_apart(L, tmp):
    L.execute('''
        local util = require("mirror.util")
        local function register() local s = util.callsite(2); return s end   -- no tail call, as game.on_tick   -- like game.on_tick asking who called it
        SITE_A = register()
        SITE_B = register()
    ''')
    a, b = L.eval('SITE_A'), L.eval('SITE_B')
    check(a is not None and b is not None and a != b,
          "two registrations from two lines get two call sites (%s / %s) - else the second replaces the first" % (a, b))
    L.execute('''
        local real = pcall
        pcall = function(...) return real(...) end
        local util = require("mirror.util")
        local function register() local s = util.callsite(2); return s end   -- no tail call, as game.on_tick
        SITE_C = register()
        SITE_D = register()
        pcall = real
    ''')
    c, d = L.eval('SITE_C'), L.eval('SITE_D')
    check(c is not None and d is not None and c != d, "...whatever pcall looks like (%s / %s)" % (c, d))


LINK_CFG = '{ transport = "%s", netsim = { enabled = false }, steam = {}, save = { peer_gone_after = 15, file_link_gone_after = 45 } }'


@test
def link_peer_state_steam(L, tmp):
    d = os.path.join(tmp, "SurrounDead")
    os.makedirs(d, exist_ok=True)
    L.execute('link = require("mirror.link"); link.start_bridge = function() end; link.configure(%s); link.open("guest")'
              % (LINK_CFG % "steam"))

    def status(hb, game):
        write(os.path.join(d, "mirror_bridge_status_guest.txt"),
              ("bridge guest: me 1, peer Host (1001), last rx 0.1 s, pkts tx 1 rx 1, KB tx 0 rx 0, blobs tx 0 rx 0"
               " peer_hb %s peer_game %s at %d" % (hb, game, int(time.time()))).encode())
    status("0.5", "alive")
    check(L.eval('link.peer_state_now(0.2)') == "ok", "heartbeat fresh, poses fresh -> ok")
    check(L.eval('link.peer_state_now(12)') == "paused", "heartbeat fresh, no poses for 12 s -> paused (menu open)")
    status("16.0", "alive")
    check(L.eval('link.peer_state_now(16)') == "gone", "no heartbeat for 16 s -> gone")
    status("0.5", "gone")
    check(L.eval('link.peer_state_now(3)') == "gone", "the peer's connector says its game closed -> gone")
    status("-1.0", "?")
    check(L.eval('link.peer_state_now(3)') == "unknown", "no peer yet -> unknown")


@test
def link_peer_state_file(L, tmp):
    L.execute('link = require("mirror.link"); link.configure(%s); link.open("guest")' % (LINK_CFG % "file"))
    check(L.eval('link.peer_state_now(5)') == "ok" and L.eval('link.peer_state_now(50)') == "gone",
          "file transport: gone after 45 s of silence")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    for fn in TESTS:
        if not fn.__name__.startswith(only):
            continue
        print(fn.__name__)
        tmp = tempfile.mkdtemp(prefix="mirror_saves_")
        os.environ["LOCALAPPDATA"] = tmp
        try:
            fn(fresh(tmp), tmp)
        except Exception as e:
            check(False, "%s raised %s" % (fn.__name__, e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("\n%s" % ("ALL PASSED" if not fails else "%d FAILED" % len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
