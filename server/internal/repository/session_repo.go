package repository

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrSessionNotFound means no live session matched the token
var ErrSessionNotFound = errors.New("session not found")

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
	// A session created while deletion was being accepted must not outlive it
	err := r.DB.QueryRow(ctx,
		`SELECT s.id, s.user_id, s.token_hash, s.expires_at, s.created_at
		 FROM sessions s JOIN users u ON u.id = s.user_id
		 WHERE s.token_hash = $1 AND u.deleting_at IS NULL`,
		HashToken(token),
	).Scan(&s.ID, &s.UserID, &s.TokenHash, &s.ExpiresAt, &s.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		// Distinguish a missing session from a database failure
		return nil, ErrSessionNotFound
	}
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func (r *SessionRepository) DeleteByToken(ctx context.Context, token string) error {
	_, err := r.DB.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, HashToken(token))
	return err
}

// ExtendByToken keeps refresh idempotent by preserving the token
func (r *SessionRepository) ExtendByToken(ctx context.Context, token string, expiresAt time.Time) error {
	// Match GetByToken's live-user constraint and reject concurrent deletion
	tag, err := r.DB.Exec(ctx,
		`UPDATE sessions s SET expires_at = $2
		 FROM users u
		 WHERE s.token_hash = $1 AND u.id = s.user_id AND u.deleting_at IS NULL`,
		HashToken(token), expiresAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrSessionNotFound
	}
	return nil
}
