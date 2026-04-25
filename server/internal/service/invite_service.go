package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type InviteStore interface {
	Create(ctx context.Context, invite *model.InviteLink) error
	GetByCode(ctx context.Context, code string) (*model.InviteLink, error)
	GetPreview(ctx context.Context, code string) (*model.InvitePreview, error)
	JoinAlbum(ctx context.Context, albumID, userID uuid.UUID, code string) error
	CreateBlob(ctx context.Context, blob *model.InviteBlob) error
	GetBlobByAlbumID(ctx context.Context, albumID uuid.UUID) (*model.InviteBlob, error)
}

type InviteService struct {
	inviteRepo InviteStore
	albumRepo  AlbumStore
}

func NewInviteService(inviteRepo InviteStore, albumRepo AlbumStore) *InviteService {
	return &InviteService{
		inviteRepo: inviteRepo,
		albumRepo:  albumRepo,
	}
}

func (s *InviteService) CreateInviteBlob(ctx context.Context, albumID, userID uuid.UUID, payload, signature string, expiresAt time.Time) (*model.InviteBlob, error) {
	// Only owner or co-owner can create invite blobs
	member, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		return nil, ErrUnauthorized
	}
	if member.Role != "owner" && member.Role != "co-owner" {
		return nil, ErrUnauthorized
	}

	blob := &model.InviteBlob{
		AlbumID:   albumID,
		Payload:   payload,
		Signature: signature,
		ExpiresAt: expiresAt,
	}

	err = s.inviteRepo.CreateBlob(ctx, blob)
	if err != nil {
		return nil, err
	}

	return blob, nil
}

func (s *InviteService) GetInviteBlob(ctx context.Context, albumID uuid.UUID) (*model.InviteBlob, error) {
	return s.inviteRepo.GetBlobByAlbumID(ctx, albumID)
}

func (s *InviteService) CreateInvite(ctx context.Context, albumID, userID uuid.UUID, maxUses *int, expiresAt *time.Time) (*model.InviteLink, error) {
	// must be album member to create invite
	_, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		return nil, ErrUnauthorized
	}

	// one link can add up to 10 users for now
	if maxUses == nil {
		defaultMax := 10
		maxUses = &defaultMax
	}
	if expiresAt == nil {
		t := time.Now().Add(24 * time.Hour)
		expiresAt = &t
	}

	// secure random code
	code, err := generateRandomCode(8)

	if err != nil {
		return nil, err
	}

	invite := &model.InviteLink{
		AlbumID:   albumID,
		CreatedBy: userID,
		Code:      "kps_" + code,
		MaxUses:   maxUses,
		ExpiresAt: expiresAt,
	}

	err = s.inviteRepo.Create(ctx, invite)
	if err != nil {
		return nil, err
	}

	return invite, nil
}

func (s *InviteService) GetInvitePreview(ctx context.Context, code string) (*model.InvitePreview, error) {
	return s.inviteRepo.GetPreview(ctx, code)
}

func (s *InviteService) JoinByInvite(ctx context.Context, code string, userID uuid.UUID) error {
	invite, err := s.inviteRepo.GetByCode(ctx, code)
	if err != nil {
		return err
	}

	// check if album is full
	count, err := s.albumRepo.CountMembers(ctx, invite.AlbumID)
	if err != nil {
		return err
	}
	if count >= MaxAlbumMembers {
		return ErrAlbumFull
	}

	return s.inviteRepo.JoinAlbum(ctx, invite.AlbumID, userID, code)
}

func generateRandomCode(n int) (string, error) {
	bytes := make([]byte, n/2)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}
