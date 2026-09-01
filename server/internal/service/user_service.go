package service

import (
	"context"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type UserStore interface {
	GetByID(ctx context.Context, id uuid.UUID) (*model.User, error)
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
