package repository_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

// Uses the real repository because retry behavior is transactional SQL
func reserveEnv(t *testing.T) (*summaryEnv, uuid.UUID, []byte) {
	t.Helper()
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("reserve"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_epochs (album_id, epoch) VALUES ($1, 0)`, album.ID,
	); err != nil {
		t.Fatalf("seed epoch: %v", err)
	}
	// A complete epoch wrap is required before uploads are allowed
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_epoch_wraps
		   (album_id, epoch, recipient_token, ek_pub, wrap_nonce, wrap_tag_ct,
		    sender_token, sender_sig)
		 VALUES ($1, 0, $2, $3, $4, $5, $2, $6)`,
		album.ID, token, make([]byte, 32), make([]byte, 12), make([]byte, 48),
		make([]byte, 64),
	); err != nil {
		t.Fatalf("seed wrap: %v", err)
	}
	return env, album.ID, token
}

func pendingRow(albumID, mediaID uuid.UUID, token []byte, storageKey, thumbKey string) *model.Media {
	thumb := thumbKey
	size := int64(64)
	return &model.Media{
		ID:             mediaID,
		AlbumID:        albumID,
		UploaderToken:  token,
		StorageKey:     storageKey,
		ThumbKey:       &thumb,
		WrapNonce:      make([]byte, 12),
		WrapTagCT:      make([]byte, 48),
		EpochTag:       0,
		BlobSize:       4096,
		BlobSHA256:     make([]byte, 32),
		MediaType:      "photo",
		ThumbWrapNonce: make([]byte, 12),
		ThumbWrapTagCT: make([]byte, 48),
		ThumbSize:      &size,
		ThumbSHA256:    make([]byte, 32),
	}
}

func TestReserveUploadRow_RetryDoesNotCollide(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-one", "thumb-one")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-two", "thumb-two")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("retry reserve must not hit the primary key, got: %v", err)
	}

	row, err := env.media.GetByID(ctx, mediaID, albumID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.Confirmed {
		t.Error("the replacement row must still be pending")
	}
	if row.StorageKey != second.StorageKey {
		t.Errorf("row key = %q, reservation reported %q",
			row.StorageKey, second.StorageKey)
	}
}

// A thumbnail retry must keep the key of an already uploaded file
func TestReserveUploadRow_RePresignKeepsKeysWhenBytesAreIdentical(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-stable", "thumb-stable")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-fresh", "thumb-fresh")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("re presign: %v", err)
	}
	if second.StorageKey != "key-stable" {
		t.Errorf("storage_key = %q, want the original key kept", second.StorageKey)
	}
	if second.ThumbKey == nil || *second.ThumbKey != "thumb-stable" {
		t.Errorf("thumb_key = %v, want the original thumb key kept", second.ThumbKey)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 10)
	if err != nil {
		t.Fatalf("cleanup keys: %v", err)
	}
	for _, k := range keys {
		if k == "key-stable" || k == "thumb-stable" {
			t.Errorf("%q is still live and must not be queued for deletion", k)
		}
	}
}

func TestReserveUploadRow_NewBytesGetNewKeys(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-old", "thumb-old")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-new", "thumb-new")
	second.BlobSHA256 = bytes.Repeat([]byte{0x9}, 32)
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("re reserve: %v", err)
	}
	if second.StorageKey != "key-new" {
		t.Errorf("storage_key = %q, want a fresh key", second.StorageKey)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 20)
	if err != nil {
		t.Fatalf("cleanup keys: %v", err)
	}
	found := false
	for _, k := range keys {
		if k == "key-old" {
			found = true
		}
	}
	if !found {
		t.Errorf("the superseded object was not queued for cleanup, got %v", keys)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup`)
	})
}

func TestReserveUploadRow_RefusesReplayOfConfirmedMedia(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	row := pendingRow(albumID, mediaID, token, "key-confirmed", "thumb-confirmed")
	if err := env.media.ReserveUploadRow(ctx, row, 0); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if _, err := env.media.MarkConfirmed(ctx, mediaID, albumID); err != nil {
		t.Fatalf("confirm: %v", err)
	}

	again := pendingRow(albumID, mediaID, token, "key-replay", "thumb-replay")
	err := env.media.ReserveUploadRow(ctx, again, 0)
	if !errors.Is(err, repository.ErrMediaConfirmed) {
		t.Fatalf("err = %v, want ErrMediaConfirmed", err)
	}
}

func TestReserveUploadRow_RefusesAnotherUploadersReservation(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	mine := pendingRow(albumID, mediaID, token, "key-mine", "thumb-mine")
	if err := env.media.ReserveUploadRow(ctx, mine, 0); err != nil {
		t.Fatalf("reserve: %v", err)
	}

	theirs := pendingRow(albumID, mediaID, []byte("someone-else-token"), "key-theirs", "thumb-theirs")
	err := env.media.ReserveUploadRow(ctx, theirs, 0)
	if !errors.Is(err, repository.ErrMediaNotOwned) {
		t.Fatalf("err = %v, want ErrMediaNotOwned", err)
	}

	row, getErr := env.media.GetByID(ctx, mediaID, albumID)
	if getErr != nil {
		t.Fatalf("get: %v", getErr)
	}
	if row.StorageKey != "key-mine" {
		t.Errorf("storage_key = %q, the original reservation must survive", row.StorageKey)
	}
}
