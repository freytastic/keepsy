package service

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)


type MediaStore interface {
	Create(ctx context.Context, media *model.Media) error
	GetByID(ctx context.Context, id uuid.UUID) (*model.Media, error)
	ListByAlbum(ctx context.Context, albumID uuid.UUID, limit, offset int) ([]model.Media, error)
	Delete(ctx context.Context, id uuid.UUID) error
}

type FileStore interface {
	GetPresignedUploadURL(ctx context.Context, key string, contentType string, expires time.Duration) (string, error)
	GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error)
	DeleteObject(ctx context.Context, key string) error
}

type MediaService struct {
	mediaRepo MediaStore
	albumRepo AlbumStore
	fileStore FileStore
}

func NewMediaService(mediaRepo MediaStore, albumStore AlbumStore, fileStore FileStore) *MediaService {
	return &MediaService{
		mediaRepo: mediaRepo,
		albumRepo: albumStore,
		fileStore: fileStore,
	}
}

// UploadRequest contains the info needed to generate a presigned URL
type UploadRequest struct {
	AlbumID     uuid.UUID
	UploaderID  uuid.UUID
	FileName    string
	ContentType string
	FileSize    int64
	MediaType   string // "photo" || "video"
}

// RequestUploadURL generates a presigned URL and prepares the DB record
func (s *MediaService) RequestUploadURL(ctx context.Context, req UploadRequest) (string, *model.Media, error) {
	//user must be an album member
	_, err := s.albumRepo.GetMember(ctx, req.AlbumID, req.UploaderID)
	if err != nil {
		return "", nil, ErrUnauthorized
	}

	mediaID := uuid.New()
	ext := filepath.Ext(req.FileName)
	storageKey := fmt.Sprintf("albums/%s/%s%s", req.AlbumID, mediaID, ext)

	// Get presigned URL for the front to upload directly to R2/MinIO
	uploadURL, err := s.fileStore.GetPresignedUploadURL(ctx, storageKey, req.ContentType, 15*time.Minute)
	if err != nil {
		return "", nil, fmt.Errorf("failed to generate upload url: %w", err)
	}

	media := &model.Media{
		ID:         mediaID,
		AlbumID:    req.AlbumID,
		UploaderID: req.UploaderID,
		StorageKey: storageKey,
		MediaType:  req.MediaType,
		MimeType:   req.ContentType,
		FileSize:   req.FileSize,
	}

	return uploadURL, media, nil
}

// ConfirmUpload saves the media record to the DB after the front confirms the file is uploaded
func (s *MediaService) ConfirmUpload(ctx context.Context, media *model.Media, userID uuid.UUID) error {
	// user must be an album member
	_, err := s.albumRepo.GetMember(ctx, media.AlbumID, userID)
	if err != nil {
		return ErrUnauthorized
	}

	return s.mediaRepo.Create(ctx, media)
}

func (s *MediaService) ListMedia(ctx context.Context, albumID, userID uuid.UUID, limit, offset int) ([]model.MediaWithURL, error) {
	// user must be an album member
	_, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		return nil, ErrUnauthorized
	}

	mediaList, err := s.mediaRepo.ListByAlbum(ctx, albumID, limit, offset)
	if err != nil {
		return nil, err
	}

	results := make([]model.MediaWithURL, len(mediaList))
	for i, m := range mediaList {
		// generate a temporary download URL (valid for 1h)
		url, err := s.fileStore.GetPresignedDownloadURL(ctx, m.StorageKey, 1*time.Hour)
		if err != nil {
			return nil, fmt.Errorf("failed to generate download url: %w", err)
		}

		results[i] = model.MediaWithURL{
			Media:       m,
			DownloadURL: url,
		}
	}

	return results, nil
}

func (s *MediaService) DeleteMedia(ctx context.Context, mediaID, userID uuid.UUID) error {
	media, err := s.mediaRepo.GetByID(ctx, mediaID)
	if err != nil {
		return err
	}

	//uploader OR album owner/co-owner can delete
	member, err := s.albumRepo.GetMember(ctx, media.AlbumID, userID)
	if err != nil {
		return ErrUnauthorized
	}

	if media.UploaderID != userID && member.Role != "owner" && member.Role != "co-owner" {
		return ErrUnauthorized
	}

	// delete from storage
	err = s.fileStore.DeleteObject(ctx, media.StorageKey)
	if err != nil {
		return fmt.Errorf("failed to delete from storage: %w", err)
	}

	// delete from DB
	return s.mediaRepo.Delete(ctx, mediaID)
}
