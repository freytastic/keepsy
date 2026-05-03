package crypto

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
)

// VerifyEd25519 returns nil if sig is a valid Ed25519 signature of msg under pub
// Rejects malformed inputs explicitly so callers dont conflate "wrong sig" with
// "wrong key length ":  both flow through the same APIError envelope upstream
func VerifyEd25519(pub ed25519.PublicKey, msg, sig []byte) error {
	if len(pub) != ed25519.PublicKeySize {
		return errors.New("crypto: Ed25519 public key must be 32 bytes")
	}
	if len(sig) != ed25519.SignatureSize {
		return errors.New("crypto: Ed25519 signature must be 64 bytes")
	}
	if !ed25519.Verify(pub, msg, sig) {
		return errors.New("crypto: Ed25519 signature verification failed")
	}
	return nil
}

// SHA256 returns the SHA-256 digest of b
func SHA256(b []byte) [32]byte {
	return sha256.Sum256(b)
}

// ConstantTimeEq reports whether a and b are byte equal in constant time
// Different length inputs return false (constant time over the shorter prefix
// is not what callers want when comparing tags / hashes)
func ConstantTimeEq(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare(a, b) == 1
}
