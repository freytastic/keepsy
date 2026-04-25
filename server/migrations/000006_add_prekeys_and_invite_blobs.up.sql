-- Table for One Time Prekeys (OPKs)
-- These are consumed one by one as users are invited
CREATE TABLE one_time_prekeys (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_content TEXT NOT NULL, -- The base64 public key
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_opk_user ON one_time_prekeys(user_id);

-- Storage for encrypted invite blobs (New User Invite)
-- Stores the MK delivery payload for someone who doesn't have an account yet
CREATE TABLE invite_blobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    payload         TEXT NOT NULL, -- The encrypted epochs_payload
    signature       TEXT NOT NULL, -- Admin's signature over the payload
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_invite_blobs_album ON invite_blobs(album_id);
