package epoch

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrAlbumNotFound  = errors.New("epoch: album not found")
	ErrEpochReplay    = errors.New("epoch: replay or non-monotonic")
	ErrMemberSetDrift = errors.New("epoch: active member set differs from request")
	ErrWrapNotFound   = errors.New("epoch: wrap not found for this recipient")
	ErrAdminNotFound  = errors.New("epoch: caller has no IK_pub on file")
)

type Repo struct {
	db     *pgxpool.Pool
	linker *userlink.Hasher
}

func NewRepo(db *pgxpool.Pool, linker *userlink.Hasher) *Repo {
	if linker == nil {
		panic("epoch.NewRepo: linker is required (M-bridge)")
	}
	return &Repo{db: db, linker: linker}
}

// CurrentEpoch returns (max_epoch, exists, started_at). exists=false when the
// album has no album_epochs row yet (next valid epoch is 0)
func (r *Repo) CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, bool, time.Time, error) {
	var (
		epoch     int
		startedAt time.Time
	)
	err := r.db.QueryRow(ctx,
		`SELECT epoch, started_at FROM album_epochs
		 WHERE album_id = $1 ORDER BY epoch DESC LIMIT 1`,
		albumID,
	).Scan(&epoch, &startedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return -1, false, time.Time{}, nil
	}
	if err != nil {
		return 0, false, time.Time{}, err
	}
	return epoch, true, startedAt, nil
}

// AdminIKByMemberToken resolves a member_token to its owner's IK_pub. Used to
// verify the envelope_sig on a set_epoch request. Two queries bcs the
// user_id is now sealed in amid.user_id_enc (M bridge) : recover it via
// linker.Open then lookup the IK
func (r *Repo) AdminIKByMemberToken(ctx context.Context, memberToken []byte) ([]byte, error) {
	var sealed []byte
	err := r.db.QueryRow(ctx,
		`SELECT user_id_enc FROM album_member_identities WHERE member_token = $1`,
		memberToken,
	).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAdminNotFound
	}
	if err != nil {
		return nil, err
	}
	userID, err := r.linker.Open(sealed, memberToken)
	if err != nil {
		return nil, ErrAdminNotFound
	}
	var ik []byte
	err = r.db.QueryRow(ctx, `SELECT ik_pub FROM users WHERE id = $1`, userID).Scan(&ik)
	if errors.Is(err, pgx.ErrNoRows) || len(ik) == 0 {
		return nil, ErrAdminNotFound
	}
	if err != nil {
		return nil, err
	}
	return ik, nil
}

// WrapInsert is one row per recipient that the service hands to InsertEpoch
type WrapInsert struct {
	RecipientToken []byte
	EkPub          []byte
	OpkIdxUsed     *int32
	WrapNonce      []byte
	WrapTagCT      []byte
	SenderSig      []byte
}

type InsertEpochInput struct {
	AlbumID               uuid.UUID
	Epoch                 int
	EpochSig              []byte
	SenderToken           []byte
	Wraps                 []WrapInsert
	ExpectedMemberSetHash []byte
}

// InsertEpoch atomically validates and writes one epoch transition

// .. Locks the album row (FOR UPDATE) to serialize concurrent rotators
// .. Re checks epoch == max(epoch)+1 inside the tx → ErrEpochReplay otherwise
// .. Re computes member_set_hash from album_members WHERE NOT revoked and
//
//	compares to ExpectedMemberSetHash → ErrMemberSetDrift otherwise

// .. Writes album_epochs row + per-recipient album_epoch_wraps rows
func (r *Repo) InsertEpoch(ctx context.Context, in InsertEpochInput) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var locked uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, in.AlbumID).Scan(&locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAlbumNotFound
	}
	if err != nil {
		return err
	}

	var maxEpoch int
	err = tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		in.AlbumID,
	).Scan(&maxEpoch)
	if err != nil {
		return err
	}
	if in.Epoch != maxEpoch+1 {
		return ErrEpochReplay
	}

	rows, err := tx.Query(ctx,
		`SELECT member_token FROM album_members
		 WHERE album_id = $1 AND revoked_at IS NULL
		 ORDER BY member_token`,
		in.AlbumID,
	)
	if err != nil {
		return err
	}
	var active [][]byte
	for rows.Next() {
		var tok []byte
		if err := rows.Scan(&tok); err != nil {
			rows.Close()
			return err
		}
		active = append(active, tok)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	gotHash := MemberSetHash(active)
	if !bytes.Equal(gotHash, in.ExpectedMemberSetHash) {
		return ErrMemberSetDrift
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO album_epochs (album_id, epoch, epoch_sig) VALUES ($1, $2, $3)`,
		in.AlbumID, in.Epoch, in.EpochSig,
	); err != nil {
		return err
	}

	for _, w := range in.Wraps {
		var opk any
		if w.OpkIdxUsed != nil {
			opk = *w.OpkIdxUsed
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, opk_idx_used,
			  wrap_nonce, wrap_tag_ct, sender_token, sender_sig)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			in.AlbumID, in.Epoch, w.RecipientToken, w.EkPub, opk,
			w.WrapNonce, w.WrapTagCT, in.SenderToken, w.SenderSig,
		); err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// Wrap is the read shape returned by GetWrap to the cold start client
type Wrap struct {
	Epoch       int
	EkPub       []byte
	OpkIdxUsed  *int32
	WrapNonce   []byte
	WrapTagCT   []byte
	SenderToken []byte
	SenderSig   []byte
	DeliveredAt time.Time
}

// GetWrap returns the wrap row for (album, epoch, recipient). The caller is
// trusted to have already enforced "recipient_token == self" upstream
func (r *Repo) GetWrap(ctx context.Context, albumID uuid.UUID, epochN int, recipient []byte) (*Wrap, error) {
	var (
		w   Wrap
		opk *int32
	)
	err := r.db.QueryRow(ctx,
		`SELECT ek_pub, opk_idx_used, wrap_nonce, wrap_tag_ct, sender_token, sender_sig, delivered_at
		 FROM album_epoch_wraps
		 WHERE album_id = $1 AND epoch = $2 AND recipient_token = $3`,
		albumID, epochN, recipient,
	).Scan(&w.EkPub, &opk, &w.WrapNonce, &w.WrapTagCT, &w.SenderToken, &w.SenderSig, &w.DeliveredAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrWrapNotFound
	}
	if err != nil {
		return nil, err
	}
	w.Epoch = epochN
	w.OpkIdxUsed = opk
	return &w, nil
}

// reports whether the album is in the transient window bw
// a member revoke and the admin's rotation : the live active member set differs
// from the current (max) epoch's recipient set. True when either an active
// member has no wrap at the current epoch (set shrank / member without keys) or
// a current epoch recipient is no longer an active member (a revoked member the
// rotation hasn't dropped yet). Backs the media upload freeze
func (r *Repo) PendingRotation(ctx context.Context, albumID uuid.UUID) (bool, error) {
	var pending bool
	err := r.db.QueryRow(ctx, `
WITH cur AS (
  SELECT COALESCE(MAX(epoch), -1) AS e FROM album_epochs WHERE album_id = $1
)
SELECT
  EXISTS (
    SELECT 1 FROM album_members m, cur
    WHERE m.album_id = $1 AND m.revoked_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM album_epoch_wraps w
        WHERE w.album_id = $1 AND w.epoch = cur.e AND w.recipient_token = m.member_token)
  )
  OR EXISTS (
    SELECT 1 FROM album_epoch_wraps w, cur
    WHERE w.album_id = $1 AND w.epoch = cur.e
      AND NOT EXISTS (
        SELECT 1 FROM album_members m
        WHERE m.album_id = $1 AND m.revoked_at IS NULL AND m.member_token = w.recipient_token)
  )`, albumID).Scan(&pending)
	return pending, err
}

// resolves a single member_token to its user_id,
// scoped to one album so a token that belongs to a different album is treated
// as not found. Backs the by nickname prekey bundle fetch : the seal is Opened
// with the token itself (M bridge nonce). repository.ErrMemberNotFound when the
// row is absent or the seal cannot be opened
func (r *Repo) UserIDByAlbumMemberToken(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error) {
	var sealed []byte
	err := r.db.QueryRow(ctx,
		`SELECT user_id_enc FROM album_member_identities WHERE album_id = $1 AND member_token = $2`,
		albumID, token,
	).Scan(&sealed)
	if err == pgx.ErrNoRows {
		return uuid.Nil, repository.ErrMemberNotFound
	}
	if err != nil {
		return uuid.Nil, err
	}
	u, err := r.linker.Open(sealed, token)
	if err != nil {
		return uuid.Nil, repository.ErrMemberNotFound
	}
	return u, nil
}

// UserIDsByMemberTokens resolves a set of member_tokens to their user_ids
// Each row's user_id is sealed in user_id_enc (M-bridge) : we fetch
// (member_token, user_id_enc) and Open each blob with its own member_token
// since the AEAD nonce is derived from member_token. Tokens that dont
// resolve (missing row or invalid seal) are silently skipped
func (r *Repo) UserIDsByMemberTokens(ctx context.Context, tokens [][]byte) ([]uuid.UUID, error) {
	if len(tokens) == 0 {
		return nil, nil
	}
	rows, err := r.db.Query(ctx,
		`SELECT member_token, user_id_enc FROM album_member_identities WHERE member_token = ANY($1)`,
		tokens,
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

// PendingMembers returns the member_tokens of non revoked members who have not
// proven (via join_complete) that they installed recent epochs and whose last
// acknowledgement (if any) is more than 24h old. newEpoch is the epoch just
// committed : a member is current if they acked >= newEpoch-1

// drives an admin "these members are behind" surface
func (r *Repo) PendingMembers(ctx context.Context, albumID uuid.UUID, newEpoch int) ([][]byte, error) {
	rows, err := r.db.Query(ctx,
		`SELECT am.member_token
		 FROM album_members am
		 JOIN album_member_identities amid ON amid.member_token = am.member_token
		 WHERE am.album_id = $1
		   AND am.revoked_at IS NULL
		   AND (amid.last_received_epoch IS NULL OR amid.last_received_epoch < $2 - 1)
		   AND (amid.last_received_at IS NULL OR amid.last_received_at < now() - interval '24 hours')`,
		albumID, newEpoch,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]byte
	for rows.Next() {
		var tok []byte
		if err := rows.Scan(&tok); err != nil {
			return nil, err
		}
		out = append(out, tok)
	}
	return out, rows.Err()
}
