-- The public server list (schema.sql has it for new databases). Run once on a database made before:
--   npx wrangler d1 execute surrounsync-realms --remote --file migrations/2026-11-01-public.sql
ALTER TABLE realms ADD COLUMN public INTEGER NOT NULL DEFAULT 0;
ALTER TABLE realms ADD COLUMN pass_salt TEXT;
ALTER TABLE realms ADD COLUMN pass_hash TEXT;
ALTER TABLE realms ADD COLUMN players INTEGER;
ALTER TABLE realms ADD COLUMN max_players INTEGER;
ALTER TABLE realms ADD COLUMN ping_loc TEXT;
ALTER TABLE realms ADD COLUMN listed_ip TEXT;
ALTER TABLE realms ADD COLUMN listed_at INTEGER;
ALTER TABLE realms ADD COLUMN hosted_at INTEGER;
ALTER TABLE realms ADD COLUMN list_banned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE members ADD COLUMN via TEXT;
