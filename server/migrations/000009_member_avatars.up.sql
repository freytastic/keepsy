-- One encrypted avatar per member per album. A replacement uploads as a pending
-- row and swaps in on confirm, so readers never see a half written object
CREATE TABLE member_avatars (
    -- Client chosen, because it is bound into the avatar's AEAD AAD
    avatar_id       UUID PRIMARY KEY,
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    member_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    storage_key     TEXT NOT NULL,
    blob_size       BIGINT NOT NULL,
    blob_sha256     BYTEA NOT NULL,
    -- u32_be(epoch) || DEK sealed under that epoch's MK, opaque to the server
    key_ct          BYTEA NOT NULL,
    confirmed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

CREATE UNIQUE INDEX idx_member_avatars_current
    ON member_avatars(album_id, member_token) WHERE confirmed = TRUE;
CREATE INDEX idx_member_avatars_member ON member_avatars(album_id, member_token);
CREATE INDEX idx_member_avatars_pending ON member_avatars(created_at) WHERE confirmed = FALSE;
