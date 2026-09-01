-- Shared order for each album's latest confirmed activity
CREATE SEQUENCE album_activity_seq;

-- Device local seen watermarks and exact per album media order
ALTER TABLE albums ADD COLUMN media_generation BIGINT NOT NULL DEFAULT 0;
ALTER TABLE albums ADD COLUMN last_activity_seq BIGINT;
ALTER TABLE media ADD COLUMN album_seq BIGINT;

-- Backfill confirmed media before watermarks use the counter
WITH ordered AS (
    SELECT id,
           album_id,
           row_number() OVER (
               PARTITION BY album_id ORDER BY created_at, id
           ) AS seq
    FROM media
    WHERE confirmed = TRUE
)
UPDATE media m SET album_seq = ordered.seq
FROM ordered WHERE m.id = ordered.id;

UPDATE albums a SET media_generation = COALESCE((
    SELECT COUNT(*) FROM media m
    WHERE m.album_id = a.id AND m.confirmed = TRUE
), 0);

-- Seed existing and empty albums deterministically
WITH ordered AS (
    SELECT a.id,
           row_number() OVER (
               ORDER BY COALESCE(MAX(m.created_at), a.created_at), a.created_at, a.id
           ) AS seq
    FROM albums a
    LEFT JOIN media m ON m.album_id = a.id AND m.confirmed = TRUE
    GROUP BY a.id, a.created_at
)
UPDATE albums a SET last_activity_seq = ordered.seq
FROM ordered WHERE a.id = ordered.id;

ALTER TABLE albums ALTER COLUMN last_activity_seq SET NOT NULL;
ALTER TABLE albums ALTER COLUMN last_activity_seq
    SET DEFAULT nextval('album_activity_seq');

SELECT setval(
    'album_activity_seq',
    COALESCE((SELECT MAX(last_activity_seq) FROM albums), 0) + 1,
    FALSE
);

CREATE INDEX idx_media_album_seq ON media(album_id, album_seq DESC)
    WHERE confirmed = TRUE;
