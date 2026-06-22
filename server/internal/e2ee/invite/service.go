package invite

import (
	"context"
	"crypto/ed25519"
	"errors"
	"sort"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/handle"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

const (
	wrapNonceLen = 12
	wrapTagCTLen = 48 // GCM tag(16) + MK ciphertext(32)
	sigLen       = ed25519.SignatureSize
	pubLen       = 32
)

// ErrAlreadyMember is returned by the repo when the M bridge (user_handle, album)
// row already exists : the caller maps it to 409 for idempotent reinvite UX
var ErrAlreadyMember = errors.New("invite: target already a member of this album")

var ErrAlbumFull = errors.New("invite: album has reached the maximum number of members")

// Onboarding only happens through DeliverExistingUser now, so this is the only
// point for the cap
const MaxAlbumMembers = 10

// store is the repo surface DeliverExistingUser needs. Tests substitute a mock
type store interface {
	FindUserIDByKeepsyID(ctx context.Context, keepsyID string) (uuid.UUID, error)
	CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, error)
	DeliverMember(ctx context.Context, in DeliverMemberInput) ([]byte, error)
	IKByMemberToken(ctx context.Context, memberToken []byte) ([]byte, error)
	MarkReceived(ctx context.Context, memberToken []byte, epoch int) error
}

type Service struct{ repo store }

func NewService(repo store) *Service { return &Service{repo: repo} }

// Envelope is one per epoch MK wrap for the new member: the §4.2 blob split into
// nonce + tag‖ct, plus the per epoch sender_sig the recipient verifies
type Envelope struct {
	Epoch     int
	WrapNonce []byte
	WrapTagCT []byte
	SenderSig []byte
}

type DeliverExistingUserInput struct {
	TargetKeepsyID string
	EKPub          []byte
	OPKIdxUsed     *int
	Envelopes      []Envelope
}

// DeliverMemberInput is the single tx write shape handed to the repo
type DeliverMemberInput struct {
	AlbumID     uuid.UUID
	UserID      uuid.UUID
	SenderToken []byte
	EKPub       []byte
	OPKIdxUsed  *int
	Envelopes   []Envelope // sorted ascending by epoch, contiguous 0..current
}

// DeliverExistingUser validates an invite and delivers all historical MK wraps
// to a freshly minted member_token for the target. Validation order is fixed so
// the error surface is stable. Returns the new member_token and the resolved
// target user_id (for the caller's WS fanout) on success
func (s *Service) DeliverExistingUser(ctx context.Context, albumID uuid.UUID, callerToken []byte, callerRole string, in DeliverExistingUserInput) ([]byte, uuid.UUID, error) {
	if callerRole != "admin" && callerRole != "co-admin" {
		return nil, uuid.Nil, apierr.Forbidden("only admin or co-admin can invite")
	}
	if len(in.EKPub) != pubLen {
		return nil, uuid.Nil, apierr.Validation("ek_pub must be 32 bytes")
	}
	if in.OPKIdxUsed != nil && *in.OPKIdxUsed < 0 {
		return nil, uuid.Nil, apierr.Validation("opk_idx_used must be >= 0 when present")
	}

	norm, err := handle.Normalize(in.TargetKeepsyID)
	if err != nil {
		return nil, uuid.Nil, apierr.NotFound("user not found")
	}
	userID, err := s.repo.FindUserIDByKeepsyID(ctx, norm)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			return nil, uuid.Nil, apierr.NotFound("user not found")
		}
		return nil, uuid.Nil, err
	}

	current, err := s.repo.CurrentEpoch(ctx, albumID)
	if err != nil {
		return nil, uuid.Nil, err
	}
	if current < 0 {
		return nil, uuid.Nil, apierr.Validation("album has no epochs to deliver")
	}
	if len(in.Envelopes) == 0 {
		return nil, uuid.Nil, apierr.Validation("envelopes must be a non-empty array")
	}

	sorted := make([]Envelope, len(in.Envelopes))
	copy(sorted, in.Envelopes)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Epoch < sorted[j].Epoch })

	if sorted[len(sorted)-1].Epoch != current {
		return nil, uuid.Nil, apierr.EpochReplay("envelopes must cover up to the current epoch")
	}
	if len(sorted) != current+1 {
		return nil, uuid.Nil, apierr.Validation("envelopes must contiguously cover epochs 0..current")
	}
	for i, e := range sorted {
		if e.Epoch != i {
			return nil, uuid.Nil, apierr.Validation("envelopes must contiguously cover epochs 0..current")
		}
		if len(e.WrapNonce) != wrapNonceLen {
			return nil, uuid.Nil, apierr.Validation("envelopes[].wrap_nonce must be 12 bytes")
		}
		if len(e.WrapTagCT) != wrapTagCTLen {
			return nil, uuid.Nil, apierr.Validation("envelopes[].wrap_tag_ct must be 48 bytes")
		}
		if len(e.SenderSig) != sigLen {
			return nil, uuid.Nil, apierr.Validation("envelopes[].sender_sig must be 64 bytes")
		}
	}

	token, err := s.repo.DeliverMember(ctx, DeliverMemberInput{
		AlbumID:     albumID,
		UserID:      userID,
		SenderToken: callerToken,
		EKPub:       in.EKPub,
		OPKIdxUsed:  in.OPKIdxUsed,
		Envelopes:   sorted,
	})
	if errors.Is(err, ErrAlreadyMember) {
		return nil, uuid.Nil, apierr.Conflict("target is already a member of this album")
	}
	if errors.Is(err, ErrAlbumFull) {
		return nil, uuid.Nil, apierr.AlbumFull(err.Error())
	}
	if err != nil {
		return nil, uuid.Nil, err
	}
	return token, userID, nil
}
