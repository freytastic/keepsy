package repository

import (
	"context"
	"crypto/sha256"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type SessionRepository struct {
	DB *pgxpool.Pool
}

func NewSessionRepository(db *pgxpool.Pool) *SessionRepository {
	return &SessionRepository{DB: db}
}

func (r *SessionRepository) Create(ctx context.Context, session *model.Session) error {
	if session.ID == uuid.Nil {
		session.ID = uuid.New()
	}
	_, err := r.DB.Exec(ctx,
		`INSERT INTO sessions (id, user_id, token_hash, expires_at)
		 VALUES ($1, $2, $3, $4)`,
		session.ID, session.UserID, session.TokenHash, session.ExpiresAt)
	return err
}

func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

func (r *SessionRepository) GetByToken(ctx context.Context, token string) (*model.Session, error) {
	var s model.Session
	err := r.DB.QueryRow(ctx,
		`SELECT id, user_id, token_hash, expires_at, created_at
		 FROM sessions WHERE token_hash = $1`,
		HashToken(token),
	).Scan(&s.ID, &s.UserID, &s.TokenHash, &s.ExpiresAt, &s.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func (r *SessionRepository) DeleteByToken(ctx context.Context, token string) error {
	_, err := r.DB.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, HashToken(token))
	return err
}
