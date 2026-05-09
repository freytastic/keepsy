package repository

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrUserNotFound = errors.New("user not found")

type UserRepository struct {
	DB *pgxpool.Pool
}

func NewUserRepository(db *pgxpool.Pool) *UserRepository {
	return &UserRepository{DB: db}
}

// GetByEmailHMAC looks up a user by HMAC of the lowercased+trimmed email.
// The HMAC is computed in the auth service : the repo never sees the plaintext
func (r *UserRepository) GetByEmailHMAC(ctx context.Context, hmac []byte) (*model.User, error) {
	var user model.User
	query := `SELECT id, email_hmac, accent_color, theme, created_at, updated_at, ik_pub, lk_pub, spk_pub, spk_sig, spk_ts FROM users WHERE email_hmac = $1`
	err := r.DB.QueryRow(ctx, query, hmac).Scan(
		&user.ID, &user.EmailHMAC, &user.AccentColor, &user.Theme, &user.CreatedAt, &user.UpdatedAt,
		&user.IKPub, &user.LKPub, &user.SPKPub, &user.SPKSig, &user.SPKTs,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *UserRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	var user model.User
	query := `SELECT id, email_hmac, accent_color, theme, created_at, updated_at, ik_pub, lk_pub, spk_pub, spk_sig, spk_ts FROM users WHERE id = $1`
	err := r.DB.QueryRow(ctx, query, id).Scan(
		&user.ID, &user.EmailHMAC, &user.AccentColor, &user.Theme, &user.CreatedAt, &user.UpdatedAt,
		&user.IKPub, &user.LKPub, &user.SPKPub, &user.SPKSig, &user.SPKTs,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &user, nil
}

// Update writes profile fields only. E2EE columns are owned by internal/e2ee/prekey
// and updated via PUT /users/me/keys + POST /users/me/spk. Display name is per
// album in album_members.name_ct (M7) ; not touched here
func (r *UserRepository) Update(ctx context.Context, user *model.User) error {
	query := `UPDATE users SET
		accent_color = $1,
		theme = $2,
		updated_at = NOW()
	WHERE id = $3`
	_, err := r.DB.Exec(ctx, query, user.AccentColor, user.Theme, user.ID)
	return err
}

func (r *UserRepository) Create(ctx context.Context, user *model.User) error {
	if user.ID == uuid.Nil {
		user.ID = uuid.New()
	}
	query := `INSERT INTO users (
			id, email_hmac, accent_color, theme,
			ik_pub, lk_pub, spk_pub, spk_sig, spk_ts,
			created_at, updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW(), NOW())
		RETURNING created_at, updated_at`
	return r.DB.QueryRow(ctx, query,
		user.ID, user.EmailHMAC, user.AccentColor, user.Theme,
		user.IKPub, user.LKPub, user.SPKPub, user.SPKSig, user.SPKTs,
	).Scan(&user.CreatedAt, &user.UpdatedAt)
}
