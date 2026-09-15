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

var (
	ErrSenderRevoked   = errors.New("invite: sender is no longer an active member")
	ErrSenderNotAdmin  = errors.New("invite: sender is not the album admin")
	ErrEpochMoved      = errors.New("invite: envelopes no longer reach the current epoch")
	ErrPendingRotation = errors.New("invite: album owes a rotation")
	ErrTargetDeleting  = errors.New("invite: target account is being deleted")
)

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

// Opens the sealed user link before loading its identity key
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

// GREATEST prevents stale receipts from lowering the acknowledged epoch
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

// Opens each active member link and skips invalid seals
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

// Rechecks authority and epoch under the lock shared with revoke and rotation
func (r *Repo) recheckUnderLock(ctx context.Context, tx pgx.Tx, in DeliverMemberInput) error {
	var role string
	var revoked bool
	var sealed []byte
	err := tx.QueryRow(ctx,
		`SELECT am.role, am.revoked_at IS NOT NULL, ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.member_token = $2`,
		in.AlbumID, in.SenderToken,
	).Scan(&role, &revoked, &sealed)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return ErrSenderRevoked
	}
	if err != nil {
		return err
	}
	if role != "admin" {
		return ErrSenderNotAdmin
	}
	sender, err := r.linker.Open(sealed, in.SenderToken)
	if err != nil {
		return ErrSenderRevoked
	}

	// FOR SHARE waits out an account deletion being accepted, so neither side
	// can join an album the deletion job has already enumerated
	rows, err := tx.Query(ctx,
		`SELECT id, deleting_at IS NOT NULL FROM users
		 WHERE id = ANY($1) ORDER BY id FOR SHARE`,
		[]uuid.UUID{sender, in.UserID},
	)
	if err != nil {
		return err
	}
	deleting := map[uuid.UUID]bool{}
	for rows.Next() {
		var id uuid.UUID
		var d bool
		if err := rows.Scan(&id, &d); err != nil {
			rows.Close()
			return err
		}
		deleting[id] = d
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if d, ok := deleting[sender]; !ok || d {
		return ErrSenderRevoked
	}
	if d, ok := deleting[in.UserID]; !ok || d {
		return ErrTargetDeleting
	}

	var current int
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		in.AlbumID,
	).Scan(&current); err != nil {
		return err
	}
	if len(in.Envelopes) == 0 || in.Envelopes[len(in.Envelopes)-1].Epoch != current {
		return ErrEpochMoved
	}

	var owed bool
	if err := tx.QueryRow(ctx,
		`SELECT `+repository.RotationRequiredExpr("$1"), in.AlbumID,
	).Scan(&owed); err != nil {
		return err
	}
	if owed {
		return ErrPendingRotation
	}
	return nil
}

// Atomically creates or reactivates membership, stores wraps and consumes the OPK
func (r *Repo) DeliverMember(ctx context.Context, in DeliverMemberInput) ([]byte, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Serializes joins so concurrent invites cannot exceed the member cap
	var locked uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, in.AlbumID).Scan(&locked); err != nil {
		return nil, err
	}
	if err := r.recheckUnderLock(ctx, tx, in); err != nil {
		return nil, err
	}

	userHandle := r.linker.Hash(in.UserID)

	// Reactivation reuses the tombstoned token because signed history still references it
	var token []byte
	var revoked bool
	err = tx.QueryRow(ctx,
		`SELECT ami.member_token, am.revoked_at IS NOT NULL
		 FROM album_member_identities ami
		 JOIN album_members am ON am.album_id = ami.album_id AND am.member_token = ami.member_token
		 WHERE ami.user_handle = $1 AND ami.album_id = $2`,
		userHandle, in.AlbumID,
	).Scan(&token, &revoked)
	reactivate := err == nil
	if err != nil && err != pgx.ErrNoRows {
		return nil, err
	}
	if reactivate && !revoked {
		return nil, ErrAlreadyMember
	}

	if !reactivate {
		token = make([]byte, 32)
		if _, err := rand.Read(token); err != nil {
			return nil, err
		}
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
	}

	// Count after duplicate detection so an active member returns ErrAlreadyMember
	var active int
	if err := tx.QueryRow(ctx,
		`SELECT count(*) FROM album_members WHERE album_id = $1 AND revoked_at IS NULL`,
		in.AlbumID,
	).Scan(&active); err != nil {
		return nil, err
	}
	if active >= MaxAlbumMembers {
		return nil, ErrAlbumFull
	}

	if reactivate {
		// Rejoin as a plain member: drop the stale encrypted name (published
		// under an old epoch the returning member no longer holds)
		if _, err := tx.Exec(ctx,
			`UPDATE album_members SET revoked_at = NULL, role = 'member', name_ct = NULL
			 WHERE album_id = $1 AND member_token = $2`,
			in.AlbumID, token,
		); err != nil {
			return nil, err
		}
	} else {
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'member')`,
			in.AlbumID, token,
		); err != nil {
			return nil, err
		}
	}

	for _, e := range in.Envelopes {
		var opk any
		if in.OPKIdxUsed != nil {
			opk = *in.OPKIdxUsed
		}
		// Reactivated members replace wraps tied to their reused token
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, opk_idx_used,
			  wrap_nonce, wrap_tag_ct, sender_token, sender_sig)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
			 ON CONFLICT (album_id, epoch, recipient_token) DO UPDATE SET
			   ek_pub = EXCLUDED.ek_pub, opk_idx_used = EXCLUDED.opk_idx_used,
			   wrap_nonce = EXCLUDED.wrap_nonce, wrap_tag_ct = EXCLUDED.wrap_tag_ct,
			   sender_token = EXCLUDED.sender_token, sender_sig = EXCLUDED.sender_sig`,
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
