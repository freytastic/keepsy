package crypto

import (
	"bytes"
	"testing"
)

// expectedSalts is the canonical byte content of every L9 salt. The Dart side
// test asserts the same literal byte sequences. If either side diverges,
// every cross language signature/HKDF derivation breaks silently
var expectedSalts = map[string][]byte{
	"vault-x3dh-v1":    SaltX3dh,
	"invite-v1":        SaltInvite,
	"seg-nonce-v1":     SaltSegNonce,
	"key-confirm-v1":   SaltKeyConfirm,
	"manifest-v1":      SaltManifest,
	"rotate-spk-v1":    SaltSpkRotate,
	"promote-v1":       SaltPromote,
	"join-complete-v1": SaltJoinComplete,
	"album-name-v1":    SaltAlbumNameHint,
}

func TestSalts_MatchExpectedAsciiBytes(t *testing.T) {
	for ascii, got := range expectedSalts {
		if !bytes.Equal(got, []byte(ascii)) {
			t.Errorf("salt %q: got %v, want ASCII bytes of literal", ascii, got)
		}
	}
}

func TestVerConstants_FixedByteValues(t *testing.T) {
	if VerAesGcm != 0x01 {
		t.Errorf("VerAesGcm = 0x%02x, want 0x01", VerAesGcm)
	}
	if VerChaPo != 0x02 {
		t.Errorf("VerChaPo = 0x%02x, want 0x02", VerChaPo)
	}
	if VerStreamGcm != 0x03 {
		t.Errorf("VerStreamGcm = 0x%02x, want 0x03", VerStreamGcm)
	}
}

func TestSegmentSize_OneMebibyte(t *testing.T) {
	if SegmentSize != 1048576 {
		t.Errorf("SegmentSize = %d, want 1048576 (1 MiB)", SegmentSize)
	}
}

func TestX3dhInfo_HappyPath(t *testing.T) {
	lkA := bytes.Repeat([]byte{0x11}, LkPubLen)
	lkB := bytes.Repeat([]byte{0x22}, LkPubLen)
	album := bytes.Repeat([]byte{0x33}, AlbumIDLen)

	got, err := X3dhInfo(lkA, lkB, album)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != X3dhInfoLen {
		t.Fatalf("got len %d, want %d", len(got), X3dhInfoLen)
	}
	if !bytes.Equal(got[0:LkPubLen], lkA) {
		t.Error("first 32 bytes != lkA")
	}
	if !bytes.Equal(got[LkPubLen:2*LkPubLen], lkB) {
		t.Error("middle 32 bytes != lkB")
	}
	if !bytes.Equal(got[2*LkPubLen:X3dhInfoLen], album) {
		t.Error("last 16 bytes != album")
	}
}

func TestX3dhInfo_RejectsWrongSizes(t *testing.T) {
	good32 := make([]byte, 32)
	good16 := make([]byte, 16)

	for _, tc := range []struct {
		name        string
		a, b, album []byte
	}{
		{"lkA too short", make([]byte, 31), good32, good16},
		{"lkA too long", make([]byte, 33), good32, good16},
		{"lkB too short", good32, make([]byte, 31), good16},
		{"album too short", good32, good32, make([]byte, 15)},
		{"album too long", good32, good32, make([]byte, 17)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := X3dhInfo(tc.a, tc.b, tc.album); err == nil {
				t.Error("expected error, got nil")
			}
		})
	}
}
