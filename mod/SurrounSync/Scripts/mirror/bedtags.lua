-- Bed names: look at a placed bed or sleeping bag -> its hover menu has a "Rename" row (scroll down past the last
-- option, press interact). The name replaces the item name at the top of the hover menu, for both players.
-- Names are kept per bed position in mirror_coop_bed_names.txt and sent to the other game ("N x y z name").
-- The game's option list is a TMap on the bed (adding entries from Lua crashes UE4SS), so the row is our own widget:
-- selecting it parks the game's option index one past the end, where interacting runs no bed option at all.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local names = require("mirror.names")
local fs = require("mirror.fs")

local bedtags = {}

local MATCH = 100
local MAX = 200
local CLASSES = { Buildable_Bed_C = "bed", Buildable_SleepingBag_C = "bag" }
local HELPER = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C"
local OPTION = "/Game/JigSInventory/Jigsaw/Widgets/BP_InteractWidgetOption.BP_InteractWidgetOption_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"

local path = nil
local records = nil
local send, shared = nil, nil
local hook_in = 0.0
local look_in = 0.0
local cur = nil            -- { w = hover widget address, actor, loc, kind, last = option index, picked = row selected }
local cycled_down = false  -- set by the CycleOptions hook, handled in the next tick
local interacted = false   -- set by the TryInteract hook
local want_box = nil       -- { loc, kind, name } - the rename box opens from the tick, never inside a hook

local records_of = nil     -- the file `records` came from (a Realm has its own)
local function file() return path and path() end

local function read()
    local p = file()
    if records and records_of == p then return records end
    records, records_of = {}, p
    for line in ((p and fs.read(p)) or ""):gmatch("[^\r\n]+") do
        local x, y, z, name = line:match("^(%S+) (%S+) (%S+)|(.+)$")
        if name and tonumber(x) then
            records[#records + 1] = { loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, name = name }
        end
    end
    return records
end

local function write(list)
    local p = file()
    records, records_of = list, p
    if not p then return end
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = string.format("%.0f %.0f %.0f|%s", r.loc.X, r.loc.Y, r.loc.Z, r.name) end
    fs.write(p, table.concat(out, "\n") .. "\n")
end

local function find(loc)
    for i, r in ipairs(read()) do if util.dist(r.loc, loc) < MATCH then return r, i end end
    return nil
end

function bedtags.name_at(loc) local r = loc and find(loc); return r and r.name or nil end

-- name nil/"" clears it. Returns true when something changed.
local function set_name(loc, name)
    local list = read()
    local r, i = find(loc)
    if name == "" then name = nil end
    if (r and r.name) == name then return false end
    if r and not name then table.remove(list, i)
    elseif r then r.name = name
    else
        list[#list + 1] = { loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, name = name }
        while #list > MAX do table.remove(list, 1) end
    end
    write(list)
    return true
end

-- a new bed where an old one stood starts without a name; a removed bed's name goes with it
function bedtags.placed(da, loc)
    if da and loc and da:find("/Beds/", 1, true) then bedtags.gone(loc) end
end

function bedtags.gone(loc)
    if not loc then return end
    local list, n = read(), 0
    for i = #list, 1, -1 do if util.dist(list[i].loc, loc) < MATCH then table.remove(list, i); n = n + 1 end end
    if n > 0 then write(list) end
end

-- "N x y z name|-" from the other game
function bedtags.apply(p)
    local x, y, z, enc = p:match("^N (%S+) (%S+) (%S+) (%S+)$")
    if not (x and tonumber(x)) then return end
    local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local name = enc ~= "-" and names.clean(names.decode(enc)) or nil
    if set_name(loc, name) then
        log.info("bedtags: the other player named a bed " .. tostring(name))
        if cur and util.dist(cur.loc, loc) < MATCH then cur.w = nil end   -- re-title next tick
    end
end

local function rename(loc, kind, name)
    if not set_name(loc, name) then return end
    name = bedtags.name_at(loc)
    log.info("bedtags: named a " .. kind .. " " .. tostring(name))
    if send and shared and shared() then
        send(string.format("N %.0f %.0f %.0f %s", loc.X, loc.Y, loc.Z, name and names.encode(name) or "-"))
    end
    local what = kind == "bag" and "Sleeping bag" or "Bed"
    notify.show(name and (what .. " named \"" .. name .. "\".") or (what .. " name cleared."), "good")
    if cur and util.dist(cur.loc, loc) < MATCH then cur.w = nil end
end

local function count(arr)
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    return n or 0
end

-- our row is the one child after the game's own options (the game clears the box whenever it rebuilds them)
local function find_row(w, vb)
    local kids, n = 0, count(w.Options)
    pcall(function() kids = vb:GetChildrenCount() end)
    if kids ~= n + 1 then return nil end
    local c
    pcall(function() c = vb:GetChildAt(n) end)
    return util.valid(c) and c or nil
end

local function add_row(w, vb)
    local cls, wbl, pc = StaticFindObject(OPTION), util.cdo(WBL), game.controller()
    if not (util.valid(cls) and wbl and util.valid(pc)) then return nil end
    local kids = 0
    pcall(function() kids = vb:GetChildrenCount() end)
    if kids ~= count(w.Options) then return nil end
    local row
    pcall(function() row = wbl:Create(pc, cls, pc) end)
    if not util.valid(row) then return nil end
    pcall(function() row.OptionName = FText("Rename") end)
    local slot
    pcall(function() slot = vb:AddChildToVerticalBox(row) end)
    pcall(function() slot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 2 }) end)
    pcall(function() row:UpdateText(FText("Rename")) end)
    pcall(function() row:SetSelected(false) end)
    return find_row(w, vb)
end

local function select_row(w, row, on)
    if on then
        pcall(function() util.each(w.Options, function(_, e) e:get():SetSelected(false) end) end)
    end
    pcall(function() row:SetSelected(on) end)
end

-- the bed I'm looking at and its hover widget, or nil
local function looking_at()
    local helper, actor, hud, w
    pcall(function() helper = game.player().BP_JigHelperComp end)
    if not util.valid(helper) then return nil end
    pcall(function() actor = helper.CurrentTracActor end)
    local kind = CLASSES[util.class_name(actor) or ""]
    if not kind then return nil end
    pcall(function() hud = game.controller().MyHUD end)
    pcall(function() w = hud.InteractWidget end)
    if not util.valid(w) then return nil end
    return helper, actor, kind, w
end

local function hover()
    local helper, actor, kind, w = looking_at()
    if not helper then cur = nil; cycled_down, interacted = false, false; return end
    local vb
    pcall(function() vb = w.InteractOptions end)
    if not util.valid(vb) then return end
    local addr = util.addr(w)
    local row = find_row(w, vb)
    if not (cur and cur.w == addr and util.same(cur.actor, actor)) or not row then
        local loc
        pcall(function() loc = util.vec(actor:K2_GetActorLocation()) end)
        if not loc then return end
        cur = { w = addr, actor = actor, loc = loc, kind = kind, last = 0, picked = false }
        row = row or add_row(w, vb)
        if not row then cur = nil; return end
        local name = bedtags.name_at(loc)
        if name then pcall(function() w.ObjectName:SetText(FText(name)) end) end
    end
    local n, idx = count(w.Options), 0
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    if cycled_down and n > 0 and cur.last == n - 1 and idx == 0 then
        pcall(function() helper.CurrentInteractOptionIndex = n end)
        idx = n
    end
    cycled_down = false
    local picked = idx == n and n > 0
    if picked ~= cur.picked then select_row(w, row, picked); cur.picked = picked end
    cur.last = idx
    if interacted and picked then
        want_box = { loc = cur.loc, kind = cur.kind, name = bedtags.name_at(cur.loc) }
    end
    interacted = false
end

local cycle_fn = function(_, value)
    local down = false
    pcall(function() down = value:get() == false end)
    if down then cycled_down = true end
end
local interact_fn = function() interacted = true end

function bedtags.tick(dt)
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(HELPER .. ":CycleOptions", cycle_fn)
        util.ensure_hook(HELPER .. ":TryInteract", interact_fn)
    end
    if want_box then
        local b = want_box
        want_box = nil
        local what = b.kind == "bag" and "SLEEPING BAG" or "BED"
        names.ask({ title = "NAME THIS " .. what, text = b.name, hint = "e.g. Base camp", cursor = true,
                    done = function(name) rename(b.loc, b.kind, name) end })
        return
    end
    look_in = look_in - dt
    if cur or cycled_down or interacted or look_in <= 0 then
        look_in = 0.1
        util.safe(hover, "bedtags.hover")
    end
end

function bedtags.init(session, send_fn, shared_fn)
    path = session and session.data_file and function() return session.data_file("mirror_coop_bed_names.txt") end
    send, shared = send_fn, shared_fn
end

function bedtags.forget() cur, want_box, cycled_down, interacted = nil, nil, false, false end
game.on_world_reset(bedtags.forget)

return bedtags
