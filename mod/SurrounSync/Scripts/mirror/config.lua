-- Defaults. Per-PC overrides go in Binaries\Win64\mirror_settings.txt (see settings.lua).
-- Distances are in cm, times in seconds.
local config = {
    enabled = true,

    -- "auto": pick host/join in the CO-OP tab. "host" / "guest" / "off" are for testing.
    role = "auto",

    debug = {
        enabled   = true,
        log_level = "INFO",
    },

    -- offline ghost test (replays your own movement); only used with role = "off"
    phase0 = {
        enabled = true,
        delay   = 2.0,
        buffer  = 10.0,
        probe_interval = 2.0,
        probe_radius   = 5000,
    },

    phase1 = {
        send_hz = 30,                -- player position updates per second
        interp_delay = 0.15,         -- starting value; clockmap.lua adjusts it to the connection
        max_extrapolation = 0.25,
        hold_after = 0.5,            -- no updates for this long: the other player stands still
        peer_timeout = 60.0,         -- ...and disappears after this
        look_interval = 1.0,
        status_interval = 5.0,
    },

    phase2 = {
        coop_slot = "SurrounSync_Session",
        legacy_coop_slot = "MirrorCoop_Session",   -- name used before 0.9; still recognised
        coop_slots = 8,
        saved_dir = { host = "Saved", guest = "Saved_Guest" },
        teleport_settle = 2.0,       -- s after a load before placing the player (the preset spawn usually already did)
        teleport_tolerance = 2000,
    },

    zombies = {
        enabled = true,
        radius = 15000,              -- host sends zombies within this range of the guest
        send_hz = 15,
        interp_delay = 0.12,
        despawn_after = 3.0,
        offscreen_anim = true,       -- copies past 40 m skip their pose while not drawn (false = always animate)
        dmg_reach = 350,             -- a hit from further away than this counts as dodged
        area_reach = 1000,           -- same for radiation clouds / blasts
        -- P8 load split (host setting LOAD SPLITTING, off by default): far apart, the guest's game runs
        -- the AI around the guest instead of the host's (mirror/split.lua). Distances in cm.
        split = {
            split_radius = 40000,    -- players further apart than this ...
            split_after = 10.0,      -- ... for this many seconds -> split
            merge_radius = 30000,    -- closer than this -> merge (once the guest isn't fighting)
            force_radius = 20000,    -- closer than this -> merge even mid-fight
            quiet_radius = 6000,     -- no split while a host AI (or body) is this close to the guest
            ack_timeout = 10.0,      -- the guest must take over within this, else stay merged
            retry_after = 30.0,      -- after a failed or blocked attempt
            horde_radius = 25000,    -- an active horde beacon this close to the guest blocks / ends a split
            nest_hit_s = 90.0,       -- a guest hit on an infestation this recent blocks / ends a split
            drain_radius = 6000,     -- guest: own AI this close at a merge are kept until done ...
            drain_s = 90.0,          -- ... at most this long
            corpse_radius = 15000,   -- own bodies this close are kept for looting ...
            corpse_s = 300.0,        -- ... this long
            host_near = 12000,       -- ... unless the host comes this close to them
        },
    },

    transport = "steam",             -- "file" = two games on one PC (testing)
    steam = {
        peer = "",                   -- a SteamID64 to connect to directly; empty = use the menu
    },
    netsim = {                       -- fake lag for testing the file transport
        enabled = false,
        latency_ms = 80,
        jitter_ms = 30,
        loss = 0.02,
    },

    diagnostics = false,

    world_sync = true,
    camp_sync = true,          -- the guest gets the host's settlement camps (camps.lua)
    door_sync = true,
    power_sync = true,
    audio_sync = true,
    loot_sync = true,
    notify = true,
    mirror_drops = true,
    mirror_tactical = true,
    mirror_throwables = true,
    mirror_vehicles = true,
    harvest_sync = true,
    fix_stuck_lasers = true,
    lasers_follow_aim = true,

    ghost = {
        class = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
        run_physics_no_controller = true,
        feed_velocity = true,
        mirror_crouch = true,
        mirror_montages = true,
        mirror_aim = true,
        mirror_fire = true,
        view_controller = true,
        snap_distance = 300,         -- teleport instead of moving when further off than this
        target_tag = "ZombieCanAttack",
        register_invoker = true,
        anim_keepalive_radius = 4000,
    },

    save = {
        destroy_ghost_on_save = true,  -- keeps the other player out of your save files
        respawn_delay = 0.5,
        backups_kept = 10,             -- per save, plus the first one (never deleted)
        checkpoints = true,            -- save shortly after items change hands between players
        checkpoint_delay = 10.0,
        checkpoint_min_interval = 90.0, -- any save (also the game's autosave) restarts this
        host_gone_countdown = 30,      -- guest goes home this long after the host's game closes
        peer_gone_after = 15,
        file_link_gone_after = 45,
        guest_gone_reset = 30,
    },
}

return config
