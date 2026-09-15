package repository

import (
	"context"
	"errors"
	"time"

	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrAccountDeleting   = errors.New("account is being deleted")
	ErrDeletionPlanStale = errors.New("deletion plan no longer matches the account")
	ErrReceiptAbandoned  = errors.New("deletion receipt was abandoned by its device")
)

type DeletionOutcome string

const (
	OutcomeLeave        DeletionOutcome = "leave"
	OutcomeDeleteAlbum  DeletionOutcome = "delete_album"
	OutcomeDeleteShared DeletionOutcome = "delete_shared"
	OutcomeErase        DeletionOutcome = "erase"
)

type DeletionMembership struct {
	AlbumID       uuid.UUID
	MemberToken   []byte
	Role          string
	Active        bool
	ActiveMembers int
	OwnMedia      int
}

// Keeps preflight, plan validation and job execution on the same decision
func (m DeletionMembership) Outcome() DeletionOutcome {
	switch {
	case !m.Active:
		return OutcomeErase
	case m.ActiveMembers <= 1:
		return OutcomeDeleteAlbum
	case m.Role == "admin":
		return OutcomeDeleteShared
	default:
		return OutcomeLeave
	}
}

type MembershipRemoval struct {
	AlbumID       uuid.UUID
	MemberToken   []byte
	Outcome       DeletionOutcome
	NotifyUserIDs []uuid.UUID
	MediaIDs      []uuid.UUID
	Keys          []string
}

type AccountDeletionRepository struct {
	DB     *pgxpool.Pool
	linker *userlink.Hasher
}

func NewAccountDeletionRepository(db *pgxpool.Pool, linker *userlink.Hasher) *AccountDeletionRepository {
	if linker == nil {
		panic("AccountDeletionRepository: linker is required (M-bridge)")
	}
	return &AccountDeletionRepository{DB: db, linker: linker}
}

type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func (r *AccountDeletionRepository) Memberships(ctx context.Context, userID uuid.UUID) ([]DeletionMembership, error) {
	return r.memberships(ctx, r.DB, userID, nil)
}

func (r *AccountDeletionRepository) memberships(ctx context.Context, q querier, userID uuid.UUID, albumID *uuid.UUID) ([]DeletionMembership, error) {
	rows, err := q.Query(ctx, `
		SELECT ami.album_id, ami.member_token, COALESCE(am.role, 'member'),
		       am.member_token IS NOT NULL AND am.revoked_at IS NULL,
		       (SELECT count(*) FROM album_members x
		        WHERE x.album_id = ami.album_id AND x.revoked_at IS NULL),
		       (SELECT count(*) FROM media m
		        WHERE m.album_id = ami.album_id AND m.uploader_token = ami.member_token
		          AND m.confirmed = TRUE)
		FROM album_member_identities ami
		LEFT JOIN album_members am
		       ON am.album_id = ami.album_id AND am.member_token = ami.member_token
		WHERE ami.user_handle = $1 AND ($2::uuid IS NULL OR ami.album_id = $2)
		ORDER BY ami.album_id`,
		r.linker.Hash(userID), albumID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DeletionMembership
	for rows.Next() {
		var m DeletionMembership
		if err := rows.Scan(&m.AlbumID, &m.MemberToken, &m.Role, &m.Active,
			&m.ActiveMembers, &m.OwnMedia); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Atomically validates the plan, records the receipt and queues deletion
func (r *AccountDeletionRepository) Accept(ctx context.Context, userID uuid.UUID, confirmedShared []uuid.UUID, receiptHash []byte) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Invites take this row FOR SHARE, so no album can become shared between
	// the plan check below and the commit
	var deleting bool
	err = tx.QueryRow(ctx,
		`SELECT deleting_at IS NOT NULL FROM users WHERE id = $1 FOR UPDATE`, userID,
	).Scan(&deleting)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUserNotFound
	}
	if err != nil {
		return err
	}
	if err := claimReceipt(ctx, tx, receiptHash); err != nil {
		return err
	}
	if deleting {
		return tx.Commit(ctx)
	}

	current, err := r.memberships(ctx, tx, userID, nil)
	if err != nil {
		return err
	}
	confirmed := make(map[uuid.UUID]bool, len(confirmedShared))
	for _, id := range confirmedShared {
		confirmed[id] = true
	}
	for _, m := range current {
		if m.Outcome() == OutcomeDeleteShared && !confirmed[m.AlbumID] {
			return ErrDeletionPlanStale
		}
	}

	if _, err := tx.Exec(ctx,
		`UPDATE users SET deleting_at = date_trunc('hour', now()) WHERE id = $1`, userID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_deletions (user_id) VALUES ($1) ON CONFLICT DO NOTHING`, userID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1`, userID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Inserting first serializes acceptance and abandonment on the receipt row
func claimReceipt(ctx context.Context, tx pgx.Tx, receiptHash []byte) error {
	tag, err := tx.Exec(ctx,
		`INSERT INTO account_deletion_receipts (receipt_hash) VALUES ($1) ON CONFLICT DO NOTHING`,
		receiptHash)
	if err != nil || tag.RowsAffected() == 1 {
		return err
	}
	var abandoned bool
	if err := tx.QueryRow(ctx,
		`SELECT abandoned FROM account_deletion_receipts WHERE receipt_hash = $1`,
		receiptHash).Scan(&abandoned); err != nil {
		return err
	}
	if abandoned {
		return ErrReceiptAbandoned
	}
	return nil
}

func (r *AccountDeletionRepository) ReceiptAccepted(ctx context.Context, receiptHash []byte) (bool, error) {
	var ok bool
	err := r.DB.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM account_deletion_receipts
		 WHERE receipt_hash = $1 AND NOT abandoned)`,
		receiptHash).Scan(&ok)
	return ok, err
}

// Returns true when acceptance already won and the device must still wipe
func (r *AccountDeletionRepository) AbandonReceipt(ctx context.Context, receiptHash []byte) (bool, error) {
	tag, err := r.DB.Exec(ctx,
		`INSERT INTO account_deletion_receipts (receipt_hash, abandoned) VALUES ($1, TRUE)
		 ON CONFLICT DO NOTHING`,
		receiptHash)
	if err != nil || tag.RowsAffected() == 1 {
		return false, err
	}
	var abandoned bool
	if err := r.DB.QueryRow(ctx,
		`SELECT abandoned FROM account_deletion_receipts WHERE receipt_hash = $1`,
		receiptHash).Scan(&abandoned); err != nil {
		return false, err
	}
	return !abandoned, nil
}

func (r *AccountDeletionRepository) PruneReceipts(ctx context.Context, before time.Time) error {
	_, err := r.DB.Exec(ctx, `DELETE FROM account_deletion_receipts WHERE accepted_at < $1`, before)
	return err
}

// Pushing back the attempt time makes a crashed worker's lease expire naturally
func (r *AccountDeletionRepository) ClaimDue(ctx context.Context) (uuid.UUID, bool, error) {
	var id uuid.UUID
	err := r.DB.QueryRow(ctx, `
		UPDATE account_deletions d
		SET attempts = d.attempts + 1,
		    next_attempt_at = now() +
		        LEAST(5 * POWER(2, LEAST(d.attempts, 6))::int, 360) * interval '1 minute'
		WHERE d.user_id = (
			SELECT user_id FROM account_deletions
			WHERE next_attempt_at <= now()
			ORDER BY next_attempt_at, user_id
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		)
		RETURNING d.user_id`).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, false, nil
	}
	if err != nil {
		return uuid.Nil, false, err
	}
	return id, true, nil
}

// Re-derives the outcome under the album lock so retries converge safely
func (r *AccountDeletionRepository) RemoveMembership(ctx context.Context, userID, albumID uuid.UUID) (MembershipRemoval, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return MembershipRemoval{}, err
	}
	defer tx.Rollback(ctx)

	out := MembershipRemoval{AlbumID: albumID}
	if err := lockAlbum(ctx, tx, albumID); errors.Is(err, ErrAlbumNotFound) {
		return out, tx.Commit(ctx)
	} else if err != nil {
		return MembershipRemoval{}, err
	}

	found, err := r.memberships(ctx, tx, userID, &albumID)
	if err != nil {
		return MembershipRemoval{}, err
	}
	if len(found) == 0 {
		return out, tx.Commit(ctx)
	}
	m := found[0]
	out.MemberToken = m.MemberToken
	out.Outcome = m.Outcome()

	switch out.Outcome {
	case OutcomeDeleteAlbum, OutcomeDeleteShared:
		removed, err := removeAlbum(ctx, tx, r.linker, albumID, m.MemberToken)
		if err != nil {
			return MembershipRemoval{}, err
		}
		out.NotifyUserIDs = removed.MemberUserIDs
		out.Keys = removed.Keys
		return out, tx.Commit(ctx)
	case OutcomeLeave:
		if _, err := tx.Exec(ctx,
			`UPDATE album_members SET revoked_at = NOW()
			 WHERE album_id = $1 AND member_token = $2`,
			albumID, m.MemberToken,
		); err != nil {
			return MembershipRemoval{}, err
		}
		// The departing account still holds the current key
		if _, err := tx.Exec(ctx,
			`UPDATE albums SET rotation_required = TRUE WHERE id = $1`, albumID,
		); err != nil {
			return MembershipRemoval{}, err
		}
	}

	media, err := removeMedia(ctx, tx,
		`DELETE FROM media WHERE album_id = $1 AND uploader_token = $2
		 RETURNING id, storage_key, thumb_key`, albumID, m.MemberToken)
	if err != nil {
		return MembershipRemoval{}, err
	}
	out.MediaIDs = media.MediaIDs
	out.Keys = media.Keys

	if out.NotifyUserIDs, err = activeUserIDs(ctx, tx, r.linker, albumID, m.MemberToken); err != nil {
		return MembershipRemoval{}, err
	}
	// Severs the account from the album: the bridge row, its roster row and
	// its wraps all go, leaving nothing that links back to the user
	if _, err := tx.Exec(ctx,
		`DELETE FROM album_member_identities WHERE member_token = $1`, m.MemberToken,
	); err != nil {
		return MembershipRemoval{}, err
	}
	return out, tx.Commit(ctx)
}

// Returns false if a membership appeared and the job needs another pass
func (r *AccountDeletionRepository) FinishAccount(ctx context.Context, userID uuid.UUID) (bool, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)

	// Album creation and invites take this row FOR SHARE, so none can land
	// between the check and the delete
	var locked uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return true, tx.Commit(ctx)
	}
	if err != nil {
		return false, err
	}
	var remaining bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM album_member_identities WHERE user_handle = $1)`,
		r.linker.Hash(userID),
	).Scan(&remaining); err != nil {
		return false, err
	}
	if remaining {
		return false, tx.Commit(ctx)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
