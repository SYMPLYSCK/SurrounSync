-- SurrounSync Realms database (Cloudflare D1). Worlds themselves are in R2: realms/<id>/world/<gen>.

CREATE TABLE IF NOT EXISTS realms (
    id            TEXT PRIMARY KEY,          -- 10 chars Crockford base32, shown as the Realm code R-XXXXX-XXXXX
    name          TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    format        INTEGER NOT NULL,          -- Realm bundle format version (client side)
    mod_version   TEXT NOT NULL,
    protocol      INTEGER NOT NULL,
    game_build    TEXT NOT NULL,
    head_gen      INTEGER NOT NULL DEFAULT 0, -- 0 = no world uploaded yet
    head_hash     TEXT,
    head_size     INTEGER,
    head_member   TEXT,
    head_at       INTEGER,
    lease_member  TEXT,                       -- who is hosting right now (NULL = nobody)
    lease_steam   TEXT,
    lease_name    TEXT,
    lease_token   TEXT,
    lease_expires INTEGER,
    rules         TEXT,                       -- the owner's game rules, "<key> <value> ..." (NULL = not set yet)
    public        INTEGER NOT NULL DEFAULT 0, -- 1 = on the public server list
    pass_salt     TEXT,                       -- a locked public Realm: hex salt + PBKDF2-SHA256 of its password
    pass_hash     TEXT,
    players       INTEGER,                    -- the host's heartbeat: players in its game, its cap, its Steam ping location
    max_players   INTEGER,
    ping_loc      TEXT,
    listed_ip     TEXT,                       -- the address (IPv6: its /64) that put it on the list, for the per-address cap
    listed_at     INTEGER,                    -- when it went on the list; with hosted_at, a Realm unhosted for 14 days drops off
    hosted_at     INTEGER,                    -- the last claim or heartbeat
    list_banned   INTEGER NOT NULL DEFAULT 0  -- 1 = an admin took it off the list for good
);

CREATE TABLE IF NOT EXISTS members (
    realm_id   TEXT NOT NULL,
    member_id  TEXT NOT NULL,
    key_hash   TEXT NOT NULL,                 -- sha256 of the member key; the key itself is never stored
    steam_id   TEXT NOT NULL,                 -- as claimed by the client (not proof: a list join never blocks the real one)
    name       TEXT NOT NULL,
    role       TEXT NOT NULL CHECK (role IN ('owner', 'member')),
    created_at INTEGER NOT NULL,
    last_seen  INTEGER,
    char_gen   INTEGER NOT NULL DEFAULT 0,
    char_hash  TEXT,
    char_size  INTEGER,
    via        TEXT,                          -- NULL = owner or invited, 'public' = joined from the server list
    PRIMARY KEY (realm_id, member_id)
);

CREATE TABLE IF NOT EXISTS invites (
    code_hash  TEXT PRIMARY KEY,              -- sha256 of the invite code
    realm_id   TEXT NOT NULL,
    created_by TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER
);
CREATE INDEX IF NOT EXISTS invites_realm ON invites (realm_id);

CREATE TABLE IF NOT EXISTS generations (
    realm_id   TEXT NOT NULL,
    gen        INTEGER NOT NULL,
    hash       TEXT NOT NULL,
    size       INTEGER NOT NULL,
    member_id  TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (realm_id, gen)
);

-- The message of the day for every player (one row; tools/motd.ps1 sets it).
CREATE TABLE IF NOT EXISTS motd (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    msg_id     TEXT NOT NULL,
    text       TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER
);

-- Fixed-window rate limits: bucket = "<action>:<ip>:<window start>".
CREATE TABLE IF NOT EXISTS hits (
    bucket   TEXT PRIMARY KEY,
    n        INTEGER NOT NULL,
    reset_at INTEGER NOT NULL
);
