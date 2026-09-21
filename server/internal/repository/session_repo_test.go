package repository_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func seedSessionUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(context.Background(),
		`INSERT INTO users (id, email_hmac, keepsy_id)
		 VALUES ($1, $2, $3)`,
		id, []byte(fmt.Sprintf("session-%s@example.com", id)), id.String(),
	); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, id)
	})
	return id
}

// The integration query proves refresh preserves the row GetByToken reads
func TestSessionRepository_ExtendByToken(t *testing.T) {
	pool := openDB(t)
	repo := repository.NewSessionRepository(pool)
	ctx := context.Background()
	userID := seedSessionUser(t, pool)

	const token = "extend-me-opaque-token"
	start := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	if err := repo.Create(ctx, &model.Session{
		UserID:    userID,
		TokenHash: repository.HashToken(token),
		ExpiresAt: start,
	}); err != nil {
		t.Fatalf("create: %v", err)
	}

	extended := time.Now().Add(30 * 24 * time.Hour).UTC().Truncate(time.Second)
	if err := repo.ExtendByToken(ctx, token, extended); err != nil {
		t.Fatalf("extend: %v", err)
	}

	got, err := repo.GetByToken(ctx, token)
	if err != nil {
		t.Fatalf("the token must still resolve after an extend: %v", err)
	}
	if !got.ExpiresAt.UTC().Truncate(time.Second).Equal(extended) {
		t.Errorf("expires_at = %v, want %v", got.ExpiresAt.UTC(), extended)
	}

	// Retrying a refresh whose response was lost must be harmless
	if err := repo.ExtendByToken(ctx, token, extended); err != nil {
		t.Fatalf("a repeated extend must succeed: %v", err)
	}
	if _, err := repo.GetByToken(ctx, token); err != nil {
		t.Fatalf("the session must survive a retried extend: %v", err)
	}
}

// Concurrent deletion must not be reported as a successful extension
func TestSessionRepository_ExtendByToken_MissingSessionFails(t *testing.T) {
	pool := openDB(t)
	repo := repository.NewSessionRepository(pool)

	err := repo.ExtendByToken(context.Background(), "no-such-token",
		time.Now().Add(time.Hour))
	if !errors.Is(err, repository.ErrSessionNotFound) {
		t.Fatalf("err = %v, want ErrSessionNotFound", err)
	}
}

func TestSessionRepository_GetByToken_MissingSessionReturnsSentinel(t *testing.T) {
	pool := openDB(t)
	repo := repository.NewSessionRepository(pool)

	_, err := repo.GetByToken(context.Background(), "no-such-token")
	if !errors.Is(err, repository.ErrSessionNotFound) {
		t.Fatalf("err = %v, want ErrSessionNotFound", err)
	}
}
