package repository

import (
	"context"
	"crypto/rand"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrAlbumNotFound  = errors.New("album not found")
	ErrMemberNotFound = errors.New("member not found in album")
	ErrMemberRevoked  = errors.New("member is revoked from album")
)

type AlbumRepository struct {
	DB *pgxpool.Pool
}

func NewAlbumRepository(db *pgxpool.Pool) *AlbumRepository {
	return &AlbumRepository{DB: db}
}

func newMemberToken() ([]byte, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// CreateWithAdmin creates an album, mints a member_token for the creator,
// inserts the identity bridge row, and adds the creator to album_members
// with role='admin' , all in one transaction
func (r *AlbumRepository) CreateWithAdmin(ctx context.Context, nameCT []byte, creatorUserID uuid.UUID) (*model.Album, []byte, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)

	a := &model.Album{ID: uuid.New(), NameCT: nameCT}
	err = tx.QueryRow(ctx,
		`INSERT INTO albums (id, name_ct) VALUES ($1, $2)
		 RETURNING created_at, updated_at`,
		a.ID, a.NameCT,
	).Scan(&a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return nil, nil, err
	}

	token, err := newMemberToken()
	if err != nil {
		return nil, nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_id, album_id)
		 VALUES ($1, $2, $3)`,
		token, creatorUserID, a.ID)
	if err != nil {
		return nil, nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'admin')`,
		a.ID, token)
	if err != nil {
		return nil, nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	return a, token, nil
}

func (r *AlbumRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error) {
	var a model.Album
	err := r.DB.QueryRow(ctx,
		`SELECT id, name_ct, created_at, updated_at FROM albums WHERE id = $1`, id,
	).Scan(&a.ID, &a.NameCT, &a.CreatedAt, &a.UpdatedAt)
	if err == pgx.ErrNoRows {
		return nil, ErrAlbumNotFound
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

func (r *AlbumRepository) ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	rows, err := r.DB.Query(ctx, `
		SELECT a.id, a.name_ct, a.created_at, a.updated_at, am.role, ami.member_token
		FROM albums a
		JOIN album_member_identities ami ON ami.album_id = a.id
		JOIN album_members am ON am.album_id = a.id AND am.member_token = ami.member_token
		WHERE ami.user_id = $1 AND am.revoked_at IS NULL
		ORDER BY a.updated_at DESC`,
		userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.AlbumWithMemberInfo
	for rows.Next() {
		var a model.AlbumWithMemberInfo
		if err := rows.Scan(&a.ID, &a.NameCT, &a.CreatedAt, &a.UpdatedAt, &a.UserRole, &a.MemberToken); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

// LookupMember resolves (userID, albumID) → (memberToken, role)
// Returns ErrMemberNotFound if no row, ErrMemberRevoked if revoked_at is set
// Backs middleware.RequireMember per L6
func (r *AlbumRepository) LookupMember(ctx context.Context, userID uuid.UUID, albumID uuid.UUID) ([]byte, string, error) {
	var token []byte
	var role string
	var revoked *string
	err := r.DB.QueryRow(ctx, `
		SELECT ami.member_token, am.role, am.revoked_at::text
		FROM album_member_identities ami
		JOIN album_members am ON am.album_id = ami.album_id AND am.member_token = ami.member_token
		WHERE ami.user_id = $1 AND ami.album_id = $2`,
		userID, albumID,
	).Scan(&token, &role, &revoked)
	if err == pgx.ErrNoRows {
		return nil, "", ErrMemberNotFound
	}
	if err != nil {
		return nil, "", err
	}
	if revoked != nil {
		return nil, "", ErrMemberRevoked
	}
	return token, role, nil
}

// AddMember mints a member_token for userID in albumID and inserts the bridge
// row and album_members row. Returns the new token.
func (r *AlbumRepository) AddMember(ctx context.Context, albumID, userID uuid.UUID, role string) ([]byte, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	token, err := newMemberToken()
	if err != nil {
		return nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_id, album_id) VALUES ($1, $2, $3)`,
		token, userID, albumID)
	if err != nil {
		return nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, $3)`,
		albumID, token, role)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return token, nil
}

func (r *AlbumRepository) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	rows, err := r.DB.Query(ctx, `
		SELECT
			am.member_token,
			am.role,
			am.revoked_at IS NOT NULL,
			ami.joined_at,
			u.ik_pub,
			u.name,
			u.avatar_key
		FROM album_members am
		JOIN album_member_identities ami ON ami.member_token = am.member_token
		JOIN users u ON u.id = ami.user_id
		WHERE am.album_id = $1
		ORDER BY ami.joined_at ASC`,
		albumID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.MemberWithProfile
	for rows.Next() {
		var m model.MemberWithProfile
		if err := rows.Scan(
			&m.MemberToken,
			&m.Role,
			&m.Revoked,
			&m.JoinedAt,
			&m.Profile.IKPub,
			&m.Profile.Name,
			&m.Profile.AvatarKey,
		); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

func (r *AlbumRepository) CountActiveMembers(ctx context.Context, albumID uuid.UUID) (int, error) {
	var n int
	err := r.DB.QueryRow(ctx,
		`SELECT COUNT(*) FROM album_members WHERE album_id = $1 AND revoked_at IS NULL`,
		albumID,
	).Scan(&n)
	return n, err
}

func (r *AlbumRepository) UpdateName(ctx context.Context, albumID uuid.UUID, nameCT []byte) error {
	_, err := r.DB.Exec(ctx,
		`UPDATE albums SET name_ct = $1, updated_at = NOW() WHERE id = $2`,
		nameCT, albumID)
	return err
}

func (r *AlbumRepository) Delete(ctx context.Context, id uuid.UUID) error {
	_, err := r.DB.Exec(ctx, `DELETE FROM albums WHERE id = $1`, id)
	return err
}
