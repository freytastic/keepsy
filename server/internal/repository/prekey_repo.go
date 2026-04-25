package repository

import (
	"context"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type PrekeyRepository struct {
	DB *pgxpool.Pool
}

func NewPrekeyRepository(db *pgxpool.Pool) *PrekeyRepository {
	return &PrekeyRepository{DB: db}
}

// CreateBatch inserts a list of OPKs for a user
func (r *PrekeyRepository) CreateBatch(ctx context.Context, opks []model.OneTimePrekey) error {
	if len(opks) == 0 {
		return nil
	}

	batch := &pgx.Batch{}
	query := `INSERT INTO one_time_prekeys (id, user_id, key_content) VALUES ($1, $2, $3)`

	for _, opk := range opks {
		id := opk.ID
		if id == uuid.Nil {
			id = uuid.New()
		}
		batch.Queue(query, id, opk.UserID, opk.KeyContent)
	}

	results := r.DB.SendBatch(ctx, batch)
	return results.Close()
}

// PopRandom fetches one random OPK for a user and deletes it atomically
func (r *PrekeyRepository) PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	var opk model.OneTimePrekey
	// Using SKIP LOCKED to handle concurrent requests,
	// tho serializing on the same userID is more likely
	query := `
		DELETE FROM one_time_prekeys
		WHERE id = (
			SELECT id FROM one_time_prekeys
			WHERE user_id = $1
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		)
		RETURNING id, user_id, key_content, created_at
	`

	err = tx.QueryRow(ctx, query, userID).Scan(&opk.ID, &opk.UserID, &opk.KeyContent, &opk.CreatedAt)
	if err == pgx.ErrNoRows {
		return nil, nil // No OPKs left
	}
	if err != nil {
		return nil, err
	}

	err = tx.Commit(ctx)
	if err != nil {
		return nil, err
	}

	return &opk, nil
}

func (r *PrekeyRepository) Count(ctx context.Context, userID uuid.UUID) (int, error) {
	var count int
	query := `SELECT COUNT(*) FROM one_time_prekeys WHERE user_id = $1`
	err := r.DB.QueryRow(ctx, query, userID).Scan(&count)
	return count, err
}
