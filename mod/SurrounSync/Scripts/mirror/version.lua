-- Mod version, and the protocol number both players must match.

return {
    VERSION = "1.1.0",
    PROTOCOL = 61,   -- 61: zombie archetype 7 = Crawler, an archetype since game build 26467602 (zombies.lua); 60: a put into a container's item (an ammo tin in a crate) carries that item, "cell:rot:slot:holder" (loot.lua); 59: the pose line's segments each after their own "|", a flown FPV quad's "Q ..." among them (drone.lua); 58: a dropped item's parts list "C" carries the last agreed list, merged on arrival (drops.lua); 57:a container take carries how many it moved, L how many to give back (loot.lua); 56: every
                     -- event line carries the sender's clock (events.lua); 55: shared sounds do (audio.lua)
}
