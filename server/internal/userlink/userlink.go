// Package userlink severs the static link between user_id and member_token
// in album_member_identities. Two derived secrets cover the two access patterns

//   - Hash(user_id) -> deterministic 32B handle. Indexed in amid.user_handle :
//     used for forward queries ("find all albums for this user", "is this user
//     a member of this album"). HMAC-SHA256, one way : reversing it is brute
//     forcing every UUID

//   - Seal(user_id, member_token) -> reversible 32B blob. Stored in
//     amid.user_id_enc : used for reverse queries ("which user_id owns this
//     member_token" , needed by WS fanout + epoch admin IK lookup). AES-256-GCM
//     with a deterministic nonce derived from member_token (which is itself
//     32B CSPRNG, so each row's nonce is unique by construction)

// Both subkeys are HKDF-derived from KEEPSY_USER_LINK_KEY so one env var covers
// both purposes without key reuse. A leaked DB snapshot is useless without the
// live key (HMAC reversal infeasible : AEAD undecryptable). A live compromised
// server still has the key , this is "encryption at rest" for the bridge, not
// zero knowledge
package userlink

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
	"golang.org/x/crypto/hkdf"
)

const (
	// HandleLen : SHA-256 output, fixed
	HandleLen = 32
	// SealedLen : AES-GCM(16B plaintext) = 16B ct + 16B tag = 32B fixed
	SealedLen = 32
)

// info strings for HKDF subkey derivation. Changing either bricks every
// existing row that was sealed under the old subkey
var (
	infoHandle = []byte("user-handle-v1")
	infoEnc    = []byte("user-id-enc-v1")
	// nonce is derived from member_token via SHA256 : the prefix domain
	// separates this nonce from any other use of the member_token bytes
	nonceInfo = []byte("user-id-enc-nonce-v1")
)

type Hasher struct {
	handleKey []byte // 32B for HMAC-SHA256
	gcm       cipher.AEAD
}

// New constructs a Hasher from the master key. Panics on a short key : this
// runs once at startup so a panic surfaces immediately. Returns nil if HKDF
// or AES setup fails (should never happen with a 32B+ key)
func New(masterKey []byte) (*Hasher, error) {
	if len(masterKey) < 32 {
		return nil, errors.New("userlink: master key must be >= 32 bytes")
	}
	handleKey := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, masterKey, nil, infoHandle), handleKey); err != nil {
		return nil, fmt.Errorf("userlink: derive handle key: %w", err)
	}
	encKey := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, masterKey, nil, infoEnc), encKey); err != nil {
		return nil, fmt.Errorf("userlink: derive enc key: %w", err)
	}
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, fmt.Errorf("userlink: aes new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("userlink: aes-gcm: %w", err)
	}
	return &Hasher{handleKey: handleKey, gcm: gcm}, nil
}

// Hash returns the 32B deterministic handle for user_id. Same input always
// yields the same output (required for indexed lookups)
func (h *Hasher) Hash(userID uuid.UUID) []byte {
	mac := hmac.New(sha256.New, h.handleKey)
	mac.Write(userID[:])
	return mac.Sum(nil)
}

// Seal returns the encrypted user_id blob for storage in amid.user_id_enc
// Nonce is derived from member_token : the input must be at least 12 bytes of
// CSPRNG output (member_token is 32B random by construction). Two rows with
// the same member_token would reuse the same nonce, but member_token is a PK
// so duplicates are structurally impossible
func (h *Hasher) Seal(userID uuid.UUID, memberToken []byte) ([]byte, error) {
	if len(memberToken) < 12 {
		return nil, errors.New("userlink: memberToken must be >= 12 bytes")
	}
	nonce := deriveNonce(memberToken)
	return h.gcm.Seal(nil, nonce, userID[:], nil), nil
}

// Open reverses Seal. Returns ErrInvalidSeal if the ciphertext doesnt verify
// (corrupt row, wrong key, or wrong member_token)
func (h *Hasher) Open(sealed, memberToken []byte) (uuid.UUID, error) {
	if len(memberToken) < 12 {
		return uuid.Nil, errors.New("userlink: memberToken must be >= 12 bytes")
	}
	nonce := deriveNonce(memberToken)
	pt, err := h.gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return uuid.Nil, ErrInvalidSeal
	}
	if len(pt) != 16 {
		return uuid.Nil, ErrInvalidSeal
	}
	var u uuid.UUID
	copy(u[:], pt)
	return u, nil
}

var ErrInvalidSeal = errors.New("userlink: invalid sealed user_id")

func deriveNonce(memberToken []byte) []byte {
	h := sha256.New()
	h.Write(nonceInfo)
	h.Write(memberToken)
	sum := h.Sum(nil)
	return sum[:12]
}
