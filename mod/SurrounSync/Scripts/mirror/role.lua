-- Reads which role this game has (mirror_role.txt next to the exe, else the config).

local role = {}

function role.resolve(cfg)
    local f = io.open("mirror_role.txt", "r")
    if f then
        local s = (f:read("*a") or ""):lower():gsub("%s", "")
        f:close()
        if s == "auto" or s == "host" or s == "guest" or s == "off" then return s, "mirror_role.txt" end
    end
    return cfg.role or "off", "config.lua"
end

return role
