package service

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

// PresignTTL : the client uploads to S3 right after RequestUploadURL returns,
// so a short TTL is fine and reduces the window for URL replay
const PresignTTL = 15 * time.Minute

// EpochLookup is the slice of *epoch.Repo this service needs : keeps the dep
// surface small + lets tests stub without pulling pgx
type EpochLookup interface {
	CurrentEpoch(ctx context.Context, albumID uuid.UUID) (epoch int, exists bool, startedAt time.Time, err error)
}

// MediaStore is the slice of *repository.MediaRepository the service needs
type MediaStore interface {
	CreatePending(ctx context.Context, m *model.Media) error
	MarkConfirmed(ctx context.Context, mediaID, albumID uuid.UUID) error
	DeletePending(ctx context.Context, mediaID, albumID uuid.UUID) error
	GetByID(ctx context.Context, mediaID, albumID uuid.UUID) (*model.Media, error)
	ListConfirmed(ctx context.Context, albumID uuid.UUID) ([]model.Media, error)
	Delete(ctx context.Context, mediaID, albumID uuid.UUID) error
}

// ObjectStore is the slice of *storage.S3Client the service needs
type ObjectStore interface {
	GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*PresignedUpload, error)
	GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error)
	HeadObject(ctx context.Context, key string) (size int64, sha256B64 string, err error)
	DeleteObject(ctx context.Context, key string) error
}

// PresignedUpload mirrors storage.PresignedUpload : duplicated here so the
// service layer doesnt force handler tests to import internal/storage
type PresignedUpload struct {
	URL            string
	RequiredHeader map[string]string
}

type MediaService struct {
	repo   MediaStore
	epochs EpochLookup
	s3     ObjectStore
}

func NewMediaService(repo MediaStore, epochs EpochLookup, s3 ObjectStore) *MediaService {
	return &MediaService{repo: repo, epochs: epochs, s3: s3}
}

// Wrap byte budgets pinned by the §1.1 wrap format (VER=0x01) and §4.1 wrap
// envelope. Keep these in lockstep with the client constants
const (
	wrapNonceLen = 12 // AES-GCM 96 bit nonce
	wrapTagCTLen = 48 // AES-GCM tag (16) + ciphertext of 32 byte DEK
	sha256Len    = 32
)

// RequestUploadInput is the decoded body of POST /albums/{id}/media/upload-url
type RequestUploadInput struct {
	MediaID    uuid.UUID
	BlobSize   int64
	BlobSHA256 []byte // raw 32 bytes : client base64s it on the wire
	MimeType   string
	MediaType  string // 'photo' or 'video'
	WrapNonce  []byte
	WrapTagCT  []byte
	EpochTag   int
}

// RequestUploadResult is what the handler returns to the client
type RequestUploadResult struct {
	MediaID        uuid.UUID
	UploadURL      string
	RequiredHeader map[string]string
	StorageKey     string // returned for client side debug logs only
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
	if err := s.repo.CreatePending(ctx, row); err != nil {
		return nil, apierr.Internal("failed to write pending media").WithCause(err)
	}

	sha256B64 := base64.StdEncoding.EncodeToString(in.BlobSHA256)
	pre, err := s.s3.GetPresignedUploadURLWithChecksum(ctx, storageKey, contentType, in.BlobSize, sha256B64, PresignTTL)
	if err != nil {
		// Best effort cleanup : if this fails the GC sweep picks up the row
		_ = s.repo.DeletePending(ctx, mediaID, albumID)
		return nil, apierr.Internal("failed to presign upload").WithCause(err)
	}
	return &RequestUploadResult{
		MediaID:        mediaID,
		UploadURL:      pre.URL,
		RequiredHeader: pre.RequiredHeader,
		StorageKey:     storageKey,
	}, nil
}

// ConfirmUpload validates the S3 object against the claimed size + sha256
// On match : flips confirmed=TRUE. On mismatch : DELETEs the S3 object +
// pending row. The client gets a typed error so it can retry the whole flow
func (s *MediaService) ConfirmUpload(ctx context.Context, albumID, mediaID uuid.UUID) error {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return apierr.NotFound("media not found")
		}
		return apierr.Internal("failed to read media row").WithCause(err)
	}
	if row.Confirmed {
		// Idempotent : repeated confirms are a no op rather than 409
		return nil
	}

	gotSize, gotSHA256B64, err := s.s3.HeadObject(ctx, row.StorageKey)
	if err != nil {
		return apierr.Validation("upload not found on storage").WithCause(err)
	}
	if gotSize != row.BlobSize {
		_ = s.dropOrphan(ctx, row)
		return apierr.Validation("uploaded blob size mismatch ; pending row dropped")
	}
	wantSHA256B64 := base64.StdEncoding.EncodeToString(row.BlobSHA256)
	if gotSHA256B64 != "" && gotSHA256B64 != wantSHA256B64 {
		_ = s.dropOrphan(ctx, row)
		return apierr.Validation("uploaded blob sha256 mismatch ; pending row dropped")
	}

	if err := s.repo.MarkConfirmed(ctx, mediaID, albumID); err != nil {
		return apierr.Internal("failed to mark confirmed").WithCause(err)
	}
	return nil
}

// DownloadURLResult is the per request presigned GET URL. TTL is short on
// purpose : the client downloads immediately after this returns. URL is the
// only field today : future expansion (range support, byte budgets) goes here
type DownloadURLResult struct {
	URL       string
	ExpiresAt time.Time
}

// DownloadURLTTL : longer than upload TTL since the client may take a moment
// to actually issue the GET (image picker, UI animation, etc.)
const DownloadURLTTL = 15 * time.Minute

// RequestDownloadURL : returns a fresh presigned GET URL for a confirmed
// media row. Refuses pending rows (their S3 object may not exist yet) and
// missing rows (caller's RequireMember middleware already gates album scope)
func (s *MediaService) RequestDownloadURL(ctx context.Context, albumID, mediaID uuid.UUID) (*DownloadURLResult, error) {
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
	url, err := s.s3.GetPresignedDownloadURL(ctx, row.StorageKey, DownloadURLTTL)
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
func (s *MediaService) DeleteMedia(ctx context.Context, albumID, mediaID uuid.UUID) error {
	row, err := s.repo.GetByID(ctx, mediaID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return apierr.NotFound("media not found")
		}
		return apierr.Internal("failed to read media").WithCause(err)
	}
	if err := s.s3.DeleteObject(ctx, row.StorageKey); err != nil {
		return apierr.Internal("failed to delete s3 object").WithCause(err)
	}
	if err := s.repo.Delete(ctx, mediaID, albumID); err != nil {
		return apierr.Internal("failed to delete media row").WithCause(err)
	}
	return nil
}

func (s *MediaService) dropOrphan(ctx context.Context, row *model.Media) error {
	_ = s.s3.DeleteObject(ctx, row.StorageKey)
	return s.repo.DeletePending(ctx, row.ID, row.AlbumID)
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
	return nil
}
