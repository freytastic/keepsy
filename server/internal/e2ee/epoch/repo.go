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
	ErrCallerRevoked  = errors.New("epoch: caller is no longer an active member")
	ErrCallerNotAdmin = errors.New("epoch: caller is not the album admin")
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

// Opens the sealed user link before loading the epoch signer's identity key
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

// Rechecks signer, sequence and recipient set under the shared album lock
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

	// The role gate ran before this lock, so a signer removed in between would
	// otherwise mint a key it is no longer entitled to know
	var role string
	var revoked bool
	err = tx.QueryRow(ctx,
		`SELECT role, revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		in.AlbumID, in.SenderToken,
	).Scan(&role, &revoked)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return ErrCallerRevoked
	}
	if err != nil {
		return err
	}
	if role != "admin" {
		return ErrCallerNotAdmin
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

	// The wraps cover the exact active set, which settles any owed rotation
	if _, err := tx.Exec(ctx,
		`UPDATE albums SET rotation_required = FALSE WHERE id = $1`, in.AlbumID,
	); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

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

// The caller must already have enforced recipient_token == self
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

// Shared by the upload freeze and client recovery
func (r *Repo) RotationRequired(ctx context.Context, albumID uuid.UUID) (bool, error) {
	var required bool
	err := r.db.QueryRow(ctx,
		`SELECT `+repository.RotationRequiredExpr("$1"), albumID,
	).Scan(&required)
	return required, err
}

// Album scoping prevents a token from another album resolving here
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

// Opens each user link with its own member token and skips invalid seals
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

// Finds active members whose acknowledged epoch is stale by over 24 hours
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
