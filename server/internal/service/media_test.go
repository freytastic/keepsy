package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

// MockMediaStore mocks the MediaStore interface
type MockMediaStore struct {
	CreateFunc      func(ctx context.Context, media *model.Media) error
	GetByIDFunc     func(ctx context.Context, id uuid.UUID) (*model.Media, error)
	ListByAlbumFunc func(ctx context.Context, albumID uuid.UUID, limit, offset int) ([]model.Media, error)
	DeleteFunc      func(ctx context.Context, id uuid.UUID) error
}

func (m *MockMediaStore) Create(ctx context.Context, media *model.Media) error {
	return m.CreateFunc(ctx, media)
}
func (m *MockMediaStore) GetByID(ctx context.Context, id uuid.UUID) (*model.Media, error) {
	return m.GetByIDFunc(ctx, id)
}
func (m *MockMediaStore) ListByAlbum(ctx context.Context, aid uuid.UUID, l, o int) ([]model.Media, error) {
	return m.ListByAlbumFunc(ctx, aid, l, o)
}
func (m *MockMediaStore) Delete(ctx context.Context, id uuid.UUID) error {
	return m.DeleteFunc(ctx, id)
}

// MockFileStore mocks the FileStore interface
type MockFileStore struct {
	GetPresignedUploadURLFunc   func(ctx context.Context, key, contentType string, expires time.Duration) (string, error)
	GetPresignedDownloadURLFunc func(ctx context.Context, key string, expires time.Duration) (string, error)
	DeleteObjectFunc            func(ctx context.Context, key string) error
}

func (m *MockFileStore) GetPresignedUploadURL(ctx context.Context, k, c string, e time.Duration) (string, error) {
	return m.GetPresignedUploadURLFunc(ctx, k, c, e)
}
func (m *MockFileStore) GetPresignedDownloadURL(ctx context.Context, k string, e time.Duration) (string, error) {
	return m.GetPresignedDownloadURLFunc(ctx, k, e)
}
func (m *MockFileStore) DeleteObject(ctx context.Context, k string) error {
	return m.DeleteObjectFunc(ctx, k)
}

func TestMediaService_RequestUploadURL(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()

	tests := []struct {
		name      string
		req       UploadRequest
		mockAlbum func() *MockAlbumStore
		mockMedia func() *MockMediaStore
		mockFile  func() *MockFileStore
		wantErr   error
	}{
		{
			name: "Success",
			req: UploadRequest{
				AlbumID:     albumID,
				UploaderID:  userID,
				FileName:    "test.jpg",
				ContentType: "image/jpeg",
			},
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{AlbumID: aid, UserID: uid}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{}
			},
			mockFile: func() *MockFileStore {
				return &MockFileStore{
					GetPresignedUploadURLFunc: func(ctx context.Context, k, c string, e time.Duration) (string, error) {
						return "http://presigned-url.com", nil
					},
				}
			},
			wantErr: nil,
		},
		{
			name: "Failure: Unauthorized",
			req: UploadRequest{
				AlbumID:    albumID,
				UploaderID: userID,
			},
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return nil, ErrUnauthorized
					},
				}
			},
			mockMedia: func() *MockMediaStore { return &MockMediaStore{} },
			mockFile:  func() *MockFileStore { return &MockFileStore{} },
			wantErr:   ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewMediaService(tt.mockMedia(), tt.mockAlbum(), tt.mockFile())
			url, _, err := s.RequestUploadURL(context.Background(), tt.req)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("RequestUploadURL() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr == nil && url == "" {
				t.Errorf("RequestUploadURL() returned empty URL")
			}
		})
	}
}

func TestMediaService_ConfirmUpload(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()
	media := &model.Media{ID: uuid.New(), AlbumID: albumID, UploaderID: userID}

	tests := []struct {
		name      string
		mockAlbum func() *MockAlbumStore
		mockMedia func() *MockMediaStore
		wantErr   error
	}{
		{
			name: "Success",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{
					CreateFunc: func(ctx context.Context, m *model.Media) error { return nil },
				}
			},
			wantErr: nil,
		},
		{
			name: "Failure: Unauthorized",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return nil, ErrUnauthorized
					},
				}
			},
			mockMedia: func() *MockMediaStore { return &MockMediaStore{} },
			wantErr:   ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewMediaService(tt.mockMedia(), tt.mockAlbum(), &MockFileStore{})
			err := s.ConfirmUpload(context.Background(), media, userID)
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("ConfirmUpload() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestMediaService_ListMedia(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()

	tests := []struct {
		name      string
		mockAlbum func() *MockAlbumStore
		mockMedia func() *MockMediaStore
		mockFile  func() *MockFileStore
		wantErr   error
	}{
		{
			name: "Success",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{
					ListByAlbumFunc: func(ctx context.Context, aid uuid.UUID, l, o int) ([]model.Media, error) {
						return []model.Media{{ID: uuid.New(), StorageKey: "key1"}}, nil
					},
				}
			},
			mockFile: func() *MockFileStore {
				return &MockFileStore{
					GetPresignedDownloadURLFunc: func(ctx context.Context, k string, e time.Duration) (string, error) {
						return "http://download.com/key1", nil
					},
				}
			},
			wantErr: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewMediaService(tt.mockMedia(), tt.mockAlbum(), tt.mockFile())
			results, err := s.ListMedia(context.Background(), albumID, userID, 10, 0)
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("ListMedia() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr == nil {
				if len(results) != 1 {
					t.Errorf("ListMedia() expected 1 result, got %d", len(results))
				}
				if results[0].DownloadURL == "" {
					t.Errorf("ListMedia() missing download URL")
				}
			}
		})
	}
}

func TestMediaService_DeleteMedia(t *testing.T) {
	mediaID := uuid.New()
	userID := uuid.New()
	albumID := uuid.New()

	tests := []struct {
		name      string
		mockAlbum func() *MockAlbumStore
		mockMedia func() *MockMediaStore
		mockFile  func() *MockFileStore
		wantErr   error
	}{
		{
			name: "Success: Uploader can delete",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "member"}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{
					GetByIDFunc: func(ctx context.Context, id uuid.UUID) (*model.Media, error) {
						return &model.Media{ID: id, AlbumID: albumID, UploaderID: userID, StorageKey: "key"}, nil
					},
					DeleteFunc: func(ctx context.Context, id uuid.UUID) error { return nil },
				}
			},
			mockFile: func() *MockFileStore {
				return &MockFileStore{
					DeleteObjectFunc: func(ctx context.Context, k string) error { return nil },
				}
			},
			wantErr: nil,
		},
		{
			name: "Success: Admin can delete",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "co-owner"}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{
					GetByIDFunc: func(ctx context.Context, id uuid.UUID) (*model.Media, error) {
						return &model.Media{ID: id, AlbumID: albumID, UploaderID: uuid.New(), StorageKey: "key"}, nil
					},
					DeleteFunc: func(ctx context.Context, id uuid.UUID) error { return nil },
				}
			},
			mockFile: func() *MockFileStore {
				return &MockFileStore{
					DeleteObjectFunc: func(ctx context.Context, k string) error { return nil },
				}
			},
			wantErr: nil,
		},
		{
			name: "Failure: Member cannot delete others media",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "member"}, nil
					},
				}
			},
			mockMedia: func() *MockMediaStore {
				return &MockMediaStore{
					GetByIDFunc: func(ctx context.Context, id uuid.UUID) (*model.Media, error) {
						return &model.Media{ID: id, AlbumID: albumID, UploaderID: uuid.New(), StorageKey: "key"}, nil
					},
				}
			},
			mockFile: func() *MockFileStore { return &MockFileStore{} },
			wantErr:  ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewMediaService(tt.mockMedia(), tt.mockAlbum(), tt.mockFile())
			err := s.DeleteMedia(context.Background(), mediaID, userID)
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("DeleteMedia() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
