-- SurrounSync's Hang Glider as its own mod (user 2026-11-10: "Make sure the standalone pak has everything needed to be
-- installed as its own mod"): SurrounSyncGlider.pak (the model and the Hang Glider item) plus the same glider files
-- SurrounSync flies it with (Scripts\mirror, copied from SurrounSync by tools/make-glidermod.py), on standalone.lua's
-- stand-ins for the rest of SurrounSync. Single player: alone there is no one to show the glider to.
-- With SurrounSync installed and on, this stays off: SurrounSync has the glider itself, in co-op too.

local base = require("standalone")

local on, where = base.surrounsync_on()
if on then
    print("[SurrounSyncGlider] SurrounSync is installed (" .. where .. "SurrounSync) and flies the glider itself - this copy stays off\n")
    return
end

local m = base.install()
local log, util = m["mirror.log"], m["mirror.util"]
log.info("SurrounSyncGlider " .. require("mirror.glider_version") .. " starting (the Hang Glider without SurrounSync)")
util.safe(function()
    require("mirror.glider").init({ reinstall = "reinstall the SurrounSync Glider mod" })
end, "glider.init")
util.safe(m["mirror.game"].init, "game.init")
