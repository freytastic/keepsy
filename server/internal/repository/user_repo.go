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

func (r *UserRepository) GetByEmail(ctx context.Context, email string) (*model.User, error) {
	var user model.User
	query := `SELECT id, email, name, avatar_key, accent_color, theme, created_at, updated_at FROM users WHERE email = $1`
	err := r.DB.QueryRow(ctx, query, email).Scan(
		&user.ID, &user.Email, &user.Name, &user.AvatarKey, &user.AccentColor, &user.Theme, &user.CreatedAt, &user.UpdatedAt,
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
	query := `SELECT id, email, name, avatar_key, accent_color, theme, created_at, updated_at FROM users WHERE id = $1`
	err := r.DB.QueryRow(ctx, query, id).Scan(
		&user.ID, &user.Email, &user.Name, &user.AvatarKey, &user.AccentColor, &user.Theme, &user.CreatedAt, &user.UpdatedAt,
	)
	if err == pgx.ErrNoRows {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *UserRepository) Update(ctx context.Context, user *model.User) error {
	query := `UPDATE users SET name = $1, accent_color = $2, theme = $3, updated_at = NOW() WHERE id = $4`
	_, err := r.DB.Exec(ctx, query, user.Name, user.AccentColor, user.Theme, user.ID)
	return err
}

func (r *UserRepository) Create(ctx context.Context, user *model.User) error {
	if user.ID == uuid.Nil {
		user.ID = uuid.New()
	}
	query := `INSERT INTO users (id, email, name, accent_color, theme, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
		RETURNING created_at, updated_at`
	return r.DB.QueryRow(ctx, query, user.ID, user.Email, user.Name, user.AccentColor, user.Theme).Scan(&user.CreatedAt, &user.UpdatedAt)
}
