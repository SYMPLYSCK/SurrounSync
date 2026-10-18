-- Backups page of the CO-OP tab: list and restore a save's backups.

local backups = require("mirror.backups")
local notify = require("mirror.notify")

local page = {}

local SHOW = 5
local ui, w = nil, nil
local shown, slot_now = {}, nil
local cache, cache_at = nil, -100

function page.pick(list, n)
    n = n or SHOW
    local out, pinned = {}, nil
    for i, e in ipairs(list) do
        if i <= n then out[#out + 1] = e end
        if e.pinned then pinned = e end
    end
    if pinned and #list > n then out[#out + 1] = pinned end
    return out
end

local short = false
local function label(e)
    local t = (e.time or ""):gsub(":%d%d$", "")
    if short then t = t:gsub("^%d%d%d%d%-", "") end
    local what = e.kind == "character" and "co-op character, not applied" or e.reason
    local kept = short and "  (kept)" or "   (before first co-op - always kept)"
    return string.format("%s   %s%s", t, what, e.pinned and kept or "")
end

function page.build(tree, helpers)
    SHOW = helpers.rows or SHOW
    short = helpers.short == true
    ui = helpers
    local box = ui.new("VerticalBox", tree)
    w = { root = box, rows = {} }
    ui.vadd(box, ui.text(tree, "BACKUPS OF THIS SAVE", 18, { 0.9, 0.75, 0.3 }), 18)
    w.info = ui.text(tree, "", 15, { 0.7, 0.7, 0.7 }); ui.vadd(box, w.info, 4)
    for i = 1, SHOW + 1 do
        local r = ui.new("HorizontalBox", tree); ui.vadd(box, r, 4)
        local l = ui.text(tree, "", 15)
        local b = ui.button(tree, " Restore ")
        ui.hadd(r, l); ui.hadd(r, b, 16)
        w.rows[i] = { row = r, label = l, btn = b }
    end
    w.cancel = ui.button(tree, " Cancel the restore "); ui.vadd(box, w.cancel, 8)
    return box
end

function page.refresh(slot)
    if not w then return end
    if slot ~= slot_now or os.clock() - cache_at > 2 then
        slot_now, cache_at = slot, os.clock()
        cache = slot and backups.list(slot) or {}
    end
    shown = page.pick(cache)
    local pending = backups.pending_restore()
    if not slot then
        ui.set(w.info, "Backups are for your own saves - leave co-op first.")
    elseif pending then
        ui.set(w.info, "Restore of " .. pending.slot .. " to " .. pending.folder .. " happens when you restart the game.")
    elseif #shown == 0 then
        ui.set(w.info, "No backups of this save yet - SurrounSync makes one every time co-op touches it.")
    else
        ui.set(w.info, "Pick a copy to bring back - it applies when you restart the game (your save now is backed up first).")
    end
    for i, r in ipairs(w.rows) do
        local e = shown[i]
        ui.vis(r.row, e ~= nil and slot ~= nil)
        if e then ui.set(r.label, label(e)) end
        ui.vis(r.btn, pending == nil)
    end
    ui.vis(w.cancel, pending ~= nil)
end

function page.handle(clicked)
    if not w then return false end
    if clicked(w.cancel) then
        backups.cancel_restore()
        notify.show("Restore cancelled.", "info")
        cache_at = -100
        return true
    end
    for i, r in ipairs(w.rows) do
        local e = shown[i]
        if e and slot_now and clicked(r.btn) then
            if ui.can_restore and not ui.can_restore() then
                notify.show("You can't restore while in co-op. Leave first, or wait until your guest has left.", "bad")
            elseif backups.request_restore(slot_now, e.folder) then
                notify.show("Restart the game to restore " .. slot_now .. " to the backup from " .. (e.time or e.folder) .. ".", "good")
            else
                notify.show("Couldn't schedule the restore. Please check the SurrounSync log.", "bad")
            end
            cache_at = -100
            return true
        end
    end
    return false
end

function page.root() return w and w.root end

return page
