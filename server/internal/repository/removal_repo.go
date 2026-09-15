package repository

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNotAlbumAdmin = errors.New("caller is not the album admin")

type AlbumRemoval struct {
	MemberUserIDs []uuid.UUID
	Keys          []string
}

type MediaRemoval struct {
	MediaIDs []uuid.UUID
	Keys     []string
}

// DeleteAlbumTx removes an album and queues every object it owned in the same
// transaction, so a crash can orphan neither rows nor encrypted blobs
func (r *AlbumRepository) DeleteAlbumTx(ctx context.Context, albumID uuid.UUID, callerToken []byte) (AlbumRemoval, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return AlbumRemoval{}, err
	}
	defer tx.Rollback(ctx)

	if err := lockAlbum(ctx, tx, albumID); err != nil {
		return AlbumRemoval{}, err
	}
	var role string
	var revoked bool
	err = tx.QueryRow(ctx,
		`SELECT role, revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, callerToken,
	).Scan(&role, &revoked)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return AlbumRemoval{}, ErrCallerRevoked
	}
	if err != nil {
		return AlbumRemoval{}, err
	}
	if role != "admin" {
		return AlbumRemoval{}, ErrNotAlbumAdmin
	}

	out, err := removeAlbum(ctx, tx, r.linker, albumID, callerToken)
	if err != nil {
		return AlbumRemoval{}, err
	}
	return out, tx.Commit(ctx)
}

func (r *MediaRepository) DeleteOwnedMedia(ctx context.Context, albumID, mediaID uuid.UUID, uploaderToken []byte) (MediaRemoval, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return MediaRemoval{}, err
	}
	defer tx.Rollback(ctx)

	if err := lockAlbum(ctx, tx, albumID); err != nil {
		return MediaRemoval{}, err
	}
	var owner []byte
	err = tx.QueryRow(ctx,
		`SELECT uploader_token FROM media
		 WHERE id = $1 AND album_id = $2 AND confirmed = TRUE`,
		mediaID, albumID,
	).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return MediaRemoval{}, ErrMediaNotFound
	}
	if err != nil {
		return MediaRemoval{}, err
	}
	if string(owner) != string(uploaderToken) {
		return MediaRemoval{}, ErrMediaNotOwned
	}

	out, err := removeMedia(ctx, tx,
		`DELETE FROM media WHERE id = $1 AND album_id = $2
		 RETURNING id, storage_key, thumb_key`, mediaID, albumID)
	if err != nil {
		return MediaRemoval{}, err
	}
	return out, tx.Commit(ctx)
}

func lockAlbum(ctx context.Context, tx pgx.Tx, albumID uuid.UUID) error {
	var locked uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, albumID).Scan(&locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrAlbumNotFound
	}
	return err
}

// removeAlbum must run under the album lock
func removeAlbum(ctx context.Context, tx pgx.Tx, linker *userlink.Hasher, albumID uuid.UUID, exceptToken []byte) (AlbumRemoval, error) {
	users, err := activeUserIDs(ctx, tx, linker, albumID, exceptToken)
	if err != nil {
		return AlbumRemoval{}, err
	}
	media, err := removeMedia(ctx, tx,
		`DELETE FROM media WHERE album_id = $1
		 RETURNING id, storage_key, thumb_key`, albumID)
	if err != nil {
		return AlbumRemoval{}, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM albums WHERE id = $1`, albumID); err != nil {
		return AlbumRemoval{}, err
	}
	return AlbumRemoval{MemberUserIDs: users, Keys: media.Keys}, nil
}

// removeMedia runs a DELETE returning (id, storage_key, thumb_key) and queues
// the keys before the caller commits
func removeMedia(ctx context.Context, tx pgx.Tx, sql string, args ...any) (MediaRemoval, error) {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return MediaRemoval{}, err
	}
	var out MediaRemoval
	for rows.Next() {
		var id uuid.UUID
		var key string
		var thumb *string
		if err := rows.Scan(&id, &key, &thumb); err != nil {
			rows.Close()
			return MediaRemoval{}, err
		}
		out.MediaIDs = append(out.MediaIDs, id)
		out.Keys = append(out.Keys, cleanupKeys(key, thumb)...)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return MediaRemoval{}, err
	}
	return out, enqueueObjectCleanup(ctx, tx, out.Keys)
}

func activeUserIDs(ctx context.Context, tx pgx.Tx, linker *userlink.Hasher, albumID uuid.UUID, exceptToken []byte) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx,
		`SELECT ami.member_token, ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.revoked_at IS NULL`,
		albumID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []uuid.UUID
	for rows.Next() {
		var token, sealed []byte
		if err := rows.Scan(&token, &sealed); err != nil {
			return nil, err
		}
		if string(token) == string(exceptToken) {
			continue
		}
		id, err := linker.Open(sealed, token)
		if err != nil {
			continue
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
