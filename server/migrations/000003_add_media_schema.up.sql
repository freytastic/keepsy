CREATE TABLE media (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    uploader_id     UUID NOT NULL REFERENCES users(id),

    -- Storage
    storage_key     TEXT NOT NULL,         -- R2 key : "albums/{album_id}/{uuid}.{ext}"
    thumb_key       TEXT,                  -- R2 key for thumbnail

    -- Metadata
    media_type      TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    mime_type       TEXT NOT NULL,         -- "image/jpeg", "video/mp4"
    file_size       BIGINT NOT NULL,       -- bytes
    width           INT,
    height          INT,
    duration_ms     INT,                   -- video duration, null for photos

    -- EXIF data
    taken_at        TIMESTAMPTZ,           -- when photo was actually taken
    location_lat    DOUBLE PRECISION,
    location_lng    DOUBLE PRECISION,

    -- Dedup
    content_hash    TEXT,                  -- SHA-256 of file content

    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_media_album ON media(album_id, created_at DESC);
CREATE INDEX idx_media_uploader ON media(uploader_id);
CREATE INDEX idx_media_hash ON media(content_hash);
