DROP INDEX IF EXISTS idx_media_album_seq;
ALTER TABLE media DROP COLUMN IF EXISTS album_seq;
ALTER TABLE albums DROP COLUMN IF EXISTS last_activity_seq;
ALTER TABLE albums DROP COLUMN IF EXISTS media_generation;
DROP SEQUENCE IF EXISTS album_activity_seq;
