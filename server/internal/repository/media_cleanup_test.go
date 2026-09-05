package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

func insertPendingMedia(t *testing.T, env *summaryEnv, albumID uuid.UUID, uploader []byte, createdAt time.Time, withThumb bool) *model.Media {
	t.Helper()
	id := uuid.New()
	storageKey := "cleanup-file-" + id.String()
	var thumbKey *string
	if withThumb {
		key := "cleanup-thumb-" + id.String()
		thumbKey = &key
	}
	if _, err := env.pool.Exec(context.Background(), `
		INSERT INTO media (
			id, album_id, uploader_token, storage_key, thumb_key,
			wrap_nonce, wrap_tag_ct, epoch_tag, blob_size, blob_sha256,
			media_type, confirmed, created_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,0,1,$8,'photo',FALSE,$9)`,
		id, albumID, uploader, storageKey, thumbKey, make([]byte, 12),
		make([]byte, 48), make([]byte, 32), createdAt,
	); err != nil {
		t.Fatalf("insert pending media: %v", err)
	}
	return &model.Media{
		ID: id, AlbumID: albumID, UploaderToken: uploader,
		StorageKey: storageKey, ThumbKey: thumbKey, CreatedAt: createdAt,
	}
}

func TestQueuePendingCleanup_RequiresUploaderAndPersistsKeys(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("cleanup"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cleanup-%'`)
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	pending := insertPendingMedia(t, env, album.ID, token, time.Now(), true)

	foreign, err := env.media.QueuePendingCleanup(ctx, pending.ID, album.ID, []byte("another-member"))
	if err != nil {
		t.Fatalf("foreign QueuePendingCleanup: %v", err)
	}
	if foreign.MediaCount != 0 {
		t.Fatalf("foreign member retired %d rows", foreign.MediaCount)
	}
	if _, err := env.media.GetByID(ctx, pending.ID, album.ID); err != nil {
		t.Fatalf("foreign abort removed pending row: %v", err)
	}

	batch, err := env.media.QueuePendingCleanup(ctx, pending.ID, album.ID, token)
	if err != nil {
		t.Fatalf("owner QueuePendingCleanup: %v", err)
	}
	if batch.MediaCount != 1 || len(batch.Keys) != 2 {
		t.Fatalf("batch = %+v, want one row and two keys", batch)
	}
	keys, err := env.media.ListObjectCleanupKeys(ctx, 10)
	if err != nil {
		t.Fatalf("ListObjectCleanupKeys: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("queued keys = %v, want two", keys)
	}
	for _, key := range keys {
		if err := env.media.DeleteObjectCleanupKey(ctx, key); err != nil {
			t.Fatalf("DeleteObjectCleanupKey: %v", err)
		}
	}
}

func TestQueueStalePendingCleanup_LeavesRecentRows(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("stale-cleanup"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cleanup-%'`)
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	now := time.Now()
	old := insertPendingMedia(t, env, album.ID, token, now.Add(-3*time.Hour), false)
	recent := insertPendingMedia(t, env, album.ID, token, now.Add(-30*time.Minute), false)

	batch, err := env.media.QueueStalePendingCleanup(ctx, now.Add(-2*time.Hour), 10)
	if err != nil {
		t.Fatalf("QueueStalePendingCleanup: %v", err)
	}
	if batch.MediaCount != 1 || len(batch.Keys) != 1 || batch.Keys[0] != old.StorageKey {
		t.Fatalf("batch = %+v, want only old row", batch)
	}
	if _, err := env.media.GetByID(ctx, recent.ID, album.ID); err != nil {
		t.Fatalf("recent pending row was retired: %v", err)
	}
}

// Covers the PostgreSQL backoff expression, which a mock cannot verify
func TestRescheduleObjectCleanupKey_BacksOffPastTheSweepInterval(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("backoff"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cleanup-%'`)
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	pending := insertPendingMedia(t, env, album.ID, token, time.Now(), false)
	if _, err := env.media.QueuePendingCleanup(ctx, pending.ID, album.ID, token); err != nil {
		t.Fatalf("QueuePendingCleanup: %v", err)
	}

	attempts, err := env.media.RescheduleObjectCleanupKey(ctx, pending.StorageKey)
	if err != nil {
		t.Fatalf("RescheduleObjectCleanupKey: %v", err)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1", attempts)
	}

	var delay time.Duration
	if err := env.pool.QueryRow(ctx, `
		SELECT next_attempt_at - now() FROM media_object_cleanup
		WHERE storage_key = $1`, pending.StorageKey).Scan(&delay); err != nil {
		t.Fatalf("read next_attempt_at: %v", err)
	}
	if delay <= 10*time.Minute {
		t.Fatalf("first backoff = %v, must exceed the ten minute sweep", delay)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 10)
	if err != nil {
		t.Fatalf("ListObjectCleanupKeys: %v", err)
	}
	for _, key := range keys {
		if key == pending.StorageKey {
			t.Fatal("a backed off key was still served as due")
		}
	}

	if _, err := env.media.RescheduleObjectCleanupKey(ctx, "cleanup-does-not-exist"); err != nil {
		t.Fatalf("reschedule of an absent key: %v", err)
	}
}

func TestListObjectCleanupKeys_ServesFewestAttemptsFirst(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cleanup-%'`)
	})

	if _, err := env.pool.Exec(ctx, `
		INSERT INTO media_object_cleanup (storage_key, enqueued_at, attempts, next_attempt_at)
		VALUES ('cleanup-poison', now() - interval '2 hours', 9, now() - interval '1 minute'),
		       ('cleanup-fresh',  now(),                      0, now() - interval '1 minute')`,
	); err != nil {
		t.Fatalf("seed queue: %v", err)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 10)
	if err != nil {
		t.Fatalf("ListObjectCleanupKeys: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("keys = %v, want both due", keys)
	}
	if keys[0] != "cleanup-fresh" {
		t.Fatalf("served %q first, want the key with fewer attempts", keys[0])
	}
}
