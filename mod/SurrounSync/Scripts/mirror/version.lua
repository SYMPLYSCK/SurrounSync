-- Mod version, and the protocol number both players must match.

return {
    VERSION = "1.0.0",
    PROTOCOL = 58,   -- 58: a dropped item's parts list "C" carries the last agreed list, merged on arrival (drops.lua); 57:a container take carries how many it moved, L how many to give back (loot.lua); 56: every
                     -- event line carries the sender's clock (events.lua); 55: shared sounds do (audio.lua)
}
