package crypto

import "fmt"

// Wire format version bytes (D5). Mirrored in lib/crypto/wire_format.dart
const (
	VerAesGcm    byte = 0x01
	VerChaPo     byte = 0x02
	VerStreamGcm byte = 0x03

	// SegmentSize is the chunk size for VER=0x03 streaming AEAD: 1 MiB (L2)
	SegmentSize = 1 << 20

	// X3DH input lengths (L1)
	IkPubLen    = 32
	LkPubLen    = 32
	AlbumIDLen  = 16
	X3dhInfoLen = LkPubLen + LkPubLen + AlbumIDLen
)

// X3dhInfo builds the HKDF info string per L1: LK_pub_A || LK_pub_B || album_id
// Uses LK_pub (the actual X25519 keys participating in DH1), never IK_pub
func X3dhInfo(lkPubA, lkPubB, albumID []byte) ([]byte, error) {
	if len(lkPubA) != LkPubLen {
		return nil, fmt.Errorf("crypto: lkPubA must be %d bytes, got %d", LkPubLen, len(lkPubA))
	}
	if len(lkPubB) != LkPubLen {
		return nil, fmt.Errorf("crypto: lkPubB must be %d bytes, got %d", LkPubLen, len(lkPubB))
	}
	if len(albumID) != AlbumIDLen {
		return nil, fmt.Errorf("crypto: albumID must be %d bytes (raw UUID), got %d", AlbumIDLen, len(albumID))
	}
	out := make([]byte, X3dhInfoLen)
	copy(out[0:LkPubLen], lkPubA)
	copy(out[LkPubLen:2*LkPubLen], lkPubB)
	copy(out[2*LkPubLen:X3dhInfoLen], albumID)
	return out, nil
}
