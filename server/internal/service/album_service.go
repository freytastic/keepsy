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
	// ErrCallerRevoked : the caller was revoked between the auth check and the
	// locked commit. Surfaced as E_MEMBER_REVOKED so the client self wipes
	ErrCallerRevoked = errors.New("caller was revoked mid-operation")
)

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

	// atomically revokes a member under an albums row lock (the
	// same lock epoch rotation takes), so concurrent removals / rotations
	// serialize. Under the lock it re checks the caller is still active, reads
	// the target, enforces the last admin guard, and stamps revoked_at in one
	// transaction. Returns the target's role, whether it was already revoked
	// (idempotent no op), and repository.ErrCallerRevoked / ErrMemberNotFound /
	// ErrLastAdmin / ErrAlbumNotFound as appropriate
	RevokeMemberTx(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (role string, alreadyRevoked bool, err error)
}

// AlbumObjectPurger deletes an album's media objects from S3. *MediaService
// satisfies it. Kept optional (settable) so album deletion still functions in
// tests / minimal wirings that don't care about object cleanup
type AlbumObjectPurger interface {
	PurgeAlbumObjects(ctx context.Context, albumID uuid.UUID) error
}

type AlbumService struct {
	albumRepo AlbumStore
	purger    AlbumObjectPurger
}

func NewAlbumService(albumRepo AlbumStore) *AlbumService {
	return &AlbumService{albumRepo: albumRepo}
}

// SetObjectPurger wires the media object cleanup used by DeleteAlbum. Set once
// at startup, after the media service exists
func (s *AlbumService) SetObjectPurger(p AlbumObjectPurger) { s.purger = p }

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
	// Delete the S3 objects first : the media rows cascade away with the album
	// row, so their storage keys must be read + purged before the DB delete or
	// the blobs orphan in object storage. If key *listing* fails we abort (don't
	// orphan everything):individual object delete failures are swallowed +
	// logged inside PurgeAlbumObjects
	if s.purger != nil {
		if err := s.purger.PurgeAlbumObjects(ctx, albumID); err != nil {
			return err
		}
	}
	return s.albumRepo.Delete(ctx, albumID)
}

func (s *AlbumService) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	return s.albumRepo.ListMembers(ctx, albumID)
}

// gives the outcome of a revoke so the handler can decide
// whether to fan out an e2ee.member_revoked event and hand the album to the
// admin for rotation
type RemoveMemberResult struct {
	TargetToken    []byte
	AlreadyRevoked bool
}

// RemoveMember revokes targetToken from the album on behalf of callerUserID
//	mark revoked happens before any rotation, so the removed member drops out of the active set the
// rotation's drift check recomputes

func (s *AlbumService) RemoveMember(ctx context.Context, albumID, callerUserID uuid.UUID, targetToken []byte) (*RemoveMemberResult, error) {
	callerToken, callerRole, err := s.albumRepo.LookupMember(ctx, callerUserID, albumID)
	if err != nil {
		return nil, ErrUnauthorized
	}

	// Authorize before touching the target : removing anyone but yourself needs
	// admin/co-admin. This precedes the idempotent already revoked no op so an
	// unauthorized caller can never learn a target's state via a 204
	isSelf := bytes.Equal(callerToken, targetToken)
	if !isSelf && callerRole != "admin" && callerRole != "co-admin" {
		return nil, ErrUnauthorized
	}

	// The caller re check + target read + last admin guard + revoke happen
	// atomically under the album lock: two concurrent admin removals can't both
	// pass the guard and leave the album adminless, a revoke can't interleave
	// with a rotation, and a caller revoked mid flight can't still remove anyone
	// (Role authz stays above, outside the lock, because roles are immutable)
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
