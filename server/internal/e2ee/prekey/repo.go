package prekey

import (
	"bytes"
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Repo bundles the prekey + identity + audit storage operations the e2ee
// handlers need. OPK CRUD is delegated to the existing repository.PrekeyRepository
// so the SQL stays in one place : identity/SPK + spk_rotations live here bcs
// they're new with §2.2 and want their own txn boundary
type Repo struct {
	db     *pgxpool.Pool
	prekey *repository.PrekeyRepository
}

func NewRepo(db *pgxpool.Pool, prekey *repository.PrekeyRepository) *Repo {
	return &Repo{db: db, prekey: prekey}
}

// Identity is the read shape for the bundle endpoint and validation pre checks
type Identity struct {
	IKPub  []byte
	LKPub  []byte
	SPKPub []byte
	SPKSig []byte
	SPKTs  *int64
}

// IdentityByID returns just the E2EE columns for a user. ErrUserNotFound bubbles
// up from the underlying users table
func (r *Repo) IdentityByID(ctx context.Context, userID uuid.UUID) (*Identity, error) {
	var id Identity
	err := r.db.QueryRow(ctx,
		`SELECT ik_pub, lk_pub, spk_pub, spk_sig, spk_ts FROM users WHERE id = $1`,
		userID,
	).Scan(&id.IKPub, &id.LKPub, &id.SPKPub, &id.SPKSig, &id.SPKTs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, repository.ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// ErrIdentityConflict means the account holds different public keys
var ErrIdentityConflict = errors.New("prekey: identity already published with different keys")

// PublishOrRefreshIdentity installs a new identity or accepts an identical
// retry. Guarded updates prevent races with rotation; the CASE expressions keep
// spk_sig and spk_ts paired without regressing the stored attestation
func (r *Repo) PublishOrRefreshIdentity(ctx context.Context, userID uuid.UUID, ikPub, lkPub, spkPub, spkSig []byte, spkTs int64) error {
	tag, err := r.db.Exec(ctx,
		`UPDATE users SET ik_pub=$1, lk_pub=$2, spk_pub=$3, spk_sig=$4, spk_ts=$5, updated_at=NOW()
		 WHERE id=$6 AND ik_pub IS NULL`,
		ikPub, lkPub, spkPub, spkSig, spkTs, userID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}

	tag, err = r.db.Exec(ctx,
		`UPDATE users SET
		   spk_sig = CASE WHEN spk_ts IS NULL OR $5 > spk_ts THEN $4 ELSE spk_sig END,
		   spk_ts  = CASE WHEN spk_ts IS NULL OR $5 > spk_ts THEN $5 ELSE spk_ts END,
		   updated_at = NOW()
		 WHERE id=$6 AND ik_pub=$1 AND lk_pub=$2 AND spk_pub=$3`,
		ikPub, lkPub, spkPub, spkSig, spkTs, userID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	return ErrIdentityConflict
}

// ErrTsNotMonotonic means spk_ts did not advance under the row lock
var ErrTsNotMonotonic = errors.New("prekey: spk_ts not strictly greater than stored spk_ts")

// RotateSPK locks the current timestamp, updates the SPK, and records the audit
// transition in one transaction so concurrent rotations remain ordered
func (r *Repo) RotateSPK(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var oldTs *int64
	if err := tx.QueryRow(ctx,
		`SELECT spk_ts FROM users WHERE id=$1 FOR UPDATE`, userID,
	).Scan(&oldTs); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return repository.ErrUserNotFound
		}
		return err
	}
	if oldTs != nil && spkTs <= *oldTs {
		return ErrTsNotMonotonic
	}

	if _, err := tx.Exec(ctx,
		`UPDATE users SET spk_pub=$1, spk_sig=$2, spk_ts=$3, updated_at=NOW() WHERE id=$4`,
		spkPub, spkSig, spkTs, userID,
	); err != nil {
		return err
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO spk_rotations (user_id, old_spk_ts, new_spk_ts)
		 VALUES ($1, $2, $3)`,
		userID, oldTs, spkTs,
	); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// SpkRotationCount returns the number of audit rows for a user : only used by tests
func (r *Repo) SpkRotationCount(ctx context.Context, userID uuid.UUID) (int, error) {
	var n int
	err := r.db.QueryRow(ctx,
		`SELECT COUNT(*) FROM spk_rotations WHERE user_id = $1`, userID,
	).Scan(&n)
	return n, err
}

// ErrOPKIndexTaken means an index is already bound to a different key
var ErrOPKIndexTaken = errors.New("prekey: opk_idx already taken")

// CreateBatchAtomic accepts identical retries, including consumed rows, without
// resurrecting them. A mismatched key rolls back the entire batch
func (r *Repo) CreateBatchAtomic(ctx context.Context, opks []model.OneTimePrekey) error {
	if len(opks) == 0 {
		return nil
	}
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, o := range opks {
		id := o.ID
		if id == uuid.Nil {
			id = uuid.New()
		}
		tag, err := tx.Exec(ctx,
			`INSERT INTO one_time_prekeys (id, user_id, opk_idx, key_pub) VALUES ($1, $2, $3, $4)
			 ON CONFLICT (user_id, opk_idx) DO NOTHING`,
			id, o.UserID, o.OPKIdx, o.KeyPub,
		)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			continue
		}
		var existing []byte
		if err := tx.QueryRow(ctx,
			`SELECT key_pub FROM one_time_prekeys WHERE user_id=$1 AND opk_idx=$2`,
			o.UserID, o.OPKIdx,
		).Scan(&existing); err != nil {
			return err
		}
		if !bytes.Equal(existing, o.KeyPub) {
			return ErrOPKIndexTaken
		}
	}
	return tx.Commit(ctx)
}

// PopRandom delegates to the underlying repository so the SKIP LOCKED query stays single source
func (r *Repo) PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error) {
	return r.prekey.PopRandom(ctx, userID)
}

func (r *Repo) Count(ctx context.Context, userID uuid.UUID) (int, error) {
	return r.prekey.Count(ctx, userID)
}
