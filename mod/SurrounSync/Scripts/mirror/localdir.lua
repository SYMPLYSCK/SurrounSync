-- Where %LOCALAPPDATA%\SurrounDead (saves, backups, link files) is for Lua's io and for UE. Lua gets the path in
-- the Windows ANSI code page: a user name it can't spell (Cyrillic on English Windows) comes out as "?" and every
-- file call fails; UE4SS also hands Lua strings to UE as UTF-8. So a non-ASCII path goes through the ASCII alias
-- the setup / bridge made (bridge/Common.cs LocalAlias, written to Win64\mirror_localdir.txt).

local localdir = {}

local ALIAS_FILE = "mirror_localdir.txt"   -- next to the game exe (the working directory)
local cached, broken, how = nil, false, nil
local retry_at = 0.0
local env = os.getenv
local alias_file = ALIAS_FILE

function localdir.ascii(p) return type(p) == "string" and not p:find("[^\32-\126]") end

local function usable(dir)
    if not dir or dir == "" or dir:find("?", 1, true) then return false end
    local probe = dir .. "\\.mirror_probe"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local function alias()
    local f = io.open(alias_file, "rb")
    if not f then return nil end
    local s = (f:read("a") or ""):match("^%s*(.-)%s*$")
    f:close()
    return s ~= "" and s or nil
end

local function pick()
    local a = env("LOCALAPPDATA")
    local plain = a and (a:gsub("[\\/]+$", "") .. "\\SurrounDead") or nil
    -- ("?" is what the code page put in for letters it can't spell - ASCII itself, never in a real path)
    if plain and localdir.ascii(plain) and not plain:find("?", 1, true) then return plain, false, "plain" end
    local al = alias()
    if al and localdir.ascii(al) and usable(al) then return al, false, "alias" end
    -- (a name the code page can spell, e.g. Cyrillic on Russian Windows: io works, uepath fixes UE's spelling)
    if usable(plain) then return plain, false, "ansi" end
    return al or plain or ".\\SurrounDead", true, "broken"
end

-- The folder; re-checked every few seconds while broken (the bridge writes the alias file when it starts).
function localdir.get()
    if cached and not broken then return cached end
    local now = os.clock()
    if cached and now < retry_at then return cached end
    retry_at = now + 5.0
    local was = cached
    cached, broken, how = pick()
    if cached ~= was then
        local ok, log = pcall(require, "mirror.log")
        if ok and type(log) == "table" and log.info then
            if broken then log.error("localdir: can't reach the save folder (" .. tostring(cached) .. ") - the Windows user name needs the " ..
                "safe path SurrounSync Setup makes (FIX)")
            elseif how ~= "plain" then log.info("localdir: save folder reached through " .. cached .. " (" .. how .. ")") end
        end
    end
    return cached
end

function localdir.broken() localdir.get(); return broken end
function localdir.how() localdir.get(); return how end

-- tests
function localdir.configure(c)
    if c.getenv then env = c.getenv end
    if c.alias_file then alias_file = c.alias_file end
    cached, broken, how, retry_at = nil, false, nil, 0.0
end

return localdir
