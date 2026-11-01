-- The owner's game rules per Realm (schema.sql has it for new databases). Run once on a database made before:
--   npx wrangler d1 execute surrounsync-realms --remote --file migrations/2026-10-30-rules.sql
ALTER TABLE realms ADD COLUMN rules TEXT;
