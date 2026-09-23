package service

import (
	"context"
	"encoding/base64"
	"errors"
	"log/slog"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

// Clients pad every avatar to one fixed size, this is only the ceiling
const MaxAvatarBytes int64 = 256 * 1024

// u32_be(epoch) || VER || NONCE || TAG || sealed 32 byte DEK
const avatarKeyCTLen = 4 + 1 + wrapNonceLen + wrapTagCTLen

type AvatarStore interface {
	Reserve(ctx context.Context, a *model.MemberAvatar) error
	Get(ctx context.Context, albumID, avatarID uuid.UUID) (*model.MemberAvatar, error)
	Confirm(ctx context.Context, albumID uuid.UUID, memberToken []byte, avatarID uuid.UUID) ([]string, error)
	DropPending(ctx context.Context, albumID uuid.UUID, memberToken []byte, avatarID uuid.UUID) ([]string, error)
	Remove(ctx context.Context, albumID uuid.UUID, memberToken []byte) ([]string, error)
	QueueStalePending(ctx context.Context, before time.Time, limit int) ([]string, error)
}

type AvatarService struct {
	repo     AvatarStore
	s3       ObjectStore
	cleaner  ObjectCleaner
	notifier Notifier
	lookup   MemberLookup
}

func NewAvatarService(repo AvatarStore, s3 ObjectStore, cleaner ObjectCleaner, notifier Notifier, lookup MemberLookup) *AvatarService {
	return &AvatarService{repo: repo, s3: s3, cleaner: cleaner, notifier: notifier, lookup: lookup}
}

type AvatarUploadInput struct {
	AvatarID   uuid.UUID
	BlobSize   int64
	BlobSHA256 []byte
	KeyCT      []byte
}

func (s *AvatarService) RequestUploadURL(ctx context.Context, albumID uuid.UUID, memberToken []byte, in AvatarUploadInput) (*PresignedUpload, error) {
	if in.AvatarID == uuid.Nil {
		return nil, apierr.Validation("avatar_id is required")
	}
	if in.BlobSize <= 0 || in.BlobSize > MaxAvatarBytes {
		return nil, apierr.Validation("blob_size is out of range for an avatar")
	}
	if len(in.BlobSHA256) != sha256Len {
		return nil, apierr.Validation("blob_sha256 must be 32 bytes")
	}
	if len(in.KeyCT) != avatarKeyCTLen {
		return nil, apierr.Validation("key_ct has the wrong length")
	}
	key, err := newStorageKey()
	if err != nil {
		return nil, apierr.Internal("failed to mint storage key").WithCause(err)
	}
	row := &model.MemberAvatar{
		AvatarID:    in.AvatarID,
		AlbumID:     albumID,
		MemberToken: memberToken,
		StorageKey:  key,
		BlobSize:    in.BlobSize,
		BlobSHA256:  in.BlobSHA256,
		KeyCT:       in.KeyCT,
	}
	if err := s.repo.Reserve(ctx, row); err != nil {
		switch {
		case errors.Is(err, repository.ErrCallerRevoked), errors.Is(err, repository.ErrAlbumNotFound):
			return nil, apierr.MemberRevoked("your access to this album has been revoked")
		case errors.Is(err, repository.ErrAvatarNotOwned):
			return nil, apierr.Forbidden("avatar_id is used by another upload")
		case errors.Is(err, repository.ErrAvatarConfirmed):
			return nil, apierr.Conflict("avatar is already confirmed")
		}
		return nil, apierr.Internal("failed to reserve avatar").WithCause(err)
	}
	sha := base64.StdEncoding.EncodeToString(in.BlobSHA256)
	pre, err := s.s3.GetPresignedUploadURLWithChecksum(ctx, row.StorageKey,
		"application/octet-stream", in.BlobSize, sha, PresignTTL)
	if err != nil {
		return nil, apierr.Internal("failed to presign avatar upload").WithCause(err)
	}
	return pre, nil
}

// Confirm checks the uploaded object before it replaces the current avatar
func (s *AvatarService) Confirm(ctx context.Context, albumID uuid.UUID, callerUserID uuid.UUID, memberToken []byte, avatarID uuid.UUID) error {
	row, err := s.repo.Get(ctx, albumID, avatarID)
	if err != nil {
		if errors.Is(err, repository.ErrAvatarNotFound) {
			return apierr.NotFound("avatar upload not found")
		}
		return apierr.Internal("failed to read avatar").WithCause(err)
	}
	if string(row.MemberToken) != string(memberToken) {
		return apierr.Forbidden("avatar was reserved by another member")
	}
	if !row.Confirmed {
		size, sha, err := s.s3.HeadObject(ctx, row.StorageKey)
		if err != nil {
			return apierr.Validation("avatar upload not found on storage").WithCause(err)
		}
		want := base64.StdEncoding.EncodeToString(row.BlobSHA256)
		if size != row.BlobSize || (sha != "" && sha != want) {
			s.drop(ctx, albumID, memberToken, avatarID)
			return apierr.Validation("uploaded avatar does not match its reservation ; pending row dropped")
		}
	}
	replaced, err := s.repo.Confirm(ctx, albumID, memberToken, avatarID)
	if err != nil {
		switch {
		case errors.Is(err, repository.ErrCallerRevoked), errors.Is(err, repository.ErrAlbumNotFound):
			return apierr.MemberRevoked("your access to this album has been revoked")
		case errors.Is(err, repository.ErrAvatarNotFound):
			return apierr.Conflict("avatar reservation is no longer current ; re-upload")
		}
		return apierr.Internal("failed to confirm avatar").WithCause(err)
	}
	s.cleanup(ctx, replaced)
	if !row.Confirmed {
		s.emitUpdated(albumID, callerUserID, memberToken)
	}
	return nil
}

func (s *AvatarService) Remove(ctx context.Context, albumID uuid.UUID, callerUserID uuid.UUID, memberToken []byte) error {
	keys, err := s.repo.Remove(ctx, albumID, memberToken)
	if err != nil {
		return apierr.Internal("failed to remove avatar").WithCause(err)
	}
	s.cleanup(ctx, keys)
	if len(keys) > 0 {
		s.emitUpdated(albumID, callerUserID, memberToken)
	}
	return nil
}

// DownloadURL is scoped to the album the middleware already checked
func (s *AvatarService) DownloadURL(ctx context.Context, albumID, avatarID uuid.UUID) (*DownloadURLResult, error) {
	row, err := s.repo.Get(ctx, albumID, avatarID)
	if err != nil {
		if errors.Is(err, repository.ErrAvatarNotFound) {
			return nil, apierr.NotFound("avatar not found")
		}
		return nil, apierr.Internal("failed to read avatar").WithCause(err)
	}
	if !row.Confirmed {
		return nil, apierr.NotFound("avatar not found")
	}
	url, err := s.s3.GetPresignedDownloadURL(ctx, row.StorageKey, DownloadURLTTL)
	if err != nil {
		return nil, apierr.Internal("failed to presign avatar download").WithCause(err)
	}
	return &DownloadURLResult{URL: url, ExpiresAt: time.Now().Add(DownloadURLTTL)}, nil
}

// Retires uploads that were reserved but never confirmed
func (s *AvatarService) RunPendingCleanup(ctx context.Context) {
	run := func() {
		keys, err := s.repo.QueueStalePending(ctx,
			time.Now().Add(-PendingUploadStaleAfter), PendingCleanupBatchSize)
		if err != nil {
			slog.ErrorContext(ctx, "pending avatar cleanup failed", "err", err)
			return
		}
		s.cleanup(ctx, keys)
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

func (s *AvatarService) drop(ctx context.Context, albumID uuid.UUID, memberToken []byte, avatarID uuid.UUID) {
	keys, err := s.repo.DropPending(ctx, albumID, memberToken, avatarID)
	if err != nil {
		slog.WarnContext(ctx, "avatar: drop pending failed", "err", err)
		return
	}
	s.cleanup(ctx, keys)
}

func (s *AvatarService) cleanup(ctx context.Context, keys []string) {
	if s.cleaner != nil && len(keys) > 0 {
		s.cleaner.CleanupObjectKeys(ctx, keys)
	}
}

// Offline members converge on their next listing
func (s *AvatarService) emitUpdated(albumID, callerUserID uuid.UUID, memberToken []byte) {
	if s.notifier == nil || s.lookup == nil {
		return
	}
	go func() {
		bg := context.Background()
		members, err := s.lookup.ActiveMemberUserIDs(bg, albumID)
		if err != nil {
			slog.Warn("member_updated: lookup failed", "err", err, "album_id", albumID)
			return
		}
		ids := make([]uuid.UUID, 0, len(members))
		for _, m := range members {
			if m != callerUserID {
				ids = append(ids, m)
			}
		}
		if len(ids) == 0 {
			return
		}
		if err := s.notifier.EmitToUsers(bg, ids, ws.EventMemberUpdated, map[string]any{
			"album_id":     albumID.String(),
			"member_token": base64.StdEncoding.EncodeToString(memberToken),
		}); err != nil {
			slog.Warn("member_updated: emit failed", "err", err, "album_id", albumID)
		}
	}()
}
