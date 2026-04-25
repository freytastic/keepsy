package service

import (
	"context"
	"errors"
	"testing"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

type MockAlbumStore struct {
	CreateWithMemberFunc func(ctx context.Context, album *model.Album) error
	GetByIDFunc          func(ctx context.Context, id uuid.UUID) (*model.Album, error)
	ListForUserFunc      func(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error)
	GetMemberFunc        func(ctx context.Context, albumID, userID uuid.UUID) (*model.AlbumMember, error)
	UpdateFunc           func(ctx context.Context, album *model.Album) error
	DeleteFunc           func(ctx context.Context, id uuid.UUID) error
	AddMemberFunc        func(ctx context.Context, albumID, userID uuid.UUID, role string) error
	CountMembersFunc     func(ctx context.Context, albumID uuid.UUID) (int, error)
}

func (m *MockAlbumStore) CreateWithMember(ctx context.Context, a *model.Album) error {
	return m.CreateWithMemberFunc(ctx, a)
}
func (m *MockAlbumStore) GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error) {
	return m.GetByIDFunc(ctx, id)
}
func (m *MockAlbumStore) ListForUser(ctx context.Context, uid uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return m.ListForUserFunc(ctx, uid)
}
func (m *MockAlbumStore) GetMember(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
	return m.GetMemberFunc(ctx, aid, uid)
}
func (m *MockAlbumStore) Update(ctx context.Context, a *model.Album) error {
	return m.UpdateFunc(ctx, a)
}
func (m *MockAlbumStore) Delete(ctx context.Context, id uuid.UUID) error {
	return m.DeleteFunc(ctx, id)
}
func (m *MockAlbumStore) AddMember(ctx context.Context, aid, uid uuid.UUID, r string) error {
	return m.AddMemberFunc(ctx, aid, uid, r)
}
func (m *MockAlbumStore) CountMembers(ctx context.Context, aid uuid.UUID) (int, error) {
	return m.CountMembersFunc(ctx, aid)
}

func TestAlbumService_GetAlbum(t *testing.T) {
	albumID := uuid.New()
	userID := uuid.New()
	otherUserID := uuid.New()

	tests := []struct {
		name    string
		albumID uuid.UUID
		userID  uuid.UUID
		mock    func() *MockAlbumStore
		wantErr error
	}{
		{
			name:    "Success",
			albumID: albumID,
			userID:  userID,
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{AlbumID: aid, UserID: uid, Role: "member"}, nil
					},
					GetByIDFunc: func(ctx context.Context, id uuid.UUID) (*model.Album, error) {
						return &model.Album{ID: id, Name: "Test Album"}, nil
					},
				}
			},
			wantErr: nil,
		},
		{
			name:    "Failure: Unauthorized (Not a member)",
			albumID: albumID,
			userID:  otherUserID,
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return nil, repository.ErrMemberNotFound
					},
				}
			},
			wantErr: ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAlbumService(tt.mock())
			_, err := s.GetAlbum(context.Background(), tt.albumID, tt.userID)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("GetAlbum() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestAlbumService_DeleteAlbum(t *testing.T) {
	albumID := uuid.New()
	ownerID := uuid.New()
	memberID := uuid.New()

	tests := []struct {
		name    string
		albumID uuid.UUID
		userID  uuid.UUID
		mock    func() *MockAlbumStore
		wantErr error
	}{
		{
			name:    "Success: Owner can delete",
			albumID: albumID,
			userID:  ownerID,
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "owner"}, nil
					},
					DeleteFunc: func(ctx context.Context, id uuid.UUID) error {
						return nil
					},
				}
			},
			wantErr: nil,
		},
		{
			name:    "Failure: Member cannot delete",
			albumID: albumID,
			userID:  memberID,
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "member"}, nil
					},
				}
			},
			wantErr: ErrUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAlbumService(tt.mock())
			err := s.DeleteAlbum(context.Background(), tt.albumID, tt.userID)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("DeleteAlbum() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestAlbumService_AddMember(t *testing.T) {
	albumID := uuid.New()
	requesterID := uuid.New()
	newUserID := uuid.New()

	tests := []struct {
		name    string
		mock    func() *MockAlbumStore
		wantErr error
	}{
		{
			name: "Success",
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "co-owner"}, nil
					},
					CountMembersFunc: func(ctx context.Context, aid uuid.UUID) (int, error) {
						return 5, nil
					},
					AddMemberFunc: func(ctx context.Context, aid, uid uuid.UUID, role string) error {
						return nil
					},
				}
			},
			wantErr: nil,
		},
		{
			name: "Failure: Album Full",
			mock: func() *MockAlbumStore {
				return &MockAlbumStore{
					GetMemberFunc: func(ctx context.Context, aid, uid uuid.UUID) (*model.AlbumMember, error) {
						return &model.AlbumMember{Role: "owner"}, nil
					},
					CountMembersFunc: func(ctx context.Context, aid uuid.UUID) (int, error) {
						return MaxAlbumMembers, nil
					},
				}
			},
			wantErr: ErrAlbumFull,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAlbumService(tt.mock())
			err := s.AddMember(context.Background(), albumID, requesterID, newUserID)

			if !errors.Is(err, tt.wantErr) {
				t.Errorf("AddMember() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
