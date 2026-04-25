ALTER TABLE media DROP COLUMN IF EXISTS taken_at;
ALTER TABLE media DROP COLUMN IF EXISTS location_lat;
ALTER TABLE media DROP COLUMN IF EXISTS location_lng;

--  Add E2EE columns to media
--    wrapped_dek : the AES-GCM encrypted DEK, only album members can decrypt
--    epoch_tag: which epoch's Master Key was used to wrap this DEK
ALTER TABLE media ADD COLUMN wrapped_dek TEXT;
ALTER TABLE media ADD COLUMN epoch_tag   INT;

-- Add epoch tracking to albums (increments on membership changes / key rotation)
ALTER TABLE albums ADD COLUMN current_epoch INT NOT NULL DEFAULT 0;

-- Fix album_members role constraint to support admin (co admin) role
ALTER TABLE album_members DROP CONSTRAINT IF EXISTS album_members_role_check;
ALTER TABLE album_members ADD CONSTRAINT album_members_role_check
    CHECK (role IN ('owner', 'co-owner', 'member'));

--  Add crypto key columns to users (nullable , set after app generates keys)
--    ik_pub:  Ed25519 identity key (signing)
--    lk_pub:  X25519 long-term key (key agreement)
--    spk_pub: X25519 signed prekey (rotatable)
--    spk_sig: Ed25519 signature over spk_pub
--    spk_ts:  Unix timestamp when SPK was signed
ALTER TABLE users ADD COLUMN ik_pub  TEXT;
ALTER TABLE users ADD COLUMN lk_pub  TEXT;
ALTER TABLE users ADD COLUMN spk_pub TEXT;
ALTER TABLE users ADD COLUMN spk_sig TEXT;
ALTER TABLE users ADD COLUMN spk_ts  BIGINT;
