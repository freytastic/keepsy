CREATE TABLE IF NOT EXISTS albums (
    id              UUID PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT,
    cover_media_id  UUID,                 -- link to media table (to be created later)
    creator_id      UUID NOT NULL REFERENCES users(id),
    widget_config   JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS album_members (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
    joined_at       TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (album_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_albums_creator ON albums(creator_id);
CREATE INDEX IF NOT EXISTS idx_album_members_user ON album_members(user_id);
