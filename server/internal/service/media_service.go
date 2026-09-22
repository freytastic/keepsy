package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
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

type EpochLookup interface {
	CurrentEpoch(ctx context.Context, albumID uuid.UUID) (epoch int, exists bool, startedAt time.Time, err error)
	// true between a revoke and the next committed epoch
	RotationRequired(ctx context.Context, albumID uuid.UUID) (bool, error)
}

type MediaStore interface {
	// Rechecks epoch and rotation debt under the album lock
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
	DeleteOwnedMedia(ctx context.Context, albumID, mediaID uuid.UUID, uploaderToken []byte) (repository.MediaRemoval, error)
}

type ObjectStore interface {
	GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*PresignedUpload, error)
	GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error)
	HeadObject(ctx context.Context, key string) (size int64, sha256B64 string, err error)
	DeleteObject(ctx context.Context, key string) error
}

// Delivers confirmed media to active album members
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

type MemberLookup interface {
	ActiveMemberUserIDs(ctx context.Context, albumID uuid.UUID) ([]uuid.UUID, error)
}

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

// Thumbnail fields must be present or absent as one group
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

type RequestUploadResult struct {
	MediaID             uuid.UUID
	UploadURL           string
	RequiredHeader      map[string]string
	StorageKey          string // returned for client side debug logs only
	ThumbUploadURL      string
	ThumbRequiredHeader map[string]string
}

// Creates a pending row before returning its presigned upload URLs
func (s *MediaService) RequestUploadURL(ctx context.Context, albumID uuid.UUID, uploaderToken []byte, in RequestUploadInput) (*RequestUploadResult, error) {
	if err := validateUploadInput(in); err != nil {
		return nil, err
	}

	// Reject stale epochs before issuing storage URLs
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

	// Freeze publication while a removed member still holds the current MK
	pending, err := s.epochs.RotationRequired(ctx, albumID)
	if err != nil {
		return nil, apierr.Internal("failed to check rotation state").WithCause(err)
	}
	if pending {
		return nil, apierr.EpochPendingRotation("album has a pending epoch rotation ; uploads are frozen until it completes")
	}

	// Opaque keys prevent the storage host grouping objects by album or media id
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

	// Thumbnail fields produce a second object that confirmation also verifies
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

	// Repeat the gate under the shared lock before writing the reservation
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
		// Do not let clients choose a misleading thumbnail content type
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

// Confirms only storage objects matching their claimed size and hash
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

	// A thumbnail mismatch drops the reservation so the client retries both objects
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
		// Typed so the client rewraps the sealed photo under the new key
		switch {
		case errors.Is(err, repository.ErrPendingRotation):
			return 0, apierr.EpochPendingRotation("album has a pending epoch rotation ; the upload must be rewrapped")
		case errors.Is(err, repository.ErrEpochMismatch):
			return 0, apierr.EpochReplay("epoch_tag does not match current epoch ; the upload must be rewrapped")
		}
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

	// Exclude the uploader because its local success path already seeds the cache
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
				"album_seq":      generation,
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

type DownloadURLResult struct {
	URL       string
	ExpiresAt time.Time
}

// DownloadURLTTL matches the longest client transfer budget
const DownloadURLTTL = 30 * time.Minute

// Returns a fresh download URL only for a confirmed object
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

// DeleteMedia removes the row and queues its objects in one transaction, then
// deletes the objects best effort. A failed delete stays queued for the sweep
func (s *MediaService) DeleteMedia(ctx context.Context, albumID, mediaID uuid.UUID, callerToken []byte) error {
	removed, err := s.repo.DeleteOwnedMedia(ctx, albumID, mediaID, callerToken)
	switch {
	case errors.Is(err, repository.ErrMediaNotFound), errors.Is(err, repository.ErrAlbumNotFound):
		return apierr.NotFound("media not found")
	case errors.Is(err, repository.ErrMediaNotOwned):
		return apierr.Forbidden("only the uploader can delete this media")
	case err != nil:
		return apierr.Internal("failed to delete media").WithCause(err)
	}
	s.CleanupObjectKeys(ctx, removed.Keys)
	s.EmitMediaDeleted(albumID, removed.MediaIDs)
	return nil
}

// Offline members converge on their next authoritative listing
func (s *MediaService) EmitMediaDeleted(albumID uuid.UUID, mediaIDs []uuid.UUID) {
	if len(mediaIDs) == 0 || s.notifier == nil || s.lookup == nil {
		return
	}
	go func() {
		bg := context.Background()
		members, err := s.lookup.ActiveMemberUserIDs(bg, albumID)
		if err != nil {
			slog.Warn("media_deleted: lookup failed", "err", err, "album_id", albumID)
			return
		}
		ids := make([]string, len(mediaIDs))
		for i, id := range mediaIDs {
			ids[i] = id.String()
		}
		if err := s.notifier.EmitToUsers(bg, members, ws.EventMediaDeleted, map[string]any{
			"album_id":  albumID.String(),
			"media_ids": ids,
		}); err != nil {
			slog.Warn("media_deleted: emit failed", "err", err, "album_id", albumID)
		}
	}()
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

// CleanupObjectKeys deletes already queued objects now instead of waiting for
// the periodic sweep
func (s *MediaService) CleanupObjectKeys(ctx context.Context, keys []string) {
	s.cleanupObjectKeys(ctx, keys)
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
	// One thumbnail field requires all four to avoid partial rows
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
