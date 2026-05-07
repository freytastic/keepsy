// Package crypto holds the server side mirror of the cryptographic constants
// and verifier helpers. The server never decrypts : it only verifies signatures
// and hashes. Every byte here must match Dart's lib/crypto/ exactly
package crypto

// Domain separation salts (L9). Byte-for-byte mirror of the Dart side
// KAT parity tests assert these match what Dart computes from utf8.encode(...).
var (
	SaltX3dh          = []byte("vault-x3dh-v1")
	SaltInvite        = []byte("invite-v1")
	SaltSegNonce      = []byte("seg-nonce-v1")
	SaltKeyConfirm    = []byte("key-confirm-v1")
	SaltManifest      = []byte("manifest-v1")
	SaltSpkRotate     = []byte("rotate-spk-v1")
	SaltEpochSet      = []byte("epoch-set-v1")
	SaltPromote       = []byte("promote-v1")
	SaltJoinComplete  = []byte("join-complete-v1")
	SaltAlbumNameHint = []byte("album-name-v1")
)
