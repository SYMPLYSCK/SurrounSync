-- The message of the day (schema.sql has it for new databases). Run once on a database made before:
--   npx wrangler d1 execute surrounsync-realms --remote --file migrations/2026-10-30-motd.sql
CREATE TABLE IF NOT EXISTS motd (
    id         INTEGER PRIMARY KEY CHECK (id = 1),
    msg_id     TEXT NOT NULL,
    text       TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER
);
