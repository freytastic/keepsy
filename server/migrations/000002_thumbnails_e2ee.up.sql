--  per file thumbnail has its OWN DEK, wrapped under MK_epoch with the
-- same wrap_aad as the file DEK (album_id ‖ uint32_be(epoch)). thumb_key was
-- already present from the initial schema sketch : the wrap + size + sha land here
-- All nullable : videos + pre §5.3 rows + future media types that wont thumbnail

ALTER TABLE media ADD COLUMN thumb_wrap_nonce BYTEA;
ALTER TABLE media ADD COLUMN thumb_wrap_tag_ct BYTEA;
ALTER TABLE media ADD COLUMN thumb_size BIGINT;
ALTER TABLE media ADD COLUMN thumb_sha256 BYTEA;
