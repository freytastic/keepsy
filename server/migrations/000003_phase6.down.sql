DROP INDEX IF EXISTS idx_users_miuchio_id;
ALTER TABLE users DROP COLUMN IF EXISTS miuchio_id;
ALTER TABLE album_member_identities DROP COLUMN IF EXISTS last_received_epoch;
ALTER TABLE album_member_identities DROP COLUMN IF EXISTS last_received_at;
