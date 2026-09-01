package repository

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrMediaNotFound   = errors.New("media not found")
	ErrNoEpoch         = errors.New("album has no epoch")
	ErrEpochMismatch   = errors.New("epoch_tag does not match current epoch")
	ErrPendingRotation = errors.New("album has a pending epoch rotation")
)

type MediaRepository struct {
	DB *pgxpool.Pool
}

func NewMediaRepository(db *pgxpool.Pool) *MediaRepository {
	return &MediaRepository{DB: db}
}

// ReserveUploadRow inserts a pending (confirmed=FALSE) media row, but only
// after re verifying, atomically under the albums row FOR UPDATE lock, that the
// upload is still valid: the album's current epoch equals epochTag and no
// rotation is pending. Because revoke (RevokeMemberTx) and rotation
// (InsertEpoch) take the same lock, a member removed concurrently with this
// upload cannot slip a new object in under the stale MK : whichever commits
// first wins, and if the revoke wins this returns ErrPendingRotation

// The current epoch and pending rotation SQL mirror epoch.Repo.PendingRotation
// CurrentEpoch and must stay in lockstep with them
func (r *MediaRepository) ReserveUploadRow(ctx context.Context, m *model.Media, epochTag int) error {
	if m.ID == uuid.Nil {
		m.ID = uuid.New()
	}
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var locked uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, m.AlbumID).Scan(&locked)
	if err == pgx.ErrNoRows {
		return ErrAlbumNotFound
	}
	if err != nil {
		return err
	}

	var cur int
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		m.AlbumID,
	).Scan(&cur); err != nil {
		return err
	}
	if cur < 0 {
		return ErrNoEpoch
	}
	if epochTag != cur {
		return ErrEpochMismatch
	}

	var pending bool
	if err := tx.QueryRow(ctx, `
		SELECT
		  EXISTS (
		    SELECT 1 FROM album_members mm
		    WHERE mm.album_id = $1 AND mm.revoked_at IS NULL
		      AND NOT EXISTS (
		        SELECT 1 FROM album_epoch_wraps w
		        WHERE w.album_id = $1 AND w.epoch = $2 AND w.recipient_token = mm.member_token)
		  )
		  OR EXISTS (
		    SELECT 1 FROM album_epoch_wraps w
		    WHERE w.album_id = $1 AND w.epoch = $2
		      AND NOT EXISTS (
		        SELECT 1 FROM album_members mm
		        WHERE mm.album_id = $1 AND mm.revoked_at IS NULL AND mm.member_token = w.recipient_token)
		  )`,
		m.AlbumID, cur,
	).Scan(&pending); err != nil {
		return err
	}
	if pending {
		return ErrPendingRotation
	}

	if err := tx.QueryRow(ctx, `
		INSERT INTO media (
			id, album_id, uploader_token, storage_key, thumb_key, wrap_nonce,
			wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, mime_type,
			thumb_wrap_nonce, thumb_wrap_tag_ct, thumb_size, thumb_sha256
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
		RETURNING created_at`,
		m.ID, m.AlbumID, m.UploaderToken, m.StorageKey, m.ThumbKey, m.WrapNonce,
		m.WrapTagCT, m.EpochTag, m.BlobSize, m.BlobSHA256, m.MediaType, m.MimeType,
		m.ThumbWrapNonce, m.ThumbWrapTagCT, m.ThumbSize, m.ThumbSHA256,
	).Scan(&m.CreatedAt); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// MarkConfirmed atomically assigns the album generation and activity order
// The conditional update is the concurrency guard for duplicate confirms
func (r *MediaRepository) MarkConfirmed(ctx context.Context, mediaID, albumID uuid.UUID) (int64, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	tag, err := tx.Exec(ctx,
		`UPDATE media SET confirmed = TRUE WHERE id = $1 AND album_id = $2 AND confirmed = FALSE`,
		mediaID, albumID,
	)
	if err != nil {
		return 0, err
	}
	if tag.RowsAffected() == 0 {
		return 0, ErrMediaNotFound
	}

	// Stamp activity at confirm time rather than reservation time
	var generation int64
	if err := tx.QueryRow(ctx,
		`UPDATE albums SET media_generation = media_generation + 1,
		                   last_activity_seq = nextval('album_activity_seq')
		 WHERE id = $1 RETURNING media_generation`,
		albumID,
	).Scan(&generation); err != nil {
		return 0, err
	}

	if _, err := tx.Exec(ctx,
		`UPDATE media SET album_seq = $1 WHERE id = $2`, generation, mediaID,
	); err != nil {
		return 0, err
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return generation, nil
}

// MediaGeneration reads the counter without incrementing it
func (r *MediaRepository) MediaGeneration(ctx context.Context, albumID uuid.UUID) (int64, error) {
	var g int64
	err := r.DB.QueryRow(ctx,
		`SELECT media_generation FROM albums WHERE id = $1`, albumID).Scan(&g)
	return g, err
}

// DeletePending removes a row that was created but never confirmed (S3 upload
// failed checksum, client gave up, etc.). Returns no error on missing : idempotent
func (r *MediaRepository) DeletePending(ctx context.Context, mediaID, albumID uuid.UUID) error {
	_, err := r.DB.Exec(ctx,
		`DELETE FROM media WHERE id = $1 AND album_id = $2 AND confirmed = FALSE`,
		mediaID, albumID,
	)
	return err
}

// GetByID returns one media row regardless of confirmed state. Used by
// ConfirmUpload to read storage_key + claimed size+sha256 for the S3 HEAD check
func (r *MediaRepository) GetByID(ctx context.Context, mediaID, albumID uuid.UUID) (*model.Media, error) {
	var m model.Media
	err := r.DB.QueryRow(ctx, `
		SELECT id, album_id, uploader_token, storage_key, thumb_key, wrap_nonce,
			wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, mime_type,
			confirmed, created_at, thumb_wrap_nonce, thumb_wrap_tag_ct, thumb_size,
			thumb_sha256, album_seq
		FROM media WHERE id = $1 AND album_id = $2`,
		mediaID, albumID,
	).Scan(
		&m.ID, &m.AlbumID, &m.UploaderToken, &m.StorageKey, &m.ThumbKey,
		&m.WrapNonce, &m.WrapTagCT, &m.EpochTag, &m.BlobSize, &m.BlobSHA256,
		&m.MediaType, &m.MimeType, &m.Confirmed, &m.CreatedAt,
		&m.ThumbWrapNonce, &m.ThumbWrapTagCT, &m.ThumbSize, &m.ThumbSHA256,
		&m.AlbumSeq,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrMediaNotFound
	}
	return &m, err
}

// ListConfirmed returns confirmed media rows for an album, newest first
// Pending rows are intentionally excluded
func (r *MediaRepository) ListConfirmed(ctx context.Context, albumID uuid.UUID) ([]model.Media, error) {
	rows, err := r.DB.Query(ctx, `
		SELECT id, album_id, uploader_token, storage_key, thumb_key, wrap_nonce,
			wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, mime_type,
			confirmed, created_at, thumb_wrap_nonce, thumb_wrap_tag_ct, thumb_size,
			thumb_sha256
		FROM media WHERE album_id = $1 AND confirmed = TRUE
		ORDER BY album_seq DESC NULLS LAST, created_at DESC, id DESC`,
		albumID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.Media
	for rows.Next() {
		var m model.Media
		if err := rows.Scan(
			&m.ID, &m.AlbumID, &m.UploaderToken, &m.StorageKey, &m.ThumbKey,
			&m.WrapNonce, &m.WrapTagCT, &m.EpochTag, &m.BlobSize, &m.BlobSHA256,
			&m.MediaType, &m.MimeType, &m.Confirmed, &m.CreatedAt,
			&m.ThumbWrapNonce, &m.ThumbWrapTagCT, &m.ThumbSize, &m.ThumbSHA256,
		); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

// MediaObjectKeys is the pair of S3 keys backing one media row : the main blob
// and its optional thumbnail. Used to purge object storage when an album is
// deleted (the media rows themselves cascade away with the album)
type MediaObjectKeys struct {
	StorageKey string
	ThumbKey   *string
}

// returns every media object key in an album, confirmed or
// not, so the caller can delete them from S3 before the album (and its media
// rows, via ON DELETE CASCADE) is dropped
func (r *MediaRepository) ListAlbumObjectKeys(ctx context.Context, albumID uuid.UUID) ([]MediaObjectKeys, error) {
	rows, err := r.DB.Query(ctx,
		`SELECT storage_key, thumb_key FROM media WHERE album_id = $1`, albumID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MediaObjectKeys
	for rows.Next() {
		var k MediaObjectKeys
		if err := rows.Scan(&k.StorageKey, &k.ThumbKey); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// Delete removes a confirmed media row. The S3 object is dropped by the
// service layer before this fires : a stranded row would still 404 cleanly
// since the storage_key would point at nothing
func (r *MediaRepository) Delete(ctx context.Context, mediaID, albumID uuid.UUID) error {
	tag, err := r.DB.Exec(ctx,
		`DELETE FROM media WHERE id = $1 AND album_id = $2`,
		mediaID, albumID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrMediaNotFound
	}
	return nil
}
