package epoch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sort"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/crypto"
	"github.com/google/uuid"
)

// store is the repo surface the service needs. Tests substitute a mock
type store interface {
	CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, bool, time.Time, error)
	AdminIKByMemberToken(ctx context.Context, memberToken []byte) ([]byte, error)
	InsertEpoch(ctx context.Context, in InsertEpochInput) error
	GetWrap(ctx context.Context, albumID uuid.UUID, epoch int, recipient []byte) (*Wrap, error)
}

type Service struct {
	repo store
}

func NewService(repo store) *Service {
	return &Service{repo: repo}
}

const (
	// VER=0x01 = AES-256-GCM, the only wrap format accepted for MK envelopes
	verAesGcm   = byte(0x01)
	gcmNonceLen = 12
	gcmTagLen   = 16
	tokenLen    = 32
	keyLen      = 32
	sigLen      = ed25519.SignatureSize
	pubLen      = ed25519.PublicKeySize
)

// WrapInput mirrors one entry in the POST body's "wraps" array
type WrapInput struct {
	RecipientToken []byte
	EkPub          []byte
	OpkIdxUsed     *int32 // nil for 3-DH (no OPK consumed)
	Wrap           []byte // VER ‖ NONCE ‖ TAG ‖ CT, VER must be 0x01
	SenderSig      []byte // X3DH signed_payload, server forwards as is
}

type SetEpochInput struct {
	Epoch         int
	MemberSetHash []byte
	Wraps         []WrapInput
	EnvelopeSig   []byte
}

// SetEpoch validates a rotation request and writes the ledger row + per
// recipient wraps in one tx via the repo. Role gate: admin or co-admin only
func (s *Service) SetEpoch(ctx context.Context, albumID uuid.UUID, callerToken []byte, callerRole string, in SetEpochInput) error {
	if callerRole != "admin" && callerRole != "co-admin" {
		return apierr.Forbidden("only admin or co-admin can rotate epoch")
	}
	if in.Epoch < 0 {
		return apierr.Validation("epoch must be >= 0")
	}
	if len(in.MemberSetHash) != sha256.Size {
		return apierr.Validation("member_set_hash must be 32 bytes")
	}
	if len(in.EnvelopeSig) != sigLen {
		return apierr.Validation("envelope_sig must be 64 bytes")
	}
	if len(in.Wraps) == 0 {
		return apierr.Validation("wraps must be a non-empty array")
	}
	for i, w := range in.Wraps {
		if len(w.RecipientToken) != tokenLen {
			return apierr.Validation("wraps[].recipient_token must be 32 bytes")
		}
		if len(w.EkPub) != keyLen {
			return apierr.Validation("wraps[].ek_pub must be 32 bytes")
		}
		if len(w.SenderSig) != sigLen {
			return apierr.Validation("wraps[].sender_sig must be 64 bytes")
		}
		if len(w.Wrap) < 1+gcmNonceLen+gcmTagLen {
			return apierr.Validation("wraps[].wrap is shorter than VER+NONCE+TAG")
		}
		if w.Wrap[0] != verAesGcm {
			return apierr.Validation("wraps[].wrap must start with VER=0x01 (AES-GCM)")
		}
		if w.OpkIdxUsed != nil && *w.OpkIdxUsed < 0 {
			return apierr.Validation("wraps[].opk_idx_used must be >= 0 when present")
		}
		// recipient_tokens must be unique within the request
		for j := range i {
			if bytes.Equal(in.Wraps[j].RecipientToken, w.RecipientToken) {
				return apierr.Validation("wraps[].recipient_token duplicated in request")
			}
		}
	}

	tokens := make([][]byte, len(in.Wraps))
	for i, w := range in.Wraps {
		tokens[i] = w.RecipientToken
	}
	if !bytes.Equal(MemberSetHash(tokens), in.MemberSetHash) {
		return apierr.Validation("member_set_hash does not match recipient_tokens")
	}

	wHash := WrapsHash(in.Wraps)
	signedMsg := EnvelopeSignMsg(albumID, in.Epoch, in.MemberSetHash, wHash)

	ikPub, err := s.repo.AdminIKByMemberToken(ctx, callerToken)
	if err != nil {
		if errors.Is(err, ErrAdminNotFound) {
			return apierr.IdentityNotSet("caller has no published identity")
		}
		return err
	}
	if err := crypto.VerifyEd25519(ed25519.PublicKey(ikPub), signedMsg, in.EnvelopeSig); err != nil {
		return apierr.SigInvalid("envelope_sig verification failed").WithCause(err)
	}

	wraps := make([]WrapInsert, len(in.Wraps))
	for i, w := range in.Wraps {
		wraps[i] = WrapInsert{
			RecipientToken: w.RecipientToken,
			EkPub:          w.EkPub,
			OpkIdxUsed:     w.OpkIdxUsed,
			WrapNonce:      w.Wrap[1 : 1+gcmNonceLen],
			WrapTagCT:      w.Wrap[1+gcmNonceLen:],
			SenderSig:      w.SenderSig,
		}
	}

	err = s.repo.InsertEpoch(ctx, InsertEpochInput{
		AlbumID:               albumID,
		Epoch:                 in.Epoch,
		EpochSig:              in.EnvelopeSig,
		SenderToken:           callerToken,
		Wraps:                 wraps,
		ExpectedMemberSetHash: in.MemberSetHash,
	})
	switch {
	case errors.Is(err, ErrEpochReplay):
		return apierr.EpochReplay("epoch must equal current+1")
	case errors.Is(err, ErrMemberSetDrift):
		return apierr.MemberSetDrift("active member set drifted between request and commit")
	case errors.Is(err, ErrAlbumNotFound):
		return apierr.NotFound("album not found")
	}
	return err
}

// CurrentResult is the shape the GET /epoch endpoint returns
type CurrentResult struct {
	CurrentEpoch int
	StartedAt    time.Time
	Exists       bool
}

func (s *Service) GetCurrent(ctx context.Context, albumID uuid.UUID) (*CurrentResult, error) {
	epoch, exists, started, err := s.repo.CurrentEpoch(ctx, albumID)
	if err != nil {
		return nil, err
	}
	return &CurrentResult{CurrentEpoch: epoch, StartedAt: started, Exists: exists}, nil
}

// GetWrap returns the recipient's own wrap. Caller must equal recipient_token
func (s *Service) GetWrap(ctx context.Context, albumID uuid.UUID, epoch int, callerToken []byte) (*Wrap, error) {
	if epoch < 0 {
		return nil, apierr.Validation("epoch must be >= 0")
	}
	w, err := s.repo.GetWrap(ctx, albumID, epoch, callerToken)
	if errors.Is(err, ErrWrapNotFound) {
		return nil, apierr.NotFound("no wrap at this epoch for this recipient")
	}
	return w, err
}

// MemberSetHash = SHA256( uint32_be(N) ‖ token_0 ‖ token_1 ‖ ... ‖ token_{N-1} )
// Tokens are sorted lexicographically before hashing : this is the canonical
// snapshot of "who must receive a wrap in this rotation". Length prefix
// guards against future token length changes
func MemberSetHash(tokens [][]byte) []byte {
	dup := make([][]byte, len(tokens))
	copy(dup, tokens)
	sort.Slice(dup, func(i, j int) bool { return bytes.Compare(dup[i], dup[j]) < 0 })
	h := sha256.New()
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(dup)))
	h.Write(n[:])
	for _, t := range dup {
		h.Write(t)
	}
	return h.Sum(nil)
}

// WrapsHash = SHA256( uint32_be(N)

//	‖ for each wrap (sorted by recipient_token):
//	    recipient_token (32B)
//	  ‖ ek_pub (32B)
//	  ‖ uint32_be(opk_idx; 0xFFFFFFFF if absent)
//	  ‖ uint32_be(len(wrap)) ‖ wrap
//	  ‖ uint32_be(len(sender_sig)) ‖ sender_sig )

// This binds the envelope_sig to every byte the server will persist
func WrapsHash(wraps []WrapInput) []byte {
	dup := make([]WrapInput, len(wraps))
	copy(dup, wraps)
	sort.Slice(dup, func(i, j int) bool {
		return bytes.Compare(dup[i].RecipientToken, dup[j].RecipientToken) < 0
	})
	h := sha256.New()
	var u32 [4]byte
	binary.BigEndian.PutUint32(u32[:], uint32(len(dup)))
	h.Write(u32[:])
	for _, w := range dup {
		h.Write(w.RecipientToken)
		h.Write(w.EkPub)
		var idx uint32 = 0xFFFFFFFF
		if w.OpkIdxUsed != nil {
			idx = uint32(*w.OpkIdxUsed)
		}
		binary.BigEndian.PutUint32(u32[:], idx)
		h.Write(u32[:])
		binary.BigEndian.PutUint32(u32[:], uint32(len(w.Wrap)))
		h.Write(u32[:])
		h.Write(w.Wrap)
		binary.BigEndian.PutUint32(u32[:], uint32(len(w.SenderSig)))
		h.Write(u32[:])
		h.Write(w.SenderSig)
	}
	return h.Sum(nil)
}

// EnvelopeSignMsg = "epoch-set-v1" ‖ album_id (16B) ‖ uint32_be(epoch)

//	‖ member_set_hash (32B) ‖ wraps_hash (32B)

// The album_id binary form is its 16-byte UUID, not the textual rendering
func EnvelopeSignMsg(albumID uuid.UUID, epoch int, memberSetHash, wrapsHash []byte) []byte {
	out := make([]byte, 0, len(crypto.SaltEpochSet)+16+4+32+32)
	out = append(out, crypto.SaltEpochSet...)
	out = append(out, albumID[:]...)
	var ep [4]byte
	binary.BigEndian.PutUint32(ep[:], uint32(epoch))
	out = append(out, ep[:]...)
	out = append(out, memberSetHash...)
	out = append(out, wrapsHash...)
	return out
}
