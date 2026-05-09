package service

import (
	"context"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type UserStore interface {
	GetByID(ctx context.Context, id uuid.UUID) (*model.User, error)
	Update(ctx context.Context, user *model.User) error
}

type UserService struct {
	userRepo UserStore
}

func NewUserService(userRepo UserStore) *UserService {
	return &UserService{userRepo: userRepo}
}

func (s *UserService) GetUserByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

// UserUpdate is the profile only update bag. Name is now per album in
// album_members.name_ct (M7) and lives client side : E2EE columns moved to
// internal/e2ee/prekey
type UserUpdate struct {
	AccentColor string
	Theme       string
}

func (s *UserService) UpdateUser(ctx context.Context, id uuid.UUID, in UserUpdate) (*model.User, error) {
	u, err := s.userRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if in.AccentColor != "" {
		u.AccentColor = in.AccentColor
	}
	if in.Theme != "" {
		u.Theme = in.Theme
	}
	if err := s.userRepo.Update(ctx, u); err != nil {
		return nil, err
	}
	return u, nil
}
