package service

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type UserStore interface {
	GetByID(ctx context.Context, id uuid.UUID) (*model.User, error)
	Update(ctx context.Context, user *model.User) error
}

type PrekeyStore interface {
	CreateBatch(ctx context.Context, opks []model.OneTimePrekey) error
	PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error)
	Count(ctx context.Context, userID uuid.UUID) (int, error)
}

type UserService struct {
	userRepo   UserStore
	prekeyRepo PrekeyStore
}

func NewUserService(userRepo UserStore, prekeyRepo PrekeyStore) *UserService {
	return &UserService{
		userRepo:   userRepo,
		prekeyRepo: prekeyRepo,
	}
}

func (s *UserService) GetUserByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *UserService) GetPrekeyBundle(ctx context.Context, userID uuid.UUID) (*model.PrekeyBundle, error) {
	user, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	if user.IKPub == nil || user.SPKPub == nil {
		return nil, errors.New("user has not completed E2EE setup")
	}

	// Atomically fetch and consume one OPK
	opk, err := s.prekeyRepo.PopRandom(ctx, userID)
	if err != nil {
		return nil, err
	}

	bundle := &model.PrekeyBundle{
		UserID: user.ID,
		IKPub:  *user.IKPub,
		LKPub:  *user.LKPub,
		SPKPub: *user.SPKPub,
		SPKSig: *user.SPKSig,
		SPKTs:  *user.SPKTs,
	}

	if opk != nil {
		bundle.OPK = &struct {
			ID         uuid.UUID `json:"id"`
			KeyContent string    `json:"key_content"`
		}{
			ID:         opk.ID,
			KeyContent: opk.KeyContent,
		}
	}

	return bundle, nil
}

func (s *UserService) ReplenishOPKs(ctx context.Context, userID uuid.UUID, keys []string) error {
	opks := make([]model.OneTimePrekey, len(keys))
	for i, key := range keys {
		opks[i] = model.OneTimePrekey{
			ID:         uuid.New(),
			UserID:     userID,
			KeyContent: key,
		}
	}
	return s.prekeyRepo.CreateBatch(ctx, opks)
}

func (s *UserService) GetOPKCount(ctx context.Context, userID uuid.UUID) (int, error) {
	return s.prekeyRepo.Count(ctx, userID)
}

func (s *UserService) UpdateUser(ctx context.Context, id uuid.UUID, name *string, accentColor string, theme string, ikPub, lkPub, spkPub, spkSig *string, spkTs *int64) (*model.User, error) {
	user, err := s.userRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}

	if name != nil {
		user.Name = name
	}
	if accentColor != "" {
		user.AccentColor = accentColor
	}
	if theme != "" {
		user.Theme = theme
	}

	if ikPub != nil {
		user.IKPub = ikPub
	}
	if lkPub != nil {
		user.LKPub = lkPub
	}
	if spkPub != nil {
		user.SPKPub = spkPub
	}
	if spkSig != nil {
		user.SPKSig = spkSig
	}
	if spkTs != nil {
		user.SPKTs = spkTs
	}

	err = s.userRepo.Update(ctx, user)
	if err != nil {
		return nil, err
	}

	return user, nil
}
