-- Remembers who placed which bed or sleeping bag, so respawn points stay per player.

local util = require("mirror.util")
local game = require("mirror.game")
local fs = require("mirror.fs")
local notify = require("mirror.notify")

local bedtags = {}

local MATCH = 100
local NEAR = 250
local AWAY = 400
local MAX = 60

local path = nil
local records = nil
local shown = nil
local check_in = 0.0

local function text_of(kind, owner)
    local what = kind == "bag" and "sleeping bag" or "bed"
    if owner == "self" then return "Your " .. what end
    return owner .. "'s " .. what
end

local function read()
    if records then return records end
    records = {}
    for line in ((path and fs.read(path)) or ""):gmatch("[^\r\n]+") do
        local x, y, z, kind, owner = line:match("^(%S+) (%S+) (%S+)|(%a+)|(.+)$")
        if owner then records[#records + 1] = { loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, kind = kind, owner = owner } end
    end
    return records
end

local function write(list)
    records = list
    if not path then return end
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = string.format("%.0f %.0f %.0f|%s|%s", r.loc.X, r.loc.Y, r.loc.Z, r.kind, r.owner) end
    fs.write(path, table.concat(out, "\n") .. "\n")
end

function bedtags.placed(da, loc, owner)
    if not (da and loc and da:find("/Beds/", 1, true)) then return end
    local kind = da:find("SleepingBag", 1, true) and "bag" or "bed"
    local list = read()
    for i = #list, 1, -1 do if util.dist(list[i].loc, loc) < MATCH then table.remove(list, i) end end
    list[#list + 1] = { loc = loc, kind = kind, owner = owner }
    while #list > MAX do table.remove(list, 1) end
    write(list)
end

function bedtags.gone(loc)
    if not loc then return end
    local list, n = read(), 0
    for i = #list, 1, -1 do if util.dist(list[i].loc, loc) < MATCH then table.remove(list, i); n = n + 1 end end
    if n > 0 then write(list) end
end

function bedtags.tick(dt)
    check_in = check_in - dt
    if check_in > 0 then return end
    check_in = 0.5
    local list = read()
    if #list == 0 then return end
    local me
    pcall(function() me = util.vec(game.player():K2_GetActorLocation()) end)
    if not me then return end
    if shown and util.dist(me, shown.loc) > AWAY then shown = nil end
    if shown then return end
    for _, r in ipairs(list) do
        if util.dist(me, r.loc) < NEAR then
            shown = r
            notify.show(text_of(r.kind, r.owner), "info", "bedtag")
            return
        end
    end
end

function bedtags.init(session)
    path = session and session.data_file and session.data_file("mirror_coop_bed_owners.txt")
end

return bedtags
