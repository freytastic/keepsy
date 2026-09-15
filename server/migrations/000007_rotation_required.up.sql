-- Durable rotation debt. Every revoke sets it and only a committed epoch for the
-- exact active set clears it. Inferred drift alone would clear once a departed
-- account's wraps are erased, while that account still holds the current key
ALTER TABLE albums ADD COLUMN rotation_required BOOLEAN NOT NULL DEFAULT FALSE;

-- Carry over albums already between a revoke and its rotation
UPDATE albums a SET rotation_required = TRUE
WHERE EXISTS (SELECT 1 FROM album_epochs e WHERE e.album_id = a.id)
  AND (
    EXISTS (
      SELECT 1 FROM album_members m
      WHERE m.album_id = a.id AND m.revoked_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM album_epoch_wraps w
          WHERE w.album_id = a.id AND w.recipient_token = m.member_token
            AND w.epoch = (SELECT MAX(epoch) FROM album_epochs WHERE album_id = a.id)))
    OR EXISTS (
      SELECT 1 FROM album_epoch_wraps w
      WHERE w.album_id = a.id
        AND w.epoch = (SELECT MAX(epoch) FROM album_epochs WHERE album_id = a.id)
        AND NOT EXISTS (
          SELECT 1 FROM album_members m
          WHERE m.album_id = a.id AND m.revoked_at IS NULL
            AND m.member_token = w.recipient_token)));
