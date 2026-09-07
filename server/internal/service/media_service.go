package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

// PresignTTL covers the largest transfer at the client's 64 KiB/s floor
const PresignTTL = 30 * time.Minute

// EpochLookup is the slice of *epoch.Repo this service needs : keeps the dep
// surface small + lets tests stub without pulling pgx
type EpochLookup interface {
	CurrentEpoch(ctx context.Context, albumID uuid.UUID) (epoch int, exists bool, startedAt time.Time, err error)
	// tells whether the album's live active member set differs
	// from the current epoch's recipient set : true during the window between a
	// revoke and the admin's rotation
	PendingRotation(ctx context.Context, albumID uuid.UUID) (bool, error)
}

// MediaStore is the slice of *repository.MediaRepository the service needs
type MediaStore interface {
	// it inserts the pending row under the albums row lock,
	// re checking (atomically with the insert) that epochTag is still current
	// and that no rotation is pending
	ReserveUploadRow(ctx context.Context, m *model.Media, epochTag int) error
	MarkConfirmed(ctx context.Context, mediaID, albumID, reservationID uuid.UUID) (int64, error)
	MediaGeneration(ctx context.Context, albumID uuid.UUID) (int64, error)
	QueuePendingCleanup(ctx context.Context, mediaID, albumID uuid.UUID, uploaderToken []byte, reservationID uuid.UUID) (repository.PendingCleanupBatch, error)
	QueueStalePendingCleanup(ctx context.Context, before time.Time, limit int) (repository.PendingCleanupBatch, error)
	ListObjectCleanupKeys(ctx context.Context, limit int) ([]string, error)
	DeleteObjectCleanupKey(ctx context.Context, key string) error
	RescheduleObjectCleanupKey(ctx context.Context, key string) (int, error)
	GetByID(ctx context.Context, mediaID, albumID uuid.UUID) (*model.Media, error)
	ListConfirmed(ctx context.Context, albumID uuid.UUID) ([]model.Media, error)
	Delete(ctx context.Context, mediaID, albumID uuid.UUID) error
	ListAlbumObjectKeys(ctx context.Context, albumID uuid.UUID) ([]repository.MediaObjectKeys, error)
}

// ObjectStore is the slice of *storage.S3Client the service needs
type ObjectStore interface {
	GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*PresignedUpload, error)
	GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error)
	HeadObject(ctx context.Context, key string) (size int64, sha256B64 string, err error)
	DeleteObject(ctx context.Context, key string) error
}

// Notifier matches *ws.Hub.EmitToUsers : ConfirmUpload fanout uses it so the
// e2ee.media_added event reaches every active album member within ~1s of the
// row going confirmed. Mirrors the pattern in internal/e2ee/invite/handler.go
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// MemberLookup matches *invite.Repo.ActiveMemberUserIDs : the existing repo
// satisfies it implicitly
type MemberLookup interface {
	ActiveMemberUserIDs(ctx context.Context, albumID uuid.UUID) ([]uuid.UUID, error)
}

// PresignedUpload mirrors storage.PresignedUpload : duplicated here so the
// service layer doesnt force handler tests to import internal/storage
type PresignedUpload struct {
	URL            string
	RequiredHeader map[string]string
}

type MediaService struct {
	repo     MediaStore
	epochs   EpochLookup
	s3       ObjectStore
	notifier Notifier
	lookup   MemberLookup
}

// NewMediaService : notifier + lookup are nil-safe so tests that don't
// exercise the fanout can keep the old 3-arg shape via wrapper. The
// production wiring in cmd/server/main.go always passes both
func NewMediaService(repo MediaStore, epochs EpochLookup, s3 ObjectStore, notifier Notifier, lookup MemberLookup) *MediaService {
	return &MediaService{repo: repo, epochs: epochs, s3: s3, notifier: notifier, lookup: lookup}
}

// Wrap byte budgets pinned by the §1.1 wrap format (VER=0x01) and §4.1 wrap
// envelope. Keep these in lockstep with the client constants
const (
	wrapNonceLen = 12 // AES-GCM 96 bit nonce
	wrapTagCTLen = 48 // AES-GCM tag (16) + ciphertext of 32 byte DEK
	sha256Len    = 32
	// plan targets ~20 KB thumbs. Hard ceiling at 500 KB rejects a
	// client that tries to abuse the thumb channel as a sneaky second blob
	maxThumbSize = 500 * 1024
)

// RequestUploadInput is the decoded body of POST /albums/{id}/media/upload-ur.
// thumb fields are optional : present-as-a-group for photos that include
// a thumb, absent-as-a-group for videos or any non thumbnailable media
type RequestUploadInput struct {
	MediaID        uuid.UUID
	BlobSize       int64
	BlobSHA256     []byte // raw 32 bytes : client base64s it on the wire
	MimeType       string
	MediaType      string // 'photo' or 'video'
	WrapNonce      []byte
	WrapTagCT      []byte
	EpochTag       int
	ThumbSize      int64  // 0 if no thumb
	ThumbSHA256    []byte // empty if no thumb
	ThumbWrapNonce []byte // empty if no thumb
	ThumbWrapTagCT []byte // empty if no thumb
}

// RequestUploadResult is what the handler returns to the client. Thumb fields
// are populated only when the request included thumb_* fields
type RequestUploadResult struct {
	MediaID             uuid.UUID
	UploadURL           string
	RequiredHeader      map[string]string
	StorageKey          string // returned for client side debug logs only
	ThumbUploadURL      string
	ThumbRequiredHeader map[string]string
}

// RequestUploadURL : creates a pending row + presigned PUT URL. The client
// then uploads to S3 and calls ConfirmUpload to flip the row confirmed=TRUE
func (s *MediaService) RequestUploadURL(ctx context.Context, albumID uuid.UUID, uploaderToken []byte, in RequestUploadInput) (*RequestUploadResult, error) {
	if err := validateUploadInput(in); err != nil {
		return nil, err
	}

	// Epoch gate (§5.1) : reject uploads against a stale epoch. Stops a
	// removed admin from sneaking a wrap under MK_old in past the rotation
	cur, exists, _, err := s.epochs.CurrentEpoch(ctx, albumID)
	if err != nil {
		return nil, apierr.Internal("failed to read current epoch").WithCause(err)
	}
	if !exists {
		return nil, apierr.Validation("album has no epoch yet ; cannot upload media")
	}
	if in.EpochTag != cur {
		return nil, apierr.EpochReplay("epoch_tag does not match current epoch")
	}

	// the stale epoch gate above passes during the
	// window between a member revoke and the admin's rotation, bcs
	// MK_current is unchanged. But a photo sealed under it during that window is
	// readable by the just removed member (they still hold MK_current), which
	// breaks "future, not past" under the DB-at-rest model. Freeze new
	// uploads until the active set and the current epoch's recipients match
	// again : the admin's rotation (or the client's pending rotation recovery)
	// lifts it. Existing reads are unaffected
	pending, err := s.epochs.PendingRotation(ctx, albumID)
	if err != nil {
		return nil, apierr.Internal("failed to check rotation state").WithCause(err)
	}
	if pending {
		return nil, apierr.EpochPendingRotation("album has a pending epoch rotation ; uploads are frozen until it completes")
	}

	// M9 : storage_key is server generated random opaque. NEVER carry album_id
	// or media_id in the path : the S3 host can group objects by key string
	// even tho the body is ciphertext
	storageKey, err := newStorageKey()
	if err != nil {
		return nil, apierr.Internal("failed to mint storage key").WithCause(err)
	}

	mediaID := in.MediaID
	if mediaID == uuid.Nil {
		mediaID = uuid.New()
	}

	contentType := in.MimeType
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	mimePtr := contentType
	row := &model.Media{
		ID:            mediaID,
		AlbumID:       albumID,
		UploaderToken: uploaderToken,
		StorageKey:    storageKey,
		WrapNonce:     in.WrapNonce,
		WrapTagCT:     in.WrapTagCT,
		EpochTag:      in.EpochTag,
		BlobSize:      in.BlobSize,
		BlobSHA256:    in.BlobSHA256,
		MediaType:     in.MediaType,
		MimeType:      &mimePtr,
	}

	//thumb fields present-as-a-group → mint second storage_key + presign
	// a second PUT. ConfirmUpload validates BOTH objects exist + checksum
	hasThumb := len(in.ThumbWrapNonce) > 0
	var thumbKey string
	if hasThumb {
		thumbKey, err = newStorageKey()
		if err != nil {
			return nil, apierr.Internal("failed to mint thumb storage key").WithCause(err)
		}
		row.ThumbKey = &thumbKey
		row.ThumbWrapNonce = in.ThumbWrapNonce
		row.ThumbWrapTagCT = in.ThumbWrapTagCT
		row.ThumbSize = &in.ThumbSize
		row.ThumbSHA256 = in.ThumbSHA256
	}

	// Authoritative check + insert, atomic under the albums row lock. A revoke
	// or rotation that commits between the pre checks above and here is caught
	// now : the row is only written while the album is genuinely uploadable
	if err := s.repo.ReserveUploadRow(ctx, row, in.EpochTag); err != nil {
		switch {
		case errors.Is(err, repository.ErrNoEpoch):
			return nil, apierr.Validation("album has no epoch yet ; cannot upload media")
		case errors.Is(err, repository.ErrEpochMismatch):
			return nil, apierr.EpochReplay("epoch_tag does not match current epoch")
		case errors.Is(err, repository.ErrPendingRotation):
			return nil, apierr.EpochPendingRotation("album has a pending epoch rotation ; uploads are frozen until it completes")
		case errors.Is(err, repository.ErrAlbumNotFound):
			return nil, apierr.NotFound("album not found")
		case errors.Is(err, repository.ErrMediaConfirmed):
			return nil, apierr.Validation("media_id is already confirmed")
		case errors.Is(err, repository.ErrMediaNotOwned):
			return nil, apierr.Forbidden("media_id is reserved by another uploader")
		default:
			return nil, apierr.Internal("failed to write pending media").WithCause(err)
		}
	}

	// Presign the keys selected by ReserveUploadRow
	storageKey = row.StorageKey
	sha256B64 := base64.StdEncoding.EncodeToString(in.BlobSHA256)
	pre, err := s.s3.GetPresignedUploadURLWithChecksum(ctx, storageKey, contentType, in.BlobSize, sha256B64, PresignTTL)
	if err != nil {
		_ = s.retirePending(ctx, row)
		return nil, apierr.Internal("failed to presign upload").WithCause(err)
	}
	res := &RequestUploadResult{
		MediaID:        mediaID,
		UploadURL:      pre.URL,
		RequiredHeader: pre.RequiredHeader,
		StorageKey:     storageKey,
	}
	if hasThumb {
		if row.ThumbKey != nil {
			thumbKey = *row.ThumbKey
		}
		thumbSHA256B64 := base64.StdEncoding.EncodeToString(in.ThumbSHA256)
		// Thumb is always image/webp client choice. Hardcoded here
		// instead of taking from the request so a bad client cant claim a
		// thumb is application/octet-stream or worse
		thumbPre, err := s.s3.GetPresignedUploadURLWithChecksum(ctx, thumbKey, "image/webp", in.ThumbSize, thumbSHA256B64, PresignTTL)
		if err != nil {
			_ = s.retirePending(ctx, row)
			return nil, apierr.Internal("failed to presign thumb upload").WithCause(err)
		}
		res.ThumbUploadURL = thumbPre.URL
		res.ThumbRequiredHeader = thumbPre.RequiredHeader
	}
	return res, nil
}

// ConfirmUpload validates the S3 object against the claimed size + sha256
// On match : flips confirmed=TRUE. On mismatch : DELETEs the S3 object +
// pending row. The client gets a typed error so it can retry the whole flow
func (s *MediaService) ConfirmUpload(ctx context.Context, albumID, mediaID, uploaderUserID uuid.UUID, uploaderToken []byte) (int64, error) {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return 0, apierr.NotFound("media not found")
		}
		return 0, apierr.Internal("failed to read media row").WithCause(err)
	}
	// Album membership does not prove reservation ownership
	if !bytes.Equal(row.UploaderToken, uploaderToken) {
		return 0, apierr.Forbidden("media was reserved by another uploader")
	}
	if row.Confirmed {
		// Return this row's generation so retries cannot mark newer media as seen
		if row.AlbumSeq != nil {
			return *row.AlbumSeq, nil
		}
		g, gerr := s.repo.MediaGeneration(ctx, albumID)
		if gerr != nil {
			return 0, apierr.Internal("failed to read generation").WithCause(gerr)
		}
		return g, nil
	}

	gotSize, gotSHA256B64, err := s.s3.HeadObject(ctx, row.StorageKey)
	if err != nil {
		return 0, apierr.Validation("upload not found on storage").WithCause(err)
	}
	if gotSize != row.BlobSize {
		_ = s.dropOrphan(ctx, row)
		return 0, apierr.Validation("uploaded blob size mismatch ; pending row dropped")
	}
	wantSHA256B64 := base64.StdEncoding.EncodeToString(row.BlobSHA256)
	if gotSHA256B64 != "" && gotSHA256B64 != wantSHA256B64 {
		_ = s.dropOrphan(ctx, row)
		return 0, apierr.Validation("uploaded blob sha256 mismatch ; pending row dropped")
	}

	// if the row has a thumb, the matching S3 object MUST exist + match
	// before confirm. A row gets at most one shot at thumb upload : if it
	// fails here the row is dropped (orphan) and client retries the whole flow
	if row.ThumbKey != nil {
		thGot, thGotSHA256B64, err := s.s3.HeadObject(ctx, *row.ThumbKey)
		if err != nil {
			_ = s.dropOrphan(ctx, row)
			return 0, apierr.Validation("thumb upload not found on storage ; pending row dropped").WithCause(err)
		}
		if row.ThumbSize == nil || thGot != *row.ThumbSize {
			_ = s.dropOrphan(ctx, row)
			return 0, apierr.Validation("uploaded thumb size mismatch ; pending row dropped")
		}
		wantThumbSHA256B64 := base64.StdEncoding.EncodeToString(row.ThumbSHA256)
		if thGotSHA256B64 != "" && thGotSHA256B64 != wantThumbSHA256B64 {
			_ = s.dropOrphan(ctx, row)
			return 0, apierr.Validation("uploaded thumb sha256 mismatch ; pending row dropped")
		}
	}

	// Commit only the reservation whose objects were checked
	generation, err := s.repo.MarkConfirmed(ctx, mediaID, albumID, row.ReservationID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			// Only an already confirmed row makes a repeated confirm successful
			if again, rerr := s.repo.GetByID(ctx, mediaID, albumID); rerr == nil {
				if again.Confirmed && again.AlbumSeq != nil {
					return *again.AlbumSeq, nil
				}
				if again.Confirmed {
					if g, gerr := s.repo.MediaGeneration(ctx, albumID); gerr == nil {
						return g, nil
					}
				}
				return 0, apierr.Conflict("media reservation is no longer current ; re-upload")
			}
			return 0, apierr.NotFound("media upload was aborted")
		}
		return 0, apierr.Internal("failed to mark confirmed").WithCause(err)
	}

	// Fanout e2ee.media_added to every active member EXCEPT the uploader
	// The uploader's UI updates from the local upload success path : sending
	// them the event back would only re trigger _loadMedia and a wasted
	// prefetch for ciphertext they already have in memory
	// Payload embeds the full record (same shape as ListMedia) so recipients
	// can warm L2 without a separate listMedia roundtrip
	if s.notifier != nil && s.lookup != nil {
		go func() {
			bg := context.Background()
			members, err := s.lookup.ActiveMemberUserIDs(bg, albumID)
			if err != nil {
				slog.Warn("media_added: lookup failed", "err", err, "album_id", albumID)
				return
			}
			ids := make([]uuid.UUID, 0, len(members))
			for _, m := range members {
				if m == uploaderUserID {
					continue
				}
				ids = append(ids, m)
			}
			if len(ids) == 0 {
				return
			}
			rec := map[string]any{
				"id":             mediaID,
				"album_id":       albumID,
				"uploader_token": base64.StdEncoding.EncodeToString(row.UploaderToken),
				"wrap_nonce":     base64.StdEncoding.EncodeToString(row.WrapNonce),
				"wrap_tag_ct":    base64.StdEncoding.EncodeToString(row.WrapTagCT),
				"epoch_tag":      row.EpochTag,
				"blob_size":      row.BlobSize,
				"blob_sha256":    base64.StdEncoding.EncodeToString(row.BlobSHA256),
				"media_type":     row.MediaType,
				"mime_type":      row.MimeType,
				"created_at":     row.CreatedAt,
			}
			if row.ThumbSize != nil {
				rec["thumb_wrap_nonce"] = base64.StdEncoding.EncodeToString(row.ThumbWrapNonce)
				rec["thumb_wrap_tag_ct"] = base64.StdEncoding.EncodeToString(row.ThumbWrapTagCT)
				rec["thumb_size"] = *row.ThumbSize
				rec["thumb_sha256"] = base64.StdEncoding.EncodeToString(row.ThumbSHA256)
			}
			if err := s.notifier.EmitToUsers(bg, ids, ws.EventMediaAdded, map[string]any{
				"album_id":         albumID.String(),
				"media_id":         mediaID.String(),
				"record":           rec,
				"media_generation": generation,
			}); err != nil {
				slog.Warn("media_added: emit failed", "err", err, "album_id", albumID)
			}
		}()
	} else {
		slog.Warn("media_added: notifier or lookup is nil, fanout skipped", "album_id", albumID)
	}
	return generation, nil
}

// DownloadURLResult is the per request presigned GET URL. TTL is short on
// purpose : the client downloads immediately after this returns. URL is the
// only field today : future expansion (range support, byte budgets) goes here
type DownloadURLResult struct {
	URL       string
	ExpiresAt time.Time
}

// DownloadURLTTL matches the longest client transfer budget
const DownloadURLTTL = 30 * time.Minute

// RequestDownloadURL : returns a fresh presigned GET URL for a confirmed
// media row. Refuses pending rows (their S3 object may not exist yet) and
// missing rows (caller's RequireMember middleware already gates album scope)
// asset == "thumb" presigns row.ThumbKey instead of row.StorageKey : 404s if
// the row has no thumb
func (s *MediaService) RequestDownloadURL(ctx context.Context, albumID, mediaID uuid.UUID, asset string) (*DownloadURLResult, error) {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return nil, apierr.NotFound("media not found")
		}
		return nil, apierr.Internal("failed to read media row").WithCause(err)
	}
	if !row.Confirmed {
		return nil, apierr.NotFound("media not yet confirmed")
	}
	key := row.StorageKey
	if asset == "thumb" {
		if row.ThumbKey == nil {
			return nil, apierr.NotFound("media has no thumb")
		}
		key = *row.ThumbKey
	}
	url, err := s.s3.GetPresignedDownloadURL(ctx, key, DownloadURLTTL)
	if err != nil {
		return nil, apierr.Internal("failed to presign download").WithCause(err)
	}
	return &DownloadURLResult{
		URL:       url,
		ExpiresAt: time.Now().Add(DownloadURLTTL),
	}, nil
}

func (s *MediaService) ListMedia(ctx context.Context, albumID uuid.UUID) ([]model.Media, error) {
	out, err := s.repo.ListConfirmed(ctx, albumID)
	if err != nil {
		return nil, apierr.Internal("failed to list media").WithCause(err)
	}
	return out, nil
}

// DeleteMedia drops the S3 object then the row. On S3 failure the row stays
// (caller can retry) : on row delete failure the S3 object is gone but the
// row is tombstone since the storage_key now 404s. Acceptable trade off if you ask me
func (s *MediaService) DeleteMedia(ctx context.Context, albumID, mediaID uuid.UUID, callerToken []byte) error {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return apierr.NotFound("media not found")
		}
		return apierr.Internal("failed to read media").WithCause(err)
	}
	// Album membership does not grant media ownership
	if !bytes.Equal(row.UploaderToken, callerToken) {
		return apierr.Forbidden("only the uploader can delete this media")
	}
	if err := s.s3.DeleteObject(ctx, row.StorageKey); err != nil {
		return apierr.Internal("failed to delete s3 object").WithCause(err)
	}
	// Drop the thumbnail object too, else it orphans in storage. Hard delete:
	// if it can't be removed, keep the row so the whole delete can be retried
	if row.ThumbKey != nil && *row.ThumbKey != "" {
		if err := s.s3.DeleteObject(ctx, *row.ThumbKey); err != nil {
			return apierr.Internal("failed to delete s3 thumb object").WithCause(err)
		}
	}
	if err := s.repo.Delete(ctx, mediaID, albumID); err != nil {
		return apierr.Internal("failed to delete media row").WithCause(err)
	}
	return nil
}

// Prevents replacement between lookup and cleanup
func (s *MediaService) AbortPendingUpload(ctx context.Context, albumID, mediaID uuid.UUID, uploaderToken []byte) error {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return nil
		}
		return apierr.Internal("failed to read pending media").WithCause(err)
	}
	batch, err := s.repo.QueuePendingCleanup(ctx, mediaID, albumID, uploaderToken, row.ReservationID)
	if err != nil {
		return apierr.Internal("failed to abort pending upload").WithCause(err)
	}
	s.cleanupObjectKeys(ctx, batch.Keys)
	return nil
}

// MaxBlobBytes is mirrored by the client when deriving transfer deadlines
const MaxBlobBytes int64 = 64 * 1024 * 1024

const (
	// Two hours avoids early cleanup of hour-quantized timestamps
	PendingUploadStaleAfter = 2 * time.Hour
	PendingCleanupInterval  = 10 * time.Minute
	PendingCleanupBatchSize = 100
	// Attempts after which a key is treated as stuck
	ObjectCleanupAlertAttempts = 10
)

type PendingCleanupStats struct {
	RetiredMedia  int
	DeletedObject int
	FailedObject  int
	StuckObject   int
}

// SweepStalePendingUploads queues stale rows before deleting their objects
func (s *MediaService) SweepStalePendingUploads(ctx context.Context, before time.Time, batchSize int) (PendingCleanupStats, error) {
	batch, err := s.repo.QueueStalePendingCleanup(ctx, before, batchSize)
	if err != nil {
		return PendingCleanupStats{}, err
	}
	keys, err := s.repo.ListObjectCleanupKeys(ctx, batchSize*2)
	if err != nil {
		return PendingCleanupStats{RetiredMedia: batch.MediaCount}, err
	}
	deleted, failed, stuck := s.cleanupObjectKeys(ctx, keys)
	return PendingCleanupStats{
		RetiredMedia:  batch.MediaCount,
		DeletedObject: deleted,
		FailedObject:  failed,
		StuckObject:   stuck,
	}, nil
}

func (s *MediaService) RunPendingUploadCleanup(ctx context.Context) {
	run := func() {
		stats, err := s.SweepStalePendingUploads(
			ctx,
			time.Now().Add(-PendingUploadStaleAfter),
			PendingCleanupBatchSize,
		)
		if err != nil {
			slog.ErrorContext(ctx, "pending media cleanup failed", "err", err)
			return
		}
		if stats.RetiredMedia > 0 || stats.DeletedObject > 0 || stats.FailedObject > 0 {
			slog.InfoContext(ctx, "pending media cleanup",
				"retired_media", stats.RetiredMedia,
				"deleted_objects", stats.DeletedObject,
				"failed_objects", stats.FailedObject,
				"stuck_objects", stats.StuckObject)
		}
	}

	run()
	ticker := time.NewTicker(PendingCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			run()
		}
	}
}

// deletes every media object (blob + thumbnail) for an album
// from object storage. Called before the album row is dropped, since the media
// rows cascade away with it and the S3 objects would otherwise orphan (S3 is
// not part of the DB cascade)

// Hard delete semantics: it attempts every object (so a single failure doesn't
// strand the rest), but if ANY delete failed it returns an error so DeleteAlbum
// keeps the DB row : that row is the only handle left to retry the cleanup
// S3 DeleteObject is idempotent, so already gone objects don't count as
// failures and a retry converges
func (s *MediaService) PurgeAlbumObjects(ctx context.Context, albumID uuid.UUID) error {
	keys, err := s.repo.ListAlbumObjectKeys(ctx, albumID)
	if err != nil {
		return err
	}
	var failed int
	for _, k := range keys {
		if err := s.s3.DeleteObject(ctx, k.StorageKey); err != nil {
			slog.Warn("purge: failed to delete blob", "album_id", albumID, "err", err)
			failed++
		}
		if k.ThumbKey != nil && *k.ThumbKey != "" {
			if err := s.s3.DeleteObject(ctx, *k.ThumbKey); err != nil {
				slog.Warn("purge: failed to delete thumb", "album_id", albumID, "err", err)
				failed++
			}
		}
	}
	if failed > 0 {
		return fmt.Errorf("purge: %d object(s) failed to delete for album %s", failed, albumID)
	}
	return nil
}

func (s *MediaService) dropOrphan(ctx context.Context, row *model.Media) error {
	return s.retirePending(ctx, row)
}

func (s *MediaService) retirePending(ctx context.Context, row *model.Media) error {
	batch, err := s.repo.QueuePendingCleanup(ctx, row.ID, row.AlbumID, row.UploaderToken, row.ReservationID)
	if err != nil {
		return err
	}
	s.cleanupObjectKeys(ctx, batch.Keys)
	return nil
}

func (s *MediaService) cleanupObjectKeys(ctx context.Context, keys []string) (deleted, failed, stuck int) {
	for _, key := range keys {
		if err := s.s3.DeleteObject(ctx, key); err != nil {
			failed++
			slog.WarnContext(ctx, "pending media object delete failed", "err", err)
			// Back off failed keys so fresh work can proceed
			attempts, rerr := s.repo.RescheduleObjectCleanupKey(ctx, key)
			if rerr != nil {
				slog.WarnContext(ctx, "pending media cleanup reschedule failed", "err", rerr)
			}
			// Keep retrying to avoid leaving encrypted user objects behind
			if attempts >= ObjectCleanupAlertAttempts {
				stuck++
				slog.ErrorContext(ctx, "pending media object will not delete",
					"attempts", attempts, "err", err)
			}
			continue
		}
		if err := s.repo.DeleteObjectCleanupKey(ctx, key); err != nil {
			// Keep the key queued; repeating object deletion is safe
			failed++
			slog.WarnContext(ctx, "pending media cleanup acknowledgement failed", "err", err)
			continue
		}
		deleted++
	}
	return deleted, failed, stuck
}

func newStorageKey() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func validateUploadInput(in RequestUploadInput) error {
	switch in.MediaType {
	case "photo", "video":
	default:
		return apierr.Validation("media_type must be 'photo' or 'video'")
	}
	if in.BlobSize <= 0 {
		return apierr.Validation("blob_size must be > 0")
	}
	// Keep this limit aligned with kMaxMediaBytes in the client
	if in.BlobSize > MaxBlobBytes {
		return apierr.Validation("blob_size exceeds the maximum media size")
	}
	if in.ThumbSize > MaxBlobBytes {
		return apierr.Validation("thumb_size exceeds the maximum media size")
	}
	if len(in.BlobSHA256) != sha256Len {
		return apierr.Validation("blob_sha256 must be 32 bytes")
	}
	if len(in.WrapNonce) != wrapNonceLen {
		return apierr.Validation("wrap_nonce must be 12 bytes")
	}
	if len(in.WrapTagCT) != wrapTagCTLen {
		return apierr.Validation("wrap_tag_ct must be 48 bytes (tag + ciphertext of 32 byte DEK)")
	}
	if in.EpochTag < 0 {
		return apierr.Validation("epoch_tag must be >= 0")
	}
	if in.MimeType != "" && !strings.HasPrefix(in.MimeType, "image/") && !strings.HasPrefix(in.MimeType, "video/") {
		return apierr.Validation("mime_type must be image/* or video/*")
	}
	//all-or-nothing. A client that sends one thumb field must
	// send all four so the row never ends up partially set
	hasAnyThumb := len(in.ThumbWrapNonce) > 0 || len(in.ThumbWrapTagCT) > 0 ||
		in.ThumbSize > 0 || len(in.ThumbSHA256) > 0
	if hasAnyThumb {
		if len(in.ThumbWrapNonce) != wrapNonceLen {
			return apierr.Validation("thumb_wrap_nonce must be 12 bytes")
		}
		if len(in.ThumbWrapTagCT) != wrapTagCTLen {
			return apierr.Validation("thumb_wrap_tag_ct must be 48 bytes")
		}
		if len(in.ThumbSHA256) != sha256Len {
			return apierr.Validation("thumb_sha256 must be 32 bytes")
		}
		if in.ThumbSize <= 0 {
			return apierr.Validation("thumb_size must be > 0")
		}
		if in.ThumbSize > maxThumbSize {
			return apierr.Validation("thumb_size exceeds 500KB cap")
		}
	}
	return nil
}
