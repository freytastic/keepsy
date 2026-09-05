-- Preserve object keys before deleting abandoned pending rows
CREATE TABLE media_object_cleanup (
    storage_key     TEXT PRIMARY KEY,
    enqueued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Backoff prevents a poison key from blocking fresh cleanup work
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_media_object_cleanup_due
    ON media_object_cleanup(next_attempt_at, storage_key);
