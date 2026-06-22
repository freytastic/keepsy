package service

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

var ErrUnauthorized = errors.New("unauthorized")

// The album member cap (MaxAlbumMembers) is enforced in the E2EE invite
// delivery path : internal/e2ee/invite. Onboarding only happens there, so the
// cap lives next to its only point rather than here

type AlbumStore interface {
	CreateWithAdmin(ctx context.Context, nameCT []byte, creatorUserID uuid.UUID) (*model.Album, []byte, error)
	GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error)
	ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error)
	LookupMember(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error)
	ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error)
	UpdateName(ctx context.Context, albumID uuid.UUID, nameCT []byte) error
	UpdateMemberNameCT(ctx context.Context, albumID uuid.UUID, memberToken, nameCT []byte) error
	Delete(ctx context.Context, id uuid.UUID) error
}

type AlbumService struct {
	albumRepo AlbumStore
}

func NewAlbumService(albumRepo AlbumStore) *AlbumService {
	return &AlbumService{albumRepo: albumRepo}
}

type CreateAlbumResult struct {
	Album       *model.Album
	MemberToken []byte
	Role        string
}

func (s *AlbumService) CreateAlbum(ctx context.Context, nameCT []byte, creatorID uuid.UUID) (*CreateAlbumResult, error) {
	if len(nameCT) == 0 {
		return nil, errors.New("name_ct is required")
	}
	a, token, err := s.albumRepo.CreateWithAdmin(ctx, nameCT, creatorID)
	if err != nil {
		return nil, err
	}
	return &CreateAlbumResult{Album: a, MemberToken: token, Role: "admin"}, nil
}

func (s *AlbumService) GetAlbum(ctx context.Context, albumID, userID uuid.UUID) (*model.AlbumWithMemberInfo, error) {
	token, role, err := s.albumRepo.LookupMember(ctx, userID, albumID)
	if err != nil {
		if errors.Is(err, repository.ErrMemberNotFound) {
			return nil, ErrUnauthorized
		}
		return nil, err
	}

	a, err := s.albumRepo.GetByID(ctx, albumID)
	if err != nil {
		return nil, err
	}
	return &model.AlbumWithMemberInfo{Album: *a, UserRole: role, MemberToken: token}, nil
}

func (s *AlbumService) ListUserAlbums(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return s.albumRepo.ListForUser(ctx, userID)
}

func (s *AlbumService) UpdateAlbum(ctx context.Context, albumID, userID uuid.UUID, nameCT []byte) error {
	_, role, err := s.albumRepo.LookupMember(ctx, userID, albumID)
	if err != nil {
		return ErrUnauthorized
	}
	if role != "admin" && role != "co-admin" {
		return ErrUnauthorized
	}
	if len(nameCT) == 0 {
		return errors.New("name_ct is required")
	}
	return s.albumRepo.UpdateName(ctx, albumID, nameCT)
}

func (s *AlbumService) DeleteAlbum(ctx context.Context, albumID, userID uuid.UUID) error {
	_, role, err := s.albumRepo.LookupMember(ctx, userID, albumID)
	if err != nil {
		return ErrUnauthorized
	}
	if role != "admin" {
		return ErrUnauthorized
	}
	return s.albumRepo.Delete(ctx, albumID)
}

func (s *AlbumService) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	return s.albumRepo.ListMembers(ctx, albumID)
}

// UpdateMemberNameCT writes the caller's encrypted name for one album. The
// caller's member_token is resolved by the RequireMember middleware : the
// service only validates payload shape and forwards. Bytes are opaque to
// the server (encrypted under the album's MK on the client)
func (s *AlbumService) UpdateMemberNameCT(ctx context.Context, albumID uuid.UUID, memberToken, nameCT []byte) error {
	if len(memberToken) == 0 {
		return ErrUnauthorized
	}
	if len(nameCT) == 0 {
		return errors.New("name_ct is required")
	}
	return s.albumRepo.UpdateMemberNameCT(ctx, albumID, memberToken, nameCT)
}
