package repository

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrMediaNotFound = errors.New("media not found")

type MediaRepository struct {
	DB *pgxpool.Pool
}

func NewMediaRepository(db *pgxpool.Pool) *MediaRepository {
	return &MediaRepository{DB: db}
}

// CreatePending inserts a row with confirmed=FALSE. The client uploads to S3
// after this returns : ConfirmUpload flips the bit if the S3 object validates
func (r *MediaRepository) CreatePending(ctx context.Context, m *model.Media) error {
	if m.ID == uuid.Nil {
		m.ID = uuid.New()
	}
	return r.DB.QueryRow(ctx, `
		INSERT INTO media (
			id, album_id, uploader_token, storage_key, wrap_nonce, wrap_tag_ct,
			epoch_tag, blob_size, blob_sha256, media_type, mime_type
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		RETURNING created_at`,
		m.ID, m.AlbumID, m.UploaderToken, m.StorageKey, m.WrapNonce, m.WrapTagCT,
		m.EpochTag, m.BlobSize, m.BlobSHA256, m.MediaType, m.MimeType,
	).Scan(&m.CreatedAt)
}

// MarkConfirmed flips confirmed=TRUE for a pending row. Returns ErrMediaNotFound
// if no pending row exists with that id+album (someone else's id, already
// confirmed, or never created)
func (r *MediaRepository) MarkConfirmed(ctx context.Context, mediaID, albumID uuid.UUID) error {
	tag, err := r.DB.Exec(ctx,
		`UPDATE media SET confirmed = TRUE WHERE id = $1 AND album_id = $2 AND confirmed = FALSE`,
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
			confirmed, created_at
		FROM media WHERE id = $1 AND album_id = $2`,
		mediaID, albumID,
	).Scan(
		&m.ID, &m.AlbumID, &m.UploaderToken, &m.StorageKey, &m.ThumbKey,
		&m.WrapNonce, &m.WrapTagCT, &m.EpochTag, &m.BlobSize, &m.BlobSHA256,
		&m.MediaType, &m.MimeType, &m.Confirmed, &m.CreatedAt,
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
			confirmed, created_at
		FROM media WHERE album_id = $1 AND confirmed = TRUE
		ORDER BY created_at DESC, id DESC`,
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
		); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
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
