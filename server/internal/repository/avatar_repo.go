package repository

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrAvatarNotFound  = errors.New("avatar not found")
	ErrAvatarNotOwned  = errors.New("avatar belongs to another member")
	ErrAvatarConfirmed = errors.New("avatar already confirmed")
)

type AvatarRepository struct {
	DB *pgxpool.Pool
}

func NewAvatarRepository(db *pgxpool.Pool) *AvatarRepository {
	return &AvatarRepository{DB: db}
}

// Reserve replaces the member's pending upload. Takes the album lock so a
// revoke cannot land between the membership check and the insert
func (r *AvatarRepository) Reserve(ctx context.Context, a *model.MemberAvatar) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if err := lockActiveMember(ctx, tx, a.AlbumID, a.MemberToken); err != nil {
		return err
	}

	var prev struct {
		album     uuid.UUID
		token     []byte
		key       string
		size      int64
		sha       []byte
		confirmed bool
	}
	err = tx.QueryRow(ctx, `
		SELECT album_id, member_token, storage_key, blob_size, blob_sha256, confirmed
		FROM member_avatars WHERE avatar_id = $1 FOR UPDATE`, a.AvatarID,
	).Scan(&prev.album, &prev.token, &prev.key, &prev.size, &prev.sha, &prev.confirmed)
	switch {
	case err == nil && (prev.album != a.AlbumID || !bytes.Equal(prev.token, a.MemberToken)):
		return ErrAvatarNotOwned
	case err == nil && prev.confirmed:
		return ErrAvatarConfirmed
	case err == nil:
		// A retry of the same bytes may already have completed its PUT
		if prev.size == a.BlobSize && bytes.Equal(prev.sha, a.BlobSHA256) {
			a.StorageKey = prev.key
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return err
	}

	// One pending upload per member, keeping a key this reservation reuses
	stale, err := removeAvatars(ctx, tx, `
		DELETE FROM member_avatars
		WHERE album_id = $1 AND member_token = $2 AND confirmed = FALSE
		RETURNING storage_key`, a.AlbumID, a.MemberToken)
	if err != nil {
		return err
	}
	if err := unqueueObjectCleanup(ctx, tx, stale, a.StorageKey); err != nil {
		return err
	}

	if err := tx.QueryRow(ctx, `
		INSERT INTO member_avatars (
			avatar_id, album_id, member_token, storage_key, blob_size, blob_sha256, key_ct
		) VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING created_at`,
		a.AvatarID, a.AlbumID, a.MemberToken, a.StorageKey, a.BlobSize, a.BlobSHA256, a.KeyCT,
	).Scan(&a.CreatedAt); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Get returns one avatar row in the album regardless of confirmed state
func (r *AvatarRepository) Get(ctx context.Context, albumID, avatarID uuid.UUID) (*model.MemberAvatar, error) {
	var a model.MemberAvatar
	err := r.DB.QueryRow(ctx, `
		SELECT avatar_id, album_id, member_token, storage_key, blob_size,
		       blob_sha256, key_ct, confirmed, created_at
		FROM member_avatars WHERE avatar_id = $1 AND album_id = $2`,
		avatarID, albumID,
	).Scan(&a.AvatarID, &a.AlbumID, &a.MemberToken, &a.StorageKey, &a.BlobSize,
		&a.BlobSHA256, &a.KeyCT, &a.Confirmed, &a.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAvatarNotFound
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// Confirm swaps the pending upload in and returns the replaced object keys,
// already queued for cleanup. Confirming the current avatar again is a no op
func (r *AvatarRepository) Confirm(ctx context.Context, albumID uuid.UUID, memberToken []byte, avatarID uuid.UUID) ([]string, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	if err := lockActiveMember(ctx, tx, albumID, memberToken); err != nil {
		return nil, err
	}

	var confirmed bool
	err = tx.QueryRow(ctx, `
		SELECT confirmed FROM member_avatars
		WHERE avatar_id = $1 AND album_id = $2 AND member_token = $3`,
		avatarID, albumID, memberToken,
	).Scan(&confirmed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrAvatarNotFound
	}
	if err != nil {
		return nil, err
	}
	if confirmed {
		return nil, tx.Commit(ctx)
	}

	replaced, err := removeAvatars(ctx, tx, `
		DELETE FROM member_avatars
		WHERE album_id = $1 AND member_token = $2 AND avatar_id <> $3
		RETURNING storage_key`, albumID, memberToken, avatarID)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE member_avatars SET confirmed = TRUE WHERE avatar_id = $1`, avatarID,
	); err != nil {
		return nil, err
	}
	return replaced, tx.Commit(ctx)
}

// DropPending retires one unconfirmed upload whose object failed verification
func (r *AvatarRepository) DropPending(ctx context.Context, albumID uuid.UUID, memberToken []byte, avatarID uuid.UUID) ([]string, error) {
	return r.removeInTx(ctx, `
		DELETE FROM member_avatars
		WHERE avatar_id = $1 AND album_id = $2 AND member_token = $3 AND confirmed = FALSE
		RETURNING storage_key`, avatarID, albumID, memberToken)
}

// Remove deletes every avatar row the member has in the album
func (r *AvatarRepository) Remove(ctx context.Context, albumID uuid.UUID, memberToken []byte) ([]string, error) {
	return r.removeInTx(ctx, `
		DELETE FROM member_avatars WHERE album_id = $1 AND member_token = $2
		RETURNING storage_key`, albumID, memberToken)
}

// QueueStalePending retires abandoned uploads. SKIP LOCKED leaves rows that a
// confirm is holding
func (r *AvatarRepository) QueueStalePending(ctx context.Context, before time.Time, limit int) ([]string, error) {
	if limit <= 0 {
		return nil, nil
	}
	return r.removeInTx(ctx, `
		WITH stale AS (
			SELECT avatar_id FROM member_avatars
			WHERE confirmed = FALSE AND created_at <= $1
			ORDER BY created_at, avatar_id
			LIMIT $2
			FOR UPDATE SKIP LOCKED
		)
		DELETE FROM member_avatars m
		USING stale
		WHERE m.avatar_id = stale.avatar_id AND m.confirmed = FALSE
		RETURNING m.storage_key`, before, limit)
}

func (r *AvatarRepository) removeInTx(ctx context.Context, sql string, args ...any) ([]string, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	keys, err := removeAvatars(ctx, tx, sql, args...)
	if err != nil {
		return nil, err
	}
	return keys, tx.Commit(ctx)
}

// removeAvatars runs a DELETE returning storage_key and queues the keys before
// the caller commits. Album and identity cascades would drop rows silently, so
// every removal path calls this first
func removeAvatars(ctx context.Context, tx pgx.Tx, sql string, args ...any) ([]string, error) {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	var keys []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			rows.Close()
			return nil, err
		}
		keys = append(keys, key)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return keys, enqueueObjectCleanup(ctx, tx, keys)
}

// A reused key is live again and must not be deleted by the cleanup queue
func unqueueObjectCleanup(ctx context.Context, tx pgx.Tx, queued []string, keep string) error {
	for _, key := range queued {
		if key != keep {
			continue
		}
		if _, err := tx.Exec(ctx,
			`DELETE FROM media_object_cleanup WHERE storage_key = $1`, key); err != nil {
			return err
		}
	}
	return nil
}

func lockActiveMember(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, memberToken []byte) error {
	if err := lockAlbum(ctx, tx, albumID); err != nil {
		return err
	}
	var revoked bool
	err := tx.QueryRow(ctx,
		`SELECT revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, memberToken,
	).Scan(&revoked)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return ErrCallerRevoked
	}
	return err
}

// Nullable columns of a LEFT JOIN on the member's current avatar
type avatarColumns struct {
	id    *uuid.UUID
	size  *int64
	sha   []byte
	keyCT []byte
}

func (c avatarColumns) ref() *model.AvatarRef {
	if c.id == nil || c.size == nil {
		return nil
	}
	return &model.AvatarRef{AvatarID: *c.id, BlobSize: *c.size, BlobSHA256: c.sha, KeyCT: c.keyCT}
}
