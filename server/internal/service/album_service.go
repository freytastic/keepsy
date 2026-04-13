package service

import (
	"context"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

var (
	ErrUnauthorized = errors.New("unauthorized")
	ErrAlbumFull    = errors.New("album has reached the maximum number of members")
)

const MaxAlbumMembers = 100 //for now lets say 100

type AlbumStore interface {
	CreateWithMember(ctx context.Context, album *model.Album) error
	GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error)
	ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error)
	GetMember(ctx context.Context, albumID, userID uuid.UUID) (*model.AlbumMember, error)
	Update(ctx context.Context, album *model.Album) error
	Delete(ctx context.Context, id uuid.UUID) error
	AddMember(ctx context.Context, albumID, userID uuid.UUID, role string) error
	CountMembers(ctx context.Context, albumID uuid.UUID) (int, error)
}

type AlbumService struct {
	albumRepo AlbumStore
}

func NewAlbumService(albumRepo AlbumStore) *AlbumService {
	return &AlbumService{albumRepo: albumRepo}
}

func (s *AlbumService) CreateAlbum(ctx context.Context, name, description string, creatorID uuid.UUID, widgetConfig map[string]interface{}) (*model.Album, error) {
	if widgetConfig == nil {
		widgetConfig = make(map[string]interface{})
	}

	album := &model.Album{
		Name:         name,
		Description:  description,
		CreatorID:    creatorID,
		WidgetConfig: widgetConfig,
	}

	err := s.albumRepo.CreateWithMember(ctx, album)
	if err != nil {
		return nil, err
	}

	return album, nil
}

func (s *AlbumService) GetAlbum(ctx context.Context, albumID, userID uuid.UUID) (*model.AlbumWithMemberInfo, error) {
	// check if user is a member
	member, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		if errors.Is(err, repository.ErrMemberNotFound) {
			return nil, ErrUnauthorized
		}
		return nil, err
	}

	// get album details
	album, err := s.albumRepo.GetByID(ctx, albumID)
	if err != nil {
		return nil, err
	}

	return &model.AlbumWithMemberInfo{
		Album:    *album,
		UserRole: member.Role,
	}, nil
}

func (s *AlbumService) ListUserAlbums(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return s.albumRepo.ListForUser(ctx, userID)
}

func (s *AlbumService) UpdateAlbum(ctx context.Context, albumID, userID uuid.UUID, name, description string, widgetConfig map[string]interface{}) error {
	//only owner can update
	member, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		return ErrUnauthorized
	}
	if member.Role != "owner" {
		return ErrUnauthorized
	}

	// get and update
	album, err := s.albumRepo.GetByID(ctx, albumID)
	if err != nil {
		return err
	}

	album.Name = name
	album.Description = description
	if widgetConfig != nil {
		album.WidgetConfig = widgetConfig
	}

	return s.albumRepo.Update(ctx, album)
}

func (s *AlbumService) DeleteAlbum(ctx context.Context, albumID, userID uuid.UUID) error {
	//only owner can delete
	member, err := s.albumRepo.GetMember(ctx, albumID, userID)
	if err != nil {
		return ErrUnauthorized
	}
	if member.Role != "owner" {
		return ErrUnauthorized
	}

	return s.albumRepo.Delete(ctx, albumID)
}

func (s *AlbumService) AddMember(ctx context.Context, albumID, requesterID, newUserID uuid.UUID) error {
	//only existing members can add others (or maybe only owner? letss stick to any member for now)
	_, err := s.albumRepo.GetMember(ctx, albumID, requesterID)
	if err != nil {
		return ErrUnauthorized
	}

	// check member limit
	count, err := s.albumRepo.CountMembers(ctx, albumID)
	if err != nil {
		return err
	}
	if count >= MaxAlbumMembers {
		return ErrAlbumFull
	}

	return s.albumRepo.AddMember(ctx, albumID, newUserID, "member")
}
