"""Realms store in the mod (mirror/realm.lua): bridge answers, world checks, the local world copy, uploads.
Runs the real Lua against a temp folder with a stand-in bridge.

    PYTHONPATH=tools/testpkg python tools/test-realm-lua.py
"""
import os
import shutil
import sys
import tempfile

try:
    from lupa import lua54
except ImportError:
    print("needs lupa: pip install --target tools/testpkg lupa, then PYTHONPATH=tools/testpkg")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
RID = "4R5BJRNGWF"
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


SETUP = r'''
local scripts, tmp = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
LOG = {}
local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
package.preload["mirror.log"] = function()
    return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end }
end
SENT = {}
BRIDGE_UP = true
package.preload["mirror.link"] = function()
    return { dir = function() return tmp end,
             bridge_cmd = function(t) if not BRIDGE_UP then return false end SENT[#SENT + 1] = t; return true end }
end
package.preload["mirror.backups"] = function()
    return { LAYOUT = { world = { "Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav", "Thumb.jpg" },
                        player = { "Player.sav", "PlayerInfo.sav" }, sidecars = { "_SDQuests.sav", "_SkillTree.sav", "_Quests.sav" } } }
end
savefs = require("mirror.savefs")
savefs.set_dir_backend(DIRS)
realm = require("mirror.realm")
realm.configure({ realms = { enabled = true } })
ANSWERS = {}
function answer(seq, verb, ok, text) ANSWERS[#ANSWERS + 1] = { seq, verb, ok, text } end
function cb_for(i) return function(ok, words, text) ANSWERS[i] = { ok = ok, words = words, text = text } end end
'''


def make(tmp):
    L = lua54.LuaRuntime()

    def mkdir(p):
        os.makedirs(p, exist_ok=True)
        return True
    L.globals().DIRS = L.table_from({"mkdir": mkdir, "list_dirs": lambda p: None, "rmdir": lambda p: True})
    L.execute(SETUP, SCRIPTS, tmp)
    return L


def two(L, expr):
    t = L.eval("{ %s }" % expr)
    return t[1], t[2]


def world(tag=b"w"):
    return {"Level.sav": b"EMSH" + tag * 200, "General.sav": b"EMSH" + tag * 40, "Slot.sav": b"EMSH" + tag * 30,
            "Thumb.sav": b"\xff\xd8\xff" + tag * 50}


def write_dir(folder, files):
    os.makedirs(folder, exist_ok=True)
    for n, d in files.items():
        with open(os.path.join(folder, n), "wb") as f:
            f.write(d)


def files_in(folder):
    return {n: open(os.path.join(folder, n), "rb").read() for n in os.listdir(folder)} if os.path.isdir(folder) else {}


def state_file(tmp, body):
    with open(os.path.join(tmp, "mirror_realms.txt"), "w", newline="\n") as f:
        f.write(body)


def t_commands(L, tmp):
    print("bridge commands and answers")
    lua = L.eval
    seq = lua('realm.send("claim", "%s", function(ok, w, t) RES = { ok = ok, w = w, t = t } end)' % RID)
    check(lua("SENT[1]") == "realm %d claim %s" % (seq, RID), "command line: " + str(lua("SENT[1]")))
    check(lua("realm.busy()") is True, "busy while waiting")
    state_file(tmp, "realms on 1\nrealm %s owner - 3 2 - My World\nlease %s held\nop %d claim ok won 3\nEND\n" % (RID, RID, seq))
    lua("realm.tick(1)")
    check(lua("RES and RES.ok") is True and lua("RES.w[1]") == "won" and lua("RES.w[2]") == "3", "answer reaches the callback")
    check(lua("realm.busy()") is False, "not busy after the answer")
    check(lua("realm.service()") == "on", "service on")
    check(lua("realm.lease('%s')" % RID) == "held", "lease state read")
    r = lua("realm.find('%s')" % RID)
    check(r is not None and r.name == "My World" and r.gen == 3 and r.members == 2 and r.host is None and r.role == "owner",
          "realm line parsed")

    seq = lua('realm.send("download", "%s", function(ok, w, t) RES2 = { ok = ok, t = t } end)' % RID)
    state_file(tmp, "realms on 1\nop %d download fail bad_hash the download was damaged\nEND" % seq)  # no END newline
    lua("realm.tick(1)")
    check(lua("RES2") is None, "a half-written state file is ignored")
    state_file(tmp, "realms on 1\nop %d download fail bad_hash the download was damaged\nEND\n" % seq)
    lua("realm.tick(1)")
    check(lua("RES2.ok") is False and lua("RES2.t").startswith("bad_hash"), "a failure reaches the callback")

    lua('realm.send("list", "", function(ok, w, t) RES3 = { ok = ok, t = t } end)')
    for _ in range(170):
        lua("realm.tick(0.25)")
    check(lua("RES3 and RES3.ok") is False and lua("RES3.t").startswith("timeout"), "no answer -> timeout")

    L.execute("BRIDGE_UP = false")
    lua('realm.send("list", "", function(ok, w, t) RES4 = { ok = ok, t = t } end)')
    check(lua("RES4.ok") is False and lua("RES4.t").startswith("no_bridge"), "no bridge -> answered at once")
    L.execute("BRIDGE_UP = true")

    state_file(tmp, "realms on 1\nrealm %s member 76561197960266730 9 4 Some_One Big  World\nrealm bad line\nEND\n" % RID)
    lua("realm.tick(5)")
    r = lua("realm.find('%s')" % RID)
    check(r.host == "76561197960266730" and r.host_name == "Some One" and r.name == "Big  World", "host + name with spaces")
    check(lua("#realm.list()") == 1, "a broken realm line is skipped")


def t_download(L, tmp):
    print("downloaded worlds")
    lua = L.eval
    rdir = os.path.join(tmp, "Saved", "SurrounSyncRealms", RID)
    down = os.path.join(rdir, "down")
    w = world()
    side = {"mirror_coop_bed_names.txt": b"1 2 3|Base\n", "mirror_host_settings.txt": b"pvp=on\n"}
    write_dir(down, dict(w, **side, **{"unknown.bin": b"x", "Player.sav": b"EMSH" + b"p" * 50}))
    g, why = two(L, 'realm.accept_download("%s", 4)' % RID)
    check(g == 4, "a good world is accepted: %s %s" % (g, why))
    got = files_in(os.path.join(rdir, "world"))
    check(all(got.get(n) == d for n, d in w.items()), "world files copied")
    check(got.get("mirror_coop_bed_names.txt") == side["mirror_coop_bed_names.txt"], "sidecar copied")
    check(got.get("mirror_coop_bags.txt") == b"", "a missing sidecar becomes empty (no stale one)")
    check("unknown.bin" not in got and "Player.sav" not in got, "unknown files and characters are not taken")
    check(lua('realm.head("%s")' % RID) == 4, "head generation 4")
    t = lua('realm.world("%s")' % RID)
    # (lupa hands Lua strings back decoded)
    check(t.gen == 4 and t.files["Level.sav"] == w["Level.sav"].decode() and t.side["mirror_host_settings.txt"] == "pvp=on\n",
          "realm.world returns files, sidecars and generation")

    for bad, label in [({"General.sav": b"EMSH" + b"x" * 40}, "no Level.sav"),
                       (dict(w, **{"Level.sav": b"NOPE" + b"x" * 40}), "Level.sav isn't a save"),
                       (dict(w, **{"mirror_coop_bags.txt": b"a\x00b"}), "binary sidecar"),
                       (dict(w, **{"mirror_coop_bags.txt": b"a" * (300 * 1024)}), "huge sidecar")]:
        shutil.rmtree(down)
        write_dir(down, bad)
        g, why = two(L, 'realm.accept_download("%s", 5)' % RID)
        check(g is None and why, "refused (%s): %s" % (label, why))
    check(lua('realm.head("%s")' % RID) == 4 and files_in(os.path.join(rdir, "world"))["Level.sav"] == w["Level.sav"],
          "a refused world leaves the old copy alone")

    w2 = {k: v for k, v in world(b"n").items() if k != "Thumb.sav"}
    shutil.rmtree(down)
    write_dir(down, w2)
    g, _ = two(L, 'realm.accept_download("%s", 6)' % RID)
    got = files_in(os.path.join(rdir, "world"))
    check(g == 6 and "Thumb.sav" not in got and got["Level.sav"] == w2["Level.sav"], "a world without Thumb.sav drops the old one")


def t_upload(L, tmp):
    print("uploads")
    lua = L.eval
    up = os.path.join(tmp, "Saved", "SurrounSyncRealms", RID, "up")
    write_dir(up, {"Thumb.sav": b"old", "mirror_coop_bags.txt": b"old"})
    L.globals().W = L.table_from({k: v for k, v in world(b"u").items() if k != "Thumb.sav"})
    L.globals().S = L.table_from({"mirror_host_settings.txt": b"pvp=off\n", "mirror_coop_bags.txt": b""})
    ok, why = two(L, 'realm.stage_upload("%s", W, S)' % RID)
    got = files_in(up)
    check(ok is True, "staged: %s" % why)
    check(set(got) == {"Level.sav", "General.sav", "Slot.sav", "mirror_host_settings.txt"},
          "exactly the new files, stale + empty ones gone: %s" % sorted(got))
    L.globals().W = L.table_from({"Level.sav": b"junk"})
    ok, why = two(L, 'realm.stage_upload("%s", W, S)' % RID)
    check(ok is None and why, "a broken world isn't staged: %s" % why)


def t_chained(L, tmp):
    """A handler that sends the next request (claim_new -> upload) while answers are handed out: in-game the walk
    over the open requests failed with "invalid key to 'next'"."""
    print("handlers that send the next request")
    L.execute('GOT, NEXT = 0, {}')
    seqs = [L.eval('realm.send("claim", "%s", function() GOT = GOT + 1; for i = 1, 20 do '
                   'NEXT[#NEXT + 1] = realm.send("upload", "%s " .. i) end end)' % (RID, RID)) for _ in range(6)]
    state_file(tmp, "realms on 1\n" + "".join("op %d claim ok won 0\n" % s for s in seqs) + "END\n")
    ok = L.eval('pcall(realm.tick, 1)')
    check(ok is True, "no error while handlers add requests")
    check(L.eval('GOT') == 6, "every answer reached its handler: %s" % L.eval('GOT'))
    check(L.eval('#NEXT') == 120 and L.eval('realm.busy()') is True, "the new requests wait for their own answers")


def t_invite(L, tmp):
    """INVITE: the bridge copies the code (an io.popen("clip") in the mod froze the game); the code stays on the
    REALMS page (members.last_invite) so it can be selected and copied by hand."""
    print("INVITE code")
    L.execute('NOTES = {}; package.preload["mirror.notify"] = function() return { show = function(m, k) NOTES[#NOTES + 1] = m end } end;'
              'package.preload["mirror.peers"] = function() return { each = function() end } end;'
              'members = require("mirror.realmmembers"); SENT = {}')
    L.execute('members.invite("%s")' % RID)
    sent = L.eval("SENT[1]") or ""
    check(sent.endswith("invite %s copy" % RID), "INVITE asks the bridge to copy: " + sent)
    seq = int(sent.split()[1])
    check(L.eval("members.last_invite()") is None, "no code before the answer")
    # (the server sends codes dashed: the mod dashed them again -> "JFNK--PBT-9-62-KE-DX6E" in-game)
    state_file(tmp, "realms on 1\nop %d invite ok ABCD-EFGH-JKMN-PQRS copied\nEND\n" % seq)
    L.eval("realm.tick(1)")
    inv = L.eval("members.last_invite()")
    check(inv is not None and inv.code == "ABCD-EFGH-JKMN-PQRS" and inv.id == RID, "the code is kept for the REALMS page")
    note = L.eval("NOTES[#NOTES]") or ""
    check("ABCD-EFGH-JKMN-PQRS copied" in note, "the note says it was copied: " + note)
    seq = L.eval('realm.send("invite", "%s", nil)' % RID)
    check(L.eval("SENT[#SENT]").endswith("invite %s" % RID), "other invite users (ADD FRIENDS HERE) don't copy")
    state_file(tmp, "realms on 1\nop %d invite ok ZZZZYYYYXXXXWWWW\nEND\n" % seq)
    L.eval("realm.tick(1)")
    check(L.eval("members.last_invite().code") == "ABCD-EFGH-JKMN-PQRS", "only INVITE's own code is shown")
    L.execute('members.invite("%s")' % RID)
    seq = int(L.eval("SENT[#SENT]").split()[1])
    state_file(tmp, "realms on 1\nop %d invite ok QQQQ-RRRR-SSSS-TTTT nocopy\nEND\n" % seq)
    L.eval("realm.tick(1)")
    note = L.eval("NOTES[#NOTES]") or ""
    check("Invite code: QQQQ-RRRR-SSSS-TTTT." in note and "copied" not in note, "clipboard failed: the code is still shown: " + note)

    # ADD FRIENDS HERE: the host sends the bare code over the link; the guest only takes [0-9A-Z]+
    L.execute('BLOBS = {}; LINK = { peer_name = function() return "Bob" end, peer_state = function() return "ok" end,'
              ' put_blob = function(k, v) BLOBS[k] = v end };'
              'package.loaded["mirror.peers"].each = function(_, f) f(LINK) end')
    L.execute('members.add("%s", "My World", nil)' % RID)
    seq = int(L.eval("SENT[#SENT]").split()[1])
    state_file(tmp, "realms on 1\nop %d invite ok MMMM-NNNN-PPPP-QQQQ\nEND\n" % seq)
    L.eval("realm.tick(1)")
    blob = L.eval('BLOBS["realm_invite"]') or ""
    check(blob == "%s MMMMNNNNPPPPQQQQ My World" % RID, "the link carries the bare code: " + blob)


def main():
    for t in (t_commands, t_download, t_upload, t_chained, t_invite):
        tmp = tempfile.mkdtemp(prefix="realmlua_")
        try:
            t(make(tmp), tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d failure(s)" % len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
