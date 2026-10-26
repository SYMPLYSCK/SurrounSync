-- Lua's io/os take paths in the Windows ANSI code page, UE4SS reads Lua strings as UTF-8. A non-ASCII user
-- name (C:\Users\<cyrillic>) reaches UE garbled, so paths under %LOCALAPPDATA% get UE's own spelling.

local uepath = {}

local map = nil

function uepath.ascii(p) return not p:find("[\128-\255]") end

local function ue_local()
    local ok, d = pcall(function()
        local v = require("mirror.util").cdo("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory()
        return type(v) == "string" and v or v:ToString()
    end)
    d = ok and type(d) == "string" and d:gsub("/", "\\"):gsub("\\+$", "") or ""
    return d:match("^(%a:\\.-)\\[^\\]+\\[Ss]aved$")
end

function uepath.set_map(ansi, ue) map = { ansi = ansi, ue = ue } end

function uepath.of(p)
    if uepath.ascii(p) then return p end
    if not map then
        local a = os.getenv("LOCALAPPDATA")
        map = { ansi = a and a:gsub("[\\/]+$", ""), ue = ue_local() }
    end
    local a, u = map.ansi, map.ue
    if a and u and p:sub(1, #a):lower() == a:lower() then return u .. p:sub(#a + 1) end
    return p
end

return uepath
