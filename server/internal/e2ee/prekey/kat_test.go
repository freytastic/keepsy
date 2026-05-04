package prekey

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestSpkRotateKAT loads test_vectors/spk_rotate_kat.json and asserts that the
// service's RotationMsg + Ed25519_verify both agree byte-for-byte with the
// frozen fixture. Dart's kat_test.dart pins the same JSON
func TestSpkRotateKAT(t *testing.T) {
	path := filepath.Join("..", "..", "..", "test_vectors", "spk_rotate_kat.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read kat: %v", err)
	}

	var doc struct {
		Category string `json:"category"`
		Vectors  []struct {
			Name                string `json:"name"`
			IKSeedHex           string `json:"ik_seed"`
			SPKPubHex           string `json:"spk_pub"`
			SPKTs               int64  `json:"spk_ts"`
			ExpectedMsgHex      string `json:"expected_msg"`
			ExpectedRotationSig string `json:"expected_rotation_sig"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("decode kat: %v", err)
	}
	if doc.Category != "spk_rotate" {
		t.Fatalf("category = %q, want spk_rotate", doc.Category)
	}
	if len(doc.Vectors) == 0 {
		t.Fatal("no vectors in fixture")
	}

	for _, v := range doc.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			seed := mustHex(t, v.IKSeedHex)
			spkPub := mustHex(t, v.SPKPubHex)
			expectedMsg := mustHex(t, v.ExpectedMsgHex)
			expectedSig := mustHex(t, v.ExpectedRotationSig)

			gotMsg := RotationMsg(spkPub, v.SPKTs)
			if hex.EncodeToString(gotMsg) != v.ExpectedMsgHex {
				t.Fatalf("RotationMsg mismatch\n got %x\nwant %x", gotMsg, expectedMsg)
			}

			priv := ed25519.NewKeyFromSeed(seed)
			pub := priv.Public().(ed25519.PublicKey)
			if !ed25519.Verify(pub, gotMsg, expectedSig) {
				t.Fatalf("Ed25519_verify failed for %q", v.Name)
			}
		})
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("hex.Decode(%q): %v", s, err)
	}
	return b
}
