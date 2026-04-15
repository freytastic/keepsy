package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type MockInviteStore struct {
	CreateFunc     func(ctx context.Context, invite *model.InviteLink) error
	GetByCodeFunc  func(ctx context.Context, code string) (*model.InviteLink, error)
	GetPreviewFunc func(ctx context.Context, code string) (*model.InvitePreview, error)
	JoinAlbumFunc  func(ctx context.Context, albumID, userID uuid.UUID, code string) error
}

func (m *MockInviteStore) Create(ctx context.Context, i *model.InviteLink) error {
	return m.CreateFunc(ctx, i)
}
func (m *MockInviteStore) GetByCode(ctx context.Context, c string) (*model.InviteLink, error) {
	return m.GetByCodeFunc(ctx, c)
}
func (m *MockInviteStore) GetPreview(ctx context.Context, c string) (*model.InvitePreview, error) {
	return m.GetPreviewFunc(ctx, c)
}
func (m *MockInviteStore) JoinAlbum(ctx context.Context, aid, uid uuid.UUID, c string) error {
	return m.JoinAlbumFunc(ctx, aid, uid, c)
}

func TestInviteService_CreateInvite(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()

	tests := []struct {
		name      string
		maxUses   *int
		expiresAt *time.Time
		mockAlbum func() *MockAlbumStore
		mockInv   func() *MockInviteStore
		wantErr   error
		checkRes  func(t *testing.T, invite *model.InviteLink)
	}{
		{
			name: "Success: with defaults",
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{}, nil
					},
				}
			},
			mockInv: func() *MockInviteStore {
				return &MockInviteStore{
					CreateFunc: func(ctx context.Context, i *model.InviteLink) error { return nil },
				}
			},
			checkRes: func(t *testing.T, i *model.InviteLink) {
				if i.MaxUses == nil || *i.MaxUses != 25 {
					t.Errorf("Expected default max uses 25, got %v", i.MaxUses)
				}
				if i.ExpiresAt == nil || i.ExpiresAt.Before(time.Now().Add(23*time.Hour)) {
					t.Errorf("Expected default expiry ~24h, got %v", i.ExpiresAt)
				}
			},
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
			mockInv: func() *MockInviteStore { return &MockInviteStore{} },
			wantErr: ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewInviteService(tt.mockInv(), tt.mockAlbum())
			res, err := s.CreateInvite(context.Background(), albumID, userID, tt.maxUses, tt.expiresAt)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("CreateInvite() error = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr == nil && tt.checkRes != nil {
				tt.checkRes(t, res)
			}
		})
	}
}

func TestInviteService_JoinByInvite(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()
	code := "kps_test"

	tests := []struct {
		name      string
		mockAlbum func() *MockAlbumStore
		mockInv   func() *MockInviteStore
		wantErr   error
	}{
		{
			name: "Success",
			mockInv: func() *MockInviteStore {
				return &MockInviteStore{
					GetByCodeFunc: func(ctx context.Context, c string) (*model.InviteLink, error) {
						return &model.InviteLink{AlbumID: albumID}, nil
					},
					JoinAlbumFunc: func(ctx context.Context, aid, uid uuid.UUID, c string) error { return nil },
				}
			},
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					CountMembersFunc: func(ctx context.Context, aid uuid.UUID) (int, error) { return 5, nil },
				}
			},
			wantErr: nil,
		},
		{
			name: "Failure: Album Full",
			mockInv: func() *MockInviteStore {
				return &MockInviteStore{
					GetByCodeFunc: func(ctx context.Context, c string) (*model.InviteLink, error) {
						return &model.InviteLink{AlbumID: albumID}, nil
					},
				}
			},
			mockAlbum: func() *MockAlbumStore {
				return &MockAlbumStore{
					CountMembersFunc: func(ctx context.Context, aid uuid.UUID) (int, error) { return MaxAlbumMembers, nil },
				}
			},
			wantErr: ErrAlbumFull,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewInviteService(tt.mockInv(), tt.mockAlbum())
			err := s.JoinByInvite(context.Background(), code, userID)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("JoinByInvite() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
