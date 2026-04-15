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
	ErrInviteNotFound = errors.New("invite link not found")
	ErrInviteExpired  = errors.New("invite link expired")
	ErrInviteFull     = errors.New("invite link has reached maximum uses")
)

type InviteRepository struct {
	DB *pgxpool.Pool
}

func NewInviteRepository(db *pgxpool.Pool) *InviteRepository {
	return &InviteRepository{DB: db}
}

func (r *InviteRepository) Create(ctx context.Context, invite *model.InviteLink) error {
	if invite.ID == uuid.Nil {
		invite.ID = uuid.New()
	}
	query := `
		INSERT INTO invite_links (id, album_id, created_by, code, max_uses, expires_at, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, NOW())
		RETURNING created_at, use_count, is_active
	`
	return r.DB.QueryRow(ctx, query,
		invite.ID, invite.AlbumID, invite.CreatedBy, invite.Code, invite.MaxUses, invite.ExpiresAt,
	).Scan(&invite.CreatedAt, &invite.UseCount, &invite.IsActive)
}

func (r *InviteRepository) GetByCode(ctx context.Context, code string) (*model.InviteLink, error) {
	var i model.InviteLink
	query := `
		SELECT id, album_id, created_by, code, max_uses, use_count, expires_at, is_active, created_at
		FROM invite_links WHERE code = $1
	`
	err := r.DB.QueryRow(ctx, query, code).Scan(
		&i.ID, &i.AlbumID, &i.CreatedBy, &i.Code, &i.MaxUses, &i.UseCount, &i.ExpiresAt, &i.IsActive, &i.CreatedAt,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrInviteNotFound
	}
	return &i, err
}

func (r *InviteRepository) GetPreview(ctx context.Context, code string) (*model.InvitePreview, error) {
	var p model.InvitePreview
	query := `
		SELECT a.name, COALESCE(u.name, 'Anonymous'), (SELECT COUNT(*) FROM album_members WHERE album_id = a.id)
		FROM invite_links i
		JOIN albums a ON i.album_id = a.id
		JOIN users u ON a.creator_id = u.id
		WHERE i.code = $1 AND i.is_active = true
	`
	err := r.DB.QueryRow(ctx, query, code).Scan(&p.AlbumName, &p.CreatorName, &p.MemberCount)
	if err == pgx.ErrNoRows {
		return nil, ErrInviteNotFound
	}
	return &p, err
}

func (r *InviteRepository) JoinAlbum(ctx context.Context, albumID, userID uuid.UUID, code string) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	//check invite link validity and increment use_count
	var i model.InviteLink
	query := `
		UPDATE invite_links
		SET use_count = use_count + 1
		WHERE code = $1 AND is_active = true
		AND (max_uses IS NULL OR use_count < max_uses)
		AND (expires_at IS NULL OR expires_at > NOW())
		RETURNING album_id
	`
	err = tx.QueryRow(ctx, query, code).Scan(&i.AlbumID)
	if err == pgx.ErrNoRows {
		return ErrInviteNotFound // or expired/full
	}
	if err != nil {
		return err
	}

	// add user to album_members (ignore if already member)
	memberQuery := `
		INSERT INTO album_members (album_id, user_id, role, joined_at)
		VALUES ($1, $2, 'member', NOW())
		ON CONFLICT (album_id, user_id) DO NOTHING
	`
	_, err = tx.Exec(ctx, memberQuery, i.AlbumID, userID)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}
