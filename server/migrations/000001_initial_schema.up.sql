CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           TEXT UNIQUE NOT NULL,
    name            TEXT,
    avatar_key      TEXT,
    accent_color    TEXT NOT NULL DEFAULT '#2dd4bf',
    theme           TEXT NOT NULL DEFAULT 'dark' CHECK (theme IN ('dark', 'light')),
    ik_pub          BYTEA,
    lk_pub          BYTEA,
    spk_pub         BYTEA,
    spk_sig         BYTEA,
    spk_ts          BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash      BYTEA NOT NULL UNIQUE,
    device_info     TEXT,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

CREATE TABLE one_time_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    opk_idx         INT NOT NULL,
    key_pub         BYTEA NOT NULL,
    consumed        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, opk_idx)
);
CREATE INDEX idx_opk_user_unconsumed ON one_time_prekeys(user_id) WHERE consumed = FALSE;

CREATE TABLE albums (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_ct         BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE album_member_identities (
    member_token    BYTEA PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, album_id)
);
CREATE INDEX idx_amid_user ON album_member_identities(user_id);
CREATE INDEX idx_amid_album ON album_member_identities(album_id);

CREATE TABLE album_members (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    member_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'co-admin', 'member')),
    revoked_at      TIMESTAMPTZ,
    PRIMARY KEY (album_id, member_token)
);

-- epoch_sig : Ed25519 over (album_id ‖ epoch ‖ member_set_hash ‖ wraps_hash)
-- Server verifies against any active co-admin's IK_pub and stores only the sig,
-- never which co-admin matched. Authorization without revealing the rotater
CREATE TABLE album_epochs (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    epoch           INT NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    epoch_sig       BYTEA,
    PRIMARY KEY (album_id, epoch)
);

CREATE TABLE album_epoch_wraps (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    epoch           INT NOT NULL,
    recipient_token BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    ek_pub          BYTEA NOT NULL,
    opk_idx_used    INT,
    wrap_nonce      BYTEA NOT NULL,
    wrap_tag_ct     BYTEA NOT NULL,
    sender_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    sender_sig      BYTEA NOT NULL,
    delivered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (album_id, epoch, recipient_token)
);

CREATE TABLE media (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    uploader_token  BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    storage_key     TEXT NOT NULL,
    thumb_key       TEXT,
    wrap_nonce      BYTEA NOT NULL,
    wrap_tag_ct     BYTEA NOT NULL,
    epoch_tag       INT NOT NULL,
    blob_size       BIGINT NOT NULL,
    blob_sha256     BYTEA NOT NULL,
    media_type      TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_media_album ON media(album_id, created_at DESC);

CREATE TABLE manifests (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    version         BIGINT NOT NULL,
    epoch           INT NOT NULL,
    payload         BYTEA NOT NULL,
    payload_hash    BYTEA NOT NULL,
    prev_hash       BYTEA,
    signer_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    signature       BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (album_id, version)
);

CREATE TABLE invite_blobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    payload         BYTEA NOT NULL,
    signer_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    signature       BYTEA NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    consumed_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE invite_links (
    code            TEXT PRIMARY KEY,
    blob_id         UUID NOT NULL REFERENCES invite_blobs(id) ON DELETE CASCADE,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type            TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}',
    is_read         BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notif_user_unread ON notifications(user_id, is_read, created_at DESC);
