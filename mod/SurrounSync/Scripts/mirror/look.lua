-- Copies the other player's clothes, gear and held weapon onto their ghost.

local log = require("mirror.log")
local util = require("mirror.util")

local look = {}

local SK = { "Mesh", "Torso", "Arms", "Biceps", "Hands", "Legs", "LowerLegs", "LowerThighs", "Feet", "Head",
             "Clothing_Torso", "Clothing_Legs", "Clothing_Feet", "Clothing_Gloves", "Clothing_Armor" }
local SM = { "HairMesh", "BeardMesh", "EyebrowsMesh", "Mouth", "Accessory1", "Accessory2", "Accessory3" }

local CLASS = {
    S = "/Script/Engine.StaticMeshComponent",
    K = "/Script/Engine.SkeletalMeshComponent",
    N = "/Script/Engine.SceneComponent",
}

local function asset_path(obj)
    if not util.valid(obj) then return "-" end
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or not full then return "-" end
    local path = full:match("^%S+ (%S+)$")
    if not path or path:find("/Engine/Transient", 1, true) then return "-" end
    return path
end

local function material_paths(comp)
    local out = {}
    pcall(function()
        local n = comp:GetNumMaterials()
        for i = 0, n - 1 do
            local m = comp:GetMaterial(i)
            if util.class_name(m) == "MaterialInstanceDynamic" then pcall(function() m = m.Parent end) end
            out[#out + 1] = asset_path(m)
        end
    end)
    return table.concat(out, ",")
end

local function mesh_of(comp, kind)
    local m
    if kind == "K" then
        pcall(function() m = comp:GetSkinnedAsset() end)
        if not util.valid(m) then pcall(function() m = comp.SkeletalMesh end) end
    else
        pcall(function() m = comp.StaticMesh end)
    end
    return asset_path(m)
end

local function visible(comp, ignore_hidden)
    if ignore_hidden then return true end
    local v = true
    pcall(function() v = comp:IsVisible() end)
    return v
end

local function kind_of(comp)
    local n = util.class_name(comp) or ""
    if n:find("StaticMeshComponent", 1, true) then return "S" end
    if n:find("SkeletalMeshComponent", 1, true) or n:find("PoseableMeshComponent", 1, true) then return "K" end
    return "N"
end

local function fmt_vec(v) return string.format("%.3f,%.3f,%.3f", v.X, v.Y, v.Z) end
local function fmt_rot(r) return string.format("%.3f,%.3f,%.3f", r.Pitch, r.Yaw, r.Roll) end

local function fp_hidden_socket(socket)
    local s = (socket or ""):lower()
    return s:find("head", 1, true) or s:find("mask", 1, true) or s:find("face", 1, true)
        or s:find("eye", 1, true) or s:find("glass", 1, true) or s:find("accessor", 1, true)
end

local function capture_gear(player, fp, lines)
    local idx = 0
    local function walk(comp, parent_idx, socket, depth, fp_ok)
        if depth > 6 then return false end
        local k = kind_of(comp)
        local mesh = (k ~= "N") and mesh_of(comp, k) or "-"
        local vis = visible(comp, fp_ok)
        local hidden_actor = false
        pcall(function() hidden_actor = comp:GetOwner().bHidden == true end)
        if hidden_actor and not fp_ok then vis = false end
        local kids, any_visual = {}, (mesh ~= "-" and vis)
        pcall(function()
            comp.AttachChildren:ForEach(function(_, c)
                local child = c:get()
                if util.valid(child) then kids[#kids + 1] = child end
            end)
        end)
        idx = idx + 1
        local me = idx
        local saved = #lines
        for _, child in ipairs(kids) do
            local sock = "None"
            pcall(function() sock = child.AttachSocketName:ToString() end)
            if walk(child, me, sock, depth + 1, fp_ok) then any_visual = true end
        end
        if not any_visual then
            for i = #lines, saved + 1, -1 do lines[i] = nil end
            idx = me - 1
            return false
        end
        local loc, rot, scl = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }
        pcall(function() loc = comp.RelativeLocation end)
        pcall(function() rot = comp.RelativeRotation end)
        pcall(function() scl = comp.RelativeScale3D end)
        local leader = 0
        if k == "K" then pcall(function() if util.valid(comp.LeaderPoseComponent:Get()) then leader = 1 end end) end
        table.insert(lines, saved + 1, table.concat({ "A", me, parent_idx, k, socket, (mesh ~= "-" and vis) and mesh or "-",
            (mesh ~= "-" and vis) and material_paths(comp) or "", fmt_vec(loc), fmt_rot(rot), fmt_vec(scl), leader }, "\t"))
        return true
    end

    local root = player.Mesh
    pcall(function()
        root.AttachChildren:ForEach(function(_, c)
            local child = c:get()
            if not util.valid(child) then return end
            local owner
            pcall(function() owner = child:GetOwner() end)
            if util.same(owner, player) then return end
            local sock = "None"
            pcall(function() sock = child.AttachSocketName:ToString() end)
            walk(child, 0, sock, 0, fp and fp_hidden_socket(sock) and true or false)
        end)
    end)
end

function look.capture(player)
    local fp = false
    pcall(function() fp = player["PlayerInFirstPerson?"] == true end)
    local lines = {}
    for _, name in ipairs(SK) do
        local c; pcall(function() c = player[name] end)
        if util.valid(c) then
            lines[#lines + 1] = table.concat({ "C", name, "K", mesh_of(c, "K"), visible(c, fp) and 1 or 0, material_paths(c) }, "\t")
        end
    end
    for _, name in ipairs(SM) do
        local c; pcall(function() c = player[name] end)
        if util.valid(c) then
            lines[#lines + 1] = table.concat({ "C", name, "S", mesh_of(c, "S"), visible(c, fp) and 1 or 0, material_paths(c) }, "\t")
        end
    end
    util.safe(capture_gear, "look.capture_gear", player, fp, lines)
    return table.concat(lines, "\n")
end

local missing = {}
local function load(path)
    if not path or path == "-" or path == "" then return nil end
    local o = util.find(path)
    if o then return o end
    missing[#missing + 1] = path
    return nil
end

local function set_materials(comp, mats)
    local i = 0
    for p in (mats or ""):gmatch("[^,]+") do
        local m = load(p)
        if m then pcall(function() comp:SetMaterial(i, m) end) end
        i = i + 1
    end
end

local function set_mesh(comp, kind, path)
    local m = (path ~= "-") and load(path) or nil
    if path ~= "-" and not m then return end
    if kind == "K" then
        pcall(function() comp:SetSkinnedAssetAndUpdate(m, false) end)
    else
        pcall(function() comp:SetStaticMesh(m) end)
    end
end

local function vec(s)
    local x, y, z = s:match("^([^,]+),([^,]+),([^,]+)$")
    return { X = tonumber(x) or 0, Y = tonumber(y) or 0, Z = tonumber(z) or 0 }
end
local function rot(s)
    local p, y, r = s:match("^([^,]+),([^,]+),([^,]+)$")
    return { Pitch = tonumber(p) or 0, Yaw = tonumber(y) or 0, Roll = tonumber(r) or 0 }
end

local gear = {}
-- in_hand[i]: gear[i] belongs to a piece attached to a hand socket (the gun being held, not a holstered one)
local in_hand = {}

local function clear_gear(g)
    local left = 0
    for _, c in ipairs(gear) do
        if util.valid(c) then
            pcall(function() c:SetVisibility(false, true) end)
            pcall(function() c:K2_DestroyComponent(g) end)
            local vis = false
            pcall(function() vis = util.valid(c) and c:IsVisible() end)
            if vis then left = left + 1 end
        end
    end
    if left > 0 then log.warn(string.format("look: %d old gear component(s) not destroyed (hidden)", left)) end
    gear, in_hand = {}, {}
end

local function add_comp(g, kind)
    local cls = StaticFindObject(CLASS[kind])
    if not util.valid(cls) then return nil end
    local c
    pcall(function()
        c = g:AddComponentByClass(cls, true, { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    return util.valid(c) and c or nil
end

function look.apply(g, blob)
    if not (util.valid(g) and blob) then return end
    clear_gear(g)
    pcall(function() g.Mesh:SetCastShadow(true) end)
    missing = {}
    local parts, gear_n, nodes, root_sock = 0, 0, {}, {}
    for line in blob:gmatch("[^\n]+") do
        local f = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
        if f[1] == "C" then
            local c; pcall(function() c = g[f[2]] end)
            if util.valid(c) then
                set_mesh(c, f[3], f[4])
                set_materials(c, f[6])
                pcall(function() c:SetVisibility(f[5] == "1", false) end)
                pcall(function() c:SetCastShadow(true) end)
                parts = parts + 1
            end
        elseif f[1] == "A" then
            local id, parent, kind, socket = tonumber(f[2]), tonumber(f[3]), f[4], f[5]
            local c = add_comp(g, (f[6] ~= "-") and kind or "N")
            if c then
                gear[#gear + 1] = c
                root_sock[id] = (parent == 0) and socket or root_sock[parent] or ""
                in_hand[#gear] = root_sock[id]:lower():find("hand", 1, true) ~= nil
                pcall(function() c:SetCastShadow(true) end)
                nodes[id] = c
                local parent_comp = (parent == 0) and g.Mesh or nodes[parent]
                pcall(function()
                    c:K2_AttachToComponent(parent_comp, FName(socket), 0, 0, 0, false)
                end)
                pcall(function() c:K2_SetRelativeLocationAndRotation(vec(f[8]), rot(f[9]), false, {}, true) end)
                pcall(function() c:SetRelativeScale3D(vec(f[10])) end)
                if f[6] ~= "-" then
                    set_mesh(c, kind, f[6])
                    set_materials(c, f[7])
                    pcall(function() c:SetCollisionEnabled(0) end)
                    if kind == "K" and f[11] == "1" then pcall(function() c:SetLeaderPoseComponent(g.Mesh, false) end) end
                    gear_n = gear_n + 1
                end
            end
        end
    end
    log.info(string.format("look: applied %d body parts, %d gear meshes%s", parts, gear_n,
        #missing > 0 and (", NOT loaded here yet (retrying): " .. table.concat(missing, ", ")) or ""))
    return #missing
end

function look.gear_summary(blob)
    local out = {}
    for line in (blob or ""):gmatch("[^\n]+") do
        local f = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
        if f[1] == "A" and f[3] == "0" then out[#out + 1] = f[5] .. (f[6] ~= "-" and "" or "(empty)") end
    end
    return table.concat(out, ",")
end

function look.forget() gear, in_hand = {}, {} end

function look.components() return gear end
function look.in_hand(i) return in_hand[i] == true end

function look.dump(g)
    if not util.valid(g) then return end
    local ours = {}
    for _, c in ipairs(gear) do local a = util.addr(c); if a then ours[a] = true end end
    local out = {}
    local function walk(comp, depth)
        if depth > 5 then return end
        pcall(function()
            comp.AttachChildren:ForEach(function(_, ch)
                local c = ch:get()
                if not util.valid(c) then return end
                local k = kind_of(c)
                if k ~= "N" then
                    local mesh = mesh_of(c, k)
                    local vis = true
                    pcall(function() vis = c:IsVisible() end)
                    if mesh ~= "-" and vis then
                        local sock = "None"
                        pcall(function() sock = c.AttachSocketName:ToString() end)
                        local who = "[mod]"
                        if not ours[util.addr(c) or 0] then
                            who = "[owner " .. tostring(util.class_name(c:GetOwner())) .. " " .. tostring(util.fname(c)) .. "]"
                        end
                        out[#out + 1] = sock .. ":" .. mesh:match("[^%.]+$") .. who
                    end
                end
                walk(c, depth + 1)
            end)
        end)
    end
    walk(g.Mesh, 0)
    log.info("look: ghost now shows " .. #out .. " attached mesh(es): " .. table.concat(out, ", "))
end

return look
