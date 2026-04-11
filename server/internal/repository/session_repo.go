package repository

import (
	"context"
	"crypto/sha256"
	"encoding/hex"

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
	query := `INSERT INTO sessions (id, user_id, token_hash, device_info, expires_at, created_at)
		VALUES ($1, $2, $3, $4, $5, NOW())`
	_, err := r.DB.Exec(ctx, query, session.ID, session.UserID, session.TokenHash, session.DeviceInfo, session.ExpiresAt)
	return err
}

func HashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func (r *SessionRepository) GetByToken(ctx context.Context, token string) (*model.Session, error) {
	var session model.Session
	tokenHash := HashToken(token)
	query := `SELECT id, user_id, token_hash, device_info, expires_at, created_at FROM sessions WHERE token_hash = $1`
	err := r.DB.QueryRow(ctx, query, tokenHash).Scan(
		&session.ID, &session.UserID, &session.TokenHash, &session.DeviceInfo, &session.ExpiresAt, &session.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &session, nil
}
