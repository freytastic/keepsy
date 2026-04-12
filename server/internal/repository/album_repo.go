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
	ErrAlbumNotFound  = errors.New("album not found")
	ErrMemberNotFound = errors.New("member not found in album")
)

type AlbumRepository struct {
	DB *pgxpool.Pool
}

func NewAlbumRepository(db *pgxpool.Pool) *AlbumRepository {
	return &AlbumRepository{DB: db}
}

// CreateWithMember creates an album and its first member (the owner) in a single transaction.
func (r *AlbumRepository) CreateWithMember(ctx context.Context, album *model.Album) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// create the album
	if album.ID == uuid.Nil {
		album.ID = uuid.New()
	}
	query := `INSERT INTO albums (id, name, description, creator_id, widget_config, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
		RETURNING created_at, updated_at`
	err = tx.QueryRow(ctx, query, album.ID, album.Name, album.Description, album.CreatorID, album.WidgetConfig).Scan(&album.CreatedAt, &album.UpdatedAt)
	if err != nil {
		return err
	}

	// addd the creator as the 'owner'
	memberQuery := `INSERT INTO album_members (album_id, user_id, role, joined_at)
		VALUES ($1, $2, $3, NOW())`
	_, err = tx.Exec(ctx, memberQuery, album.ID, album.CreatorID, "owner")
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

func (r *AlbumRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error) {
	var album model.Album
	query := `SELECT id, name, description, cover_media_id, creator_id, widget_config, created_at, updated_at FROM albums WHERE id = $1`
	err := r.DB.QueryRow(ctx, query, id).Scan(
		&album.ID, &album.Name, &album.Description, &album.CoverMediaID, &album.CreatorID, &album.WidgetConfig, &album.CreatedAt, &album.UpdatedAt,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrAlbumNotFound
	}
	if err != nil {
		return nil, err
	}
	return &album, nil
}

func (r *AlbumRepository) ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	query := `
		SELECT a.id, a.name, a.description, a.cover_media_id, a.creator_id, a.widget_config, a.created_at, a.updated_at, am.role
		FROM albums a
		JOIN album_members am ON a.id = am.album_id
		WHERE am.user_id = $1
		ORDER BY a.updated_at DESC
	`
	rows, err := r.DB.Query(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var albums []model.AlbumWithMemberInfo
	for rows.Next() {
		var a model.AlbumWithMemberInfo
		err := rows.Scan(
			&a.ID, &a.Name, &a.Description, &a.CoverMediaID, &a.CreatorID, &a.WidgetConfig, &a.CreatedAt, &a.UpdatedAt, &a.UserRole,
		)
		if err != nil {
			return nil, err
		}
		albums = append(albums, a)
	}
	return albums, nil
}

func (r *AlbumRepository) GetMember(ctx context.Context, albumID, userID uuid.UUID) (*model.AlbumMember, error) {
	var member model.AlbumMember
	query := `SELECT album_id, user_id, role, joined_at FROM album_members WHERE album_id = $1 AND user_id = $2`
	err := r.DB.QueryRow(ctx, query, albumID, userID).Scan(&member.AlbumID, &member.UserID, &member.Role, &member.JoinedAt)
	if err == pgx.ErrNoRows {
		return nil, ErrMemberNotFound
	}
	if err != nil {
		return nil, err
	}
	return &member, nil
}

func (r *AlbumRepository) Update(ctx context.Context, album *model.Album) error {
	query := `UPDATE albums SET name = $1, description = $2, widget_config = $3, updated_at = NOW() WHERE id = $4`
	_, err := r.DB.Exec(ctx, query, album.Name, album.Description, album.WidgetConfig, album.ID)
	return err
}

func (r *AlbumRepository) Delete(ctx context.Context, id uuid.UUID) error {
	query := `DELETE FROM albums WHERE id = $1`
	_, err := r.DB.Exec(ctx, query, id)
	return err
}

func (r *AlbumRepository) AddMember(ctx context.Context, albumID, userID uuid.UUID, role string) error {
	query := `INSERT INTO album_members (album_id, user_id, role, joined_at) VALUES ($1, $2, $3, NOW())`
	_, err := r.DB.Exec(ctx, query, albumID, userID, role)
	return err
}

func (r *AlbumRepository) CountMembers(ctx context.Context, albumID uuid.UUID) (int, error) {
	var count int
	query := `SELECT COUNT(*) FROM album_members WHERE album_id = $1`
	err := r.DB.QueryRow(ctx, query, albumID).Scan(&count)
	return count, err
}
