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

func (r *PrekeyRepository) CreateBatch(ctx context.Context, opks []model.OneTimePrekey) error {
	if len(opks) == 0 {
		return nil
	}
	batch := &pgx.Batch{}
	for _, o := range opks {
		id := o.ID
		if id == uuid.Nil {
			id = uuid.New()
		}
		batch.Queue(
			`INSERT INTO one_time_prekeys (id, user_id, opk_idx, key_pub)
			 VALUES ($1, $2, $3, $4)`,
			id, o.UserID, o.OPKIdx, o.KeyPub)
	}
	return r.DB.SendBatch(ctx, batch).Close()
}

// PopRandom marks one unconsumed OPK as consumed and returns it. Atomic via
// FOR UPDATE SKIP LOCKED so concurrent prekey bundle fetches never claim the
// same row. acc to L3: consumed is a BOOLEAN flag, no consumed_by_user/at metadata
func (r *PrekeyRepository) PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error) {
	var o model.OneTimePrekey
	err := r.DB.QueryRow(ctx, `
		UPDATE one_time_prekeys SET consumed = TRUE
		WHERE id = (
			SELECT id FROM one_time_prekeys
			WHERE user_id = $1 AND consumed = FALSE
			LIMIT 1 FOR UPDATE SKIP LOCKED
		)
		RETURNING id, user_id, opk_idx, key_pub, consumed, created_at`,
		userID,
	).Scan(&o.ID, &o.UserID, &o.OPKIdx, &o.KeyPub, &o.Consumed, &o.CreatedAt)
	if err == pgx.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &o, nil
}

func (r *PrekeyRepository) Count(ctx context.Context, userID uuid.UUID) (int, error) {
	var c int
	err := r.DB.QueryRow(ctx,
		`SELECT COUNT(*) FROM one_time_prekeys WHERE user_id = $1 AND consumed = FALSE`,
		userID,
	).Scan(&c)
	return c, err
}
