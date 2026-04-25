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
	ErrMediaNotFound = errors.New("media not found")
)

type MediaRepository struct {
	DB *pgxpool.Pool
}

func NewMediaRepository(db *pgxpool.Pool) *MediaRepository {
	return &MediaRepository{DB: db}
}

func (r *MediaRepository) Create(ctx context.Context, media *model.Media) error {
	if media.ID == uuid.Nil {
		media.ID = uuid.New()
	}

	query := `
		INSERT INTO media (
			id, album_id, uploader_id, storage_key, thumb_key,
			media_type, mime_type, file_size, width, height,
			duration_ms, content_hash, wrapped_dek, epoch_tag,
			created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW()
		) RETURNING created_at
	`
	err := r.DB.QueryRow(ctx, query,
		media.ID, media.AlbumID, media.UploaderID, media.StorageKey, media.ThumbKey,
		media.MediaType, media.MimeType, media.FileSize, media.Width, media.Height,
		media.DurationMS, media.ContentHash, media.WrappedDEK, media.EpochTag,
	).Scan(&media.CreatedAt)

	return err
}

func (r *MediaRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Media, error) {
	var m model.Media
	query := `
		SELECT
			id, album_id, uploader_id, storage_key, thumb_key,
			media_type, mime_type, file_size, width, height,
			duration_ms, content_hash, wrapped_dek, epoch_tag,
			created_at
		FROM media WHERE id = $1
	`
	err := r.DB.QueryRow(ctx, query, id).Scan(
		&m.ID, &m.AlbumID, &m.UploaderID, &m.StorageKey, &m.ThumbKey,
		&m.MediaType, &m.MimeType, &m.FileSize, &m.Width, &m.Height,
		&m.DurationMS, &m.ContentHash, &m.WrappedDEK, &m.EpochTag,
		&m.CreatedAt,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrMediaNotFound
	}
	return &m, err
}

func (r *MediaRepository) ListByAlbum(ctx context.Context, albumID uuid.UUID, limit, offset int) ([]model.Media, error) {
	query := `
		SELECT
			id, album_id, uploader_id, storage_key, thumb_key,
			media_type, mime_type, file_size, width, height,
			duration_ms, content_hash, wrapped_dek, epoch_tag,
			created_at
		FROM media
		WHERE album_id = $1
		ORDER BY created_at DESC
		LIMIT $2 OFFSET $3
	`
	rows, err := r.DB.Query(ctx, query, albumID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []model.Media
	for rows.Next() {
		var m model.Media
		err := rows.Scan(
			&m.ID, &m.AlbumID, &m.UploaderID, &m.StorageKey, &m.ThumbKey,
			&m.MediaType, &m.MimeType, &m.FileSize, &m.Width, &m.Height,
			&m.DurationMS, &m.ContentHash, &m.WrappedDEK, &m.EpochTag,
			&m.CreatedAt,
		)
		if err != nil {
			return nil, err
		}
		results = append(results, m)
	}
	return results, nil
}

func (r *MediaRepository) Delete(ctx context.Context, id uuid.UUID) error {
	query := `DELETE FROM media WHERE id = $1`
	_, err := r.DB.Exec(ctx, query, id)
	return err
}
