package invite

import (
	"context"
	"crypto/rand"
	"errors"

	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrIKNotFound : the caller's member_token does not resolve to a user with a
// published identity. Treated as a signature failure at the service boundary
var ErrIKNotFound = errors.New("invite: member has no IK on file")

type Repo struct {
	db     *pgxpool.Pool
	linker *userlink.Hasher
	users  *repository.UserRepository
}

func NewRepo(db *pgxpool.Pool, linker *userlink.Hasher, users *repository.UserRepository) *Repo {
	if linker == nil || users == nil {
		panic("invite.NewRepo: linker and users are required (M-bridge + keepsy_id lookup)")
	}
	return &Repo{db: db, linker: linker, users: users}
}

func (r *Repo) FindUserIDByKeepsyID(ctx context.Context, keepsyID string) (uuid.UUID, error) {
	return r.users.FindUserIDByKeepsyID(ctx, keepsyID)
}

func (r *Repo) CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, error) {
	var epoch int
	err := r.db.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		albumID,
	).Scan(&epoch)
	if err != nil {
		return 0, err
	}
	return epoch, nil
}

// IKByMemberToken resolves the caller's member_token to its owner's IK_pub by
// opening the M bridge seal then reading users.ik_pub. Mirrors the epoch repo's
// AdminIKByMemberToken: the user_id is sealed at rest so it takes two hops
func (r *Repo) IKByMemberToken(ctx context.Context, memberToken []byte) ([]byte, error) {
	var sealed []byte
	err := r.db.QueryRow(ctx,
		`SELECT user_id_enc FROM album_member_identities WHERE member_token = $1`,
		memberToken,
	).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrIKNotFound
	}
	if err != nil {
		return nil, err
	}
	userID, err := r.linker.Open(sealed, memberToken)
	if err != nil {
		return nil, ErrIKNotFound
	}
	var ik []byte
	err = r.db.QueryRow(ctx, `SELECT ik_pub FROM users WHERE id = $1`, userID).Scan(&ik)
	if errors.Is(err, pgx.ErrNoRows) || len(ik) == 0 {
		return nil, ErrIKNotFound
	}
	if err != nil {
		return nil, err
	}
	return ik, nil
}

// MarkReceived records the join_complete high-water mark. GREATEST + COALESCE
// keep the max epoch the member ever acknowledged, so a stale receipt can't
// regress it
func (r *Repo) MarkReceived(ctx context.Context, memberToken []byte, epoch int) error {
	_, err := r.db.Exec(ctx,
		`UPDATE album_member_identities
		 SET last_received_epoch = GREATEST(COALESCE(last_received_epoch, -1), $2),
		     last_received_at = now()
		 WHERE member_token = $1`,
		memberToken, epoch,
	)
	return err
}

// ActiveMemberUserIDs returns the user_ids of every nonrevoked member of the
// album, opening each M bridge seal with its own member_token. Tokens that fail
// to open are skipped. Used to fan out member_added to the existing roster
func (r *Repo) ActiveMemberUserIDs(ctx context.Context, albumID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := r.db.Query(ctx,
		`SELECT amid.member_token, amid.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities amid ON amid.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.revoked_at IS NULL`,
		albumID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []uuid.UUID
	for rows.Next() {
		var tok, sealed []byte
		if err := rows.Scan(&tok, &sealed); err != nil {
			return nil, err
		}
		u, err := r.linker.Open(sealed, tok)
		if err != nil {
			continue
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// DeliverMember mints a member_token for the target and, in one tx, writes the
// M bridge identity row, the album_members row, every per epoch wrap, and marks
// the consumed OPK. A unique violation on (user_handle, album_id) means the
// target is already a member → ErrAlreadyMember (idempotent re invite)
func (r *Repo) DeliverMember(ctx context.Context, in DeliverMemberInput) ([]byte, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		return nil, err
	}
	userHandle := r.linker.Hash(in.UserID)
	sealed, err := r.linker.Seal(in.UserID, token)
	if err != nil {
		return nil, err
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
		token, userHandle, sealed, in.AlbumID,
	); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrAlreadyMember
		}
		return nil, err
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'member')`,
		in.AlbumID, token,
	); err != nil {
		return nil, err
	}

	for _, e := range in.Envelopes {
		var opk any
		if in.OPKIdxUsed != nil {
			opk = *in.OPKIdxUsed
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, opk_idx_used,
			  wrap_nonce, wrap_tag_ct, sender_token, sender_sig)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			in.AlbumID, e.Epoch, token, in.EKPub, opk,
			e.WrapNonce, e.WrapTagCT, in.SenderToken, e.SenderSig,
		); err != nil {
			return nil, err
		}
	}

	if in.OPKIdxUsed != nil {
		if _, err := tx.Exec(ctx,
			`UPDATE one_time_prekeys SET consumed = TRUE WHERE user_id = $1 AND opk_idx = $2`,
			in.UserID, *in.OPKIdxUsed,
		); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return token, nil
}
