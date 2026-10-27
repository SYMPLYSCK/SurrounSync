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
    lease_expires INTEGER
);

CREATE TABLE IF NOT EXISTS members (
    realm_id   TEXT NOT NULL,
    member_id  TEXT NOT NULL,
    key_hash   TEXT NOT NULL,                 -- sha256 of the member key; the key itself is never stored
    steam_id   TEXT NOT NULL,                 -- as claimed by the client (display only, not proof)
    name       TEXT NOT NULL,
    role       TEXT NOT NULL CHECK (role IN ('owner', 'member')),
    created_at INTEGER NOT NULL,
    last_seen  INTEGER,
    char_gen   INTEGER NOT NULL DEFAULT 0,
    char_hash  TEXT,
    char_size  INTEGER,
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

-- Fixed-window rate limits: bucket = "<action>:<ip>:<window start>".
CREATE TABLE IF NOT EXISTS hits (
    bucket   TEXT PRIMARY KEY,
    n        INTEGER NOT NULL,
    reset_at INTEGER NOT NULL
);
