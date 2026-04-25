-- Reverse E2EE alignment changes

-- Restore EXIF columns
ALTER TABLE media ADD COLUMN IF NOT EXISTS taken_at      TIMESTAMPTZ;
ALTER TABLE media ADD COLUMN IF NOT EXISTS location_lat  DOUBLE PRECISION;
ALTER TABLE media ADD COLUMN IF NOT EXISTS location_lng  DOUBLE PRECISION;

-- Remove E2EE columns
ALTER TABLE media DROP COLUMN IF EXISTS wrapped_dek;
ALTER TABLE media DROP COLUMN IF EXISTS epoch_tag;

-- Remove epoch tracking
ALTER TABLE albums DROP COLUMN IF EXISTS current_epoch;

-- Revert role constraint
ALTER TABLE album_members DROP CONSTRAINT IF EXISTS album_members_role_check;
ALTER TABLE album_members ADD CONSTRAINT album_members_role_check
    CHECK (role IN ('owner', 'member'));

-- Remove crypto key columns
ALTER TABLE users DROP COLUMN IF EXISTS ik_pub;
ALTER TABLE users DROP COLUMN IF EXISTS lk_pub;
ALTER TABLE users DROP COLUMN IF EXISTS spk_pub;
ALTER TABLE users DROP COLUMN IF EXISTS spk_sig;
ALTER TABLE users DROP COLUMN IF EXISTS spk_ts;
