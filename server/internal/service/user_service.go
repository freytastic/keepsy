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
	return &UserService{userRepo: userRepo, prekeyRepo: prekeyRepo}
}

func (s *UserService) GetUserByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *UserService) GetPrekeyBundle(ctx context.Context, userID uuid.UUID) (*model.PrekeyBundle, error) {
	user, err := s.userRepo.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if len(user.IKPub) == 0 || len(user.SPKPub) == 0 {
		return nil, errors.New("user has not completed E2EE setup")
	}

	opk, err := s.prekeyRepo.PopRandom(ctx, userID)
	if err != nil {
		return nil, err
	}

	bundle := &model.PrekeyBundle{
		UserID: user.ID,
		IKPub:  user.IKPub,
		LKPub:  user.LKPub,
		SPKPub: user.SPKPub,
		SPKSig: user.SPKSig,
	}
	if user.SPKTs != nil {
		bundle.SPKTs = *user.SPKTs
	}
	if opk != nil {
		bundle.OPK = &struct {
			Idx    int    `json:"idx"`
			KeyPub []byte `json:"key_pub"`
		}{Idx: opk.OPKIdx, KeyPub: opk.KeyPub}
	}
	return bundle, nil
}

type OPKUpload struct {
	Idx    int
	KeyPub []byte
}

func (s *UserService) ReplenishOPKs(ctx context.Context, userID uuid.UUID, uploads []OPKUpload) error {
	opks := make([]model.OneTimePrekey, len(uploads))
	for i, u := range uploads {
		opks[i] = model.OneTimePrekey{
			ID:     uuid.New(),
			UserID: userID,
			OPKIdx: u.Idx,
			KeyPub: u.KeyPub,
		}
	}
	return s.prekeyRepo.CreateBatch(ctx, opks)
}

func (s *UserService) GetOPKCount(ctx context.Context, userID uuid.UUID) (int, error) {
	return s.prekeyRepo.Count(ctx, userID)
}

type UserUpdate struct {
	Name        *string
	AccentColor string
	Theme       string
	IKPub       []byte
	LKPub       []byte
	SPKPub      []byte
	SPKSig      []byte
	SPKTs       *int64
}

func (s *UserService) UpdateUser(ctx context.Context, id uuid.UUID, in UserUpdate) (*model.User, error) {
	u, err := s.userRepo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if in.Name != nil {
		u.Name = in.Name
	}
	if in.AccentColor != "" {
		u.AccentColor = in.AccentColor
	}
	if in.Theme != "" {
		u.Theme = in.Theme
	}
	if len(in.IKPub) > 0 {
		u.IKPub = in.IKPub
	}
	if len(in.LKPub) > 0 {
		u.LKPub = in.LKPub
	}
	if len(in.SPKPub) > 0 {
		u.SPKPub = in.SPKPub
	}
	if len(in.SPKSig) > 0 {
		u.SPKSig = in.SPKSig
	}
	if in.SPKTs != nil {
		u.SPKTs = in.SPKTs
	}
	if err := s.userRepo.Update(ctx, u); err != nil {
		return nil, err
	}
	return u, nil
}
