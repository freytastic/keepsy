CREATE TABLE IF NOT EXISTS invite_links (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id    UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    created_by  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code        TEXT NOT NULL UNIQUE,
    max_uses    INT DEFAULT NULL, -- NULL means unlimited (being handled carefully in the business logic)
    use_count   INT DEFAULT 0,
    expires_at  TIMESTAMPTZ DEFAULT NULL, -- NULL means never expires (being handled carefully in the business logic)
    is_active   BOOLEAN DEFAULT TRUE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_invite_links_code ON invite_links(code);
CREATE INDEX IF NOT EXISTS idx_invite_links_album ON invite_links(album_id);
