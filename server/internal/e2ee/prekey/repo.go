package prekey

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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

// UpsertIdentity writes the 5 E2EE columns. one shot enforcement (must be
// unset) is the service's job : this just executes the UPDATE
func (r *Repo) UpsertIdentity(ctx context.Context, userID uuid.UUID, ikPub, lkPub, spkPub, spkSig []byte, spkTs int64) error {
	_, err := r.db.Exec(ctx,
		`UPDATE users SET ik_pub=$1, lk_pub=$2, spk_pub=$3, spk_sig=$4, spk_ts=$5, updated_at=NOW() WHERE id=$6`,
		ikPub, lkPub, spkPub, spkSig, spkTs, userID,
	)
	return err
}

// SpkRotation captures the audit row written alongside an SPK update
type SpkRotation struct {
	OldSpkTs  *int64
	NewSpkTs  int64
	IP        string
	UserAgent string
}

// RotateSPK updates users.spk_* and inserts one spk_rotations audit row in a
// single txn so a failed audit cannot leave a rotated SPK without history
func (r *Repo) RotateSPK(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64, audit SpkRotation) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx,
		`UPDATE users SET spk_pub=$1, spk_sig=$2, spk_ts=$3, updated_at=NOW() WHERE id=$4`,
		spkPub, spkSig, spkTs, userID,
	); err != nil {
		return err
	}

	var ip any
	if audit.IP != "" {
		ip = audit.IP
	}
	var ua any
	if audit.UserAgent != "" {
		ua = audit.UserAgent
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO spk_rotations (user_id, old_spk_ts, new_spk_ts, ip, user_agent)
		 VALUES ($1, $2, $3, $4, $5)`,
		userID, audit.OldSpkTs, audit.NewSpkTs, ip, ua,
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

// ErrOPKIndexTaken signals a unique violation on (user_id, opk_idx) during CreateBatchAtomic
var ErrOPKIndexTaken = errors.New("prekey: opk_idx already taken")

// CreateBatchAtomic inserts every OPK in one txn : any duplicate (user_id, opk_idx)
// rolls the whole batch back and returns ErrOPKIndexTaken
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
		if _, err := tx.Exec(ctx,
			`INSERT INTO one_time_prekeys (id, user_id, opk_idx, key_pub) VALUES ($1, $2, $3, $4)`,
			id, o.UserID, o.OPKIdx, o.KeyPub,
		); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				return ErrOPKIndexTaken
			}
			return err
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
