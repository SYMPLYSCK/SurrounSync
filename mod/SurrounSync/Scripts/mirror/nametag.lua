-- The other player's name above their head.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local netq = require("mirror.netq")

local nametag = {}

local WC = "/Script/UMG.WidgetComponent"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELLS = {
    "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C",
    "/Game/UI/Widgets/Notification/NotificationParentWidget.NotificationParentWidget_C",
}
local FAR = 40000

local cfg
local made_for = nil
local tag = nil
local check_in = 0.0
local failed = 0

function nametag.attach(actor, text, z, size)
    local wbl, pc = util.cdo(WBL), game.controller()
    local wc = StaticFindObject(WC)
    if not (wbl and util.valid(pc) and util.valid(wc)) then error("UMG not ready") end
    local shell
    for _, p in ipairs(SHELLS) do
        local c = StaticFindObject(p)
        if util.valid(c) then shell = c; break end
    end
    if not shell then error("no widget class loaded yet") end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then error("couldn't create the tag widget") end
    local tree = w.WidgetTree
    local tb
    pcall(function() tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree) end)
    if not util.valid(tb) then error("couldn't create the tag text") end
    pcall(function() tb:SetText(FText(text)) end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }) end)
    pcall(function() tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
    pcall(function() tb:SetShadowOffset({ X = 1.5, Y = 1.5 }) end)
    pcall(function() local f = tb.Font; f.Size = size or 15; tb:SetFont(f) end)
    pcall(function() tb:SetJustification(1) end)
    tree.RootWidget = tb
    local comp
    local xf = { Translation = { X = 0, Y = 0, Z = z or 115 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    pcall(function() comp = actor:AddComponentByClass(wc, false, xf, false) end)
    if not util.valid(comp) then error("couldn't add the tag component") end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetGenerateOverlapEvents(false) end)
    pcall(function() comp:SetWidgetSpace(1) end)
    pcall(function() comp:SetDrawAtDesiredSize(true) end)
    pcall(function() comp:SetPivot({ X = 0.5, Y = 1.0 }) end)
    pcall(function() comp:SetWidget(w) end)
    return { comp = comp, text = tb, name = text, shown = true }
end

function nametag.tick(dt)
    if cfg and cfg.nametags == false then return end
    local g = ghost.get()
    if not g then made_for, tag = nil, nil; return end
    if made_for ~= ghost.generation() and failed < 5 then
        local ok, res = pcall(nametag.attach, g, link.peer_name(), 115)
        if ok then
            made_for, tag = ghost.generation(), res
            log.info("nametag: '" .. res.name .. "' above the other player")
        else
            failed = failed + 1
            made_for = ghost.generation()
            log.warn("nametag: couldn't make the tag (" .. tostring(res) .. ")")
        end
    end
    check_in = check_in - dt
    if not tag or check_in > 0 then return end
    check_in = 0.5
    local label, color = netq.tag(link.peer_name())
    if label ~= tag.name then tag.name = label; pcall(function() tag.text:SetText(FText(label)) end) end
    if color ~= tag.color then
        tag.color = color
        pcall(function() tag.text:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    end
    local far = false
    pcall(function() far = util.dist(util.vec(g:K2_GetActorLocation()), util.vec(game.player():K2_GetActorLocation())) > FAR end)
    if far == tag.shown then
        tag.shown = not far
        pcall(function() tag.comp:SetVisibility(not far, false) end)
    end
end

function nametag.init(c) cfg = c end

return nametag
