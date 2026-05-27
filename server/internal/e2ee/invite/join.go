package invite

import (
	"context"
	"crypto/ed25519"
	"encoding/binary"
	"errors"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/crypto"
	"github.com/google/uuid"
)

const joinCompletePrefix = "join-complete-v1"

// JoinCompleteMsg = "join-complete-v1" ‖ album_id(16) ‖ uint32_be(epoch) ‖ ek_pub_admin(32)
// Exported so the KAT generator and the Dart client build byte-identical input
func JoinCompleteMsg(albumID uuid.UUID, epoch int, ekPubAdmin []byte) []byte {
	out := make([]byte, 0, len(joinCompletePrefix)+16+4+len(ekPubAdmin))
	out = append(out, joinCompletePrefix...)
	out = append(out, albumID[:]...)
	var ep [4]byte
	binary.BigEndian.PutUint32(ep[:], uint32(epoch))
	out = append(out, ep[:]...)
	out = append(out, ekPubAdmin...)
	return out
}

type JoinCompleteInput struct {
	Epoch      int
	EKPubAdmin []byte
	Sig        []byte
}

// JoinComplete verifies a new member's signed receipt against their own IK and
// records the epoch they proved they installed (§6.3). Idempotent: re-posting an
// older epoch keeps the high-water mark (GREATEST in the repo)
func (s *Service) JoinComplete(ctx context.Context, albumID uuid.UUID, callerToken []byte, in JoinCompleteInput) error {
	if in.Epoch < 0 {
		return apierr.Validation("epoch must be >= 0")
	}
	if len(in.EKPubAdmin) != pubLen {
		return apierr.Validation("ek_pub_admin must be 32 bytes")
	}
	if len(in.Sig) != sigLen {
		return apierr.Validation("sig must be 64 bytes")
	}
	ikPub, err := s.repo.IKByMemberToken(ctx, callerToken)
	if err != nil {
		if errors.Is(err, ErrIKNotFound) {
			return apierr.SigInvalid("cannot resolve caller identity")
		}
		return err
	}
	if err := crypto.VerifyEd25519(ed25519.PublicKey(ikPub), JoinCompleteMsg(albumID, in.Epoch, in.EKPubAdmin), in.Sig); err != nil {
		return apierr.SigInvalid("join-complete signature verification failed").WithCause(err)
	}
	return s.repo.MarkReceived(ctx, callerToken, in.Epoch)
}
