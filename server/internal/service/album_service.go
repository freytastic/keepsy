package service

import (
	"bytes"
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

var (
	ErrUnauthorized   = errors.New("unauthorized")
	ErrLastAdmin      = errors.New("cannot remove the last remaining admin")
	ErrMemberNotFound = errors.New("member not found in album")
	// Surfaced as E_MEMBER_REVOKED so the client wipes local album data
	ErrCallerRevoked = errors.New("caller was revoked mid-operation")
)

// The E2EE invite transaction owns the album member cap

type AlbumStore interface {
	CreateWithAdmin(ctx context.Context, nameCT []byte, creatorUserID uuid.UUID) (*model.Album, []byte, error)
	GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error)
	ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error)
	LookupMember(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error)
	ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error)
	UpdateName(ctx context.Context, albumID uuid.UUID, nameCT []byte) error
	UpdateMemberNameCT(ctx context.Context, albumID uuid.UUID, memberToken, nameCT []byte) error
	// Deletes under the album lock, re checking the caller is the active admin
	DeleteAlbumTx(ctx context.Context, albumID uuid.UUID, callerToken []byte) (repository.AlbumRemoval, error)

	// Shares the album lock with rotation and upload reservation
	// Rechecks caller state and the last-admin guard before revoking
	RevokeMemberTx(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (role string, alreadyRevoked bool, err error)
}

// Deletes objects already queued for durable cleanup
type ObjectCleaner interface {
	CleanupObjectKeys(ctx context.Context, keys []string)
}

type AlbumService struct {
	albumRepo AlbumStore
	cleaner   ObjectCleaner
}

func NewAlbumService(albumRepo AlbumStore) *AlbumService {
	return &AlbumService{albumRepo: albumRepo}
}

func (s *AlbumService) SetObjectCleaner(c ObjectCleaner) { s.cleaner = c }

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
	if role != "admin" {
		return ErrUnauthorized
	}
	if len(nameCT) == 0 {
		return errors.New("name_ct is required")
	}
	return s.albumRepo.UpdateName(ctx, albumID, nameCT)
}

// DeleteAlbum returns the members who must be told the album is gone
func (s *AlbumService) DeleteAlbum(ctx context.Context, albumID, userID uuid.UUID) ([]uuid.UUID, error) {
	token, role, err := s.albumRepo.LookupMember(ctx, userID, albumID)
	if err != nil || role != "admin" {
		return nil, ErrUnauthorized
	}
	removed, err := s.albumRepo.DeleteAlbumTx(ctx, albumID, token)
	switch {
	case errors.Is(err, repository.ErrCallerRevoked):
		return nil, ErrCallerRevoked
	case errors.Is(err, repository.ErrNotAlbumAdmin), errors.Is(err, repository.ErrAlbumNotFound):
		return nil, ErrUnauthorized
	case err != nil:
		return nil, err
	}
	if s.cleaner != nil {
		s.cleaner.CleanupObjectKeys(ctx, removed.Keys)
	}
	return removed.MemberUserIDs, nil
}

func (s *AlbumService) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	return s.albumRepo.ListMembers(ctx, albumID)
}

type RemoveMemberResult struct {
	TargetToken    []byte
	AlreadyRevoked bool
}

// Revocation must commit before the client's recovery rotation begins
func (s *AlbumService) RemoveMember(ctx context.Context, albumID, callerUserID uuid.UUID, targetToken []byte) (*RemoveMemberResult, error) {
	callerToken, callerRole, err := s.albumRepo.LookupMember(ctx, callerUserID, albumID)
	if err != nil {
		return nil, ErrUnauthorized
	}

	// Authorize before reading target state to avoid leaking it through a 204
	isSelf := bytes.Equal(callerToken, targetToken)
	if !isSelf && callerRole != "admin" {
		return nil, ErrUnauthorized
	}

	// The shared lock closes races with another revoke or rotation
	_, alreadyRevoked, err := s.albumRepo.RevokeMemberTx(ctx, albumID, callerToken, targetToken)
	if err != nil {
		switch {
		case errors.Is(err, repository.ErrCallerRevoked):
			return nil, ErrCallerRevoked
		case errors.Is(err, repository.ErrMemberNotFound),
			errors.Is(err, repository.ErrAlbumNotFound):
			return nil, ErrMemberNotFound
		case errors.Is(err, repository.ErrLastAdmin):
			return nil, ErrLastAdmin
		default:
			return nil, err
		}
	}
	return &RemoveMemberResult{TargetToken: targetToken, AlreadyRevoked: alreadyRevoked}, nil
}

// The middleware resolves membership before opaque encrypted bytes arrive here
func (s *AlbumService) UpdateMemberNameCT(ctx context.Context, albumID uuid.UUID, memberToken, nameCT []byte) error {
	if len(memberToken) == 0 {
		return ErrUnauthorized
	}
	if len(nameCT) == 0 {
		return errors.New("name_ct is required")
	}
	return s.albumRepo.UpdateMemberNameCT(ctx, albumID, memberToken, nameCT)
}
