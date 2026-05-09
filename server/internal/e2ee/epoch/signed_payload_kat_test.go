package epoch

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/freytastic/keepsy/internal/crypto"
)

// TestSignedPayloadKAT loads test_vectors/signed_payload_kat.json and asserts
// that the §4.2 D3 sender_sig msg + Ed25519_verify both agree byte for byte
// with the frozen fixture. Dart's mk_delivery_kat_test.dart pins the same JSON
func TestSignedPayloadKAT(t *testing.T) {
	path := filepath.Join("..", "..", "..", "test_vectors", "signed_payload_kat.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read kat: %v", err)
	}

	var doc struct {
		Category string `json:"category"`
		Vectors  []struct {
			Name           string `json:"name"`
			IKSeedHex      string `json:"ik_seed_hex"`
			AlbumIDHex     string `json:"album_id_hex"`
			Epoch          uint32 `json:"epoch"`
			WrapBlobHex    string `json:"wrap_blob_hex"`
			ExpectedMsgHex string `json:"expected_msg_hex"`
			ExpectedSigHex string `json:"expected_sig_hex"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("decode kat: %v", err)
	}
	if doc.Category != "signed_payload" {
		t.Fatalf("category = %q, want signed_payload", doc.Category)
	}
	if len(doc.Vectors) == 0 {
		t.Fatal("no vectors in fixture")
	}

	for _, v := range doc.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			seed := mustHexKAT(t, v.IKSeedHex)
			albumID := mustHexKAT(t, v.AlbumIDHex)
			wrap := mustHexKAT(t, v.WrapBlobHex)
			expectedSig := mustHexKAT(t, v.ExpectedSigHex)

			buf := make([]byte, 0, 16+4+61)
			buf = append(buf, albumID...)
			var ep [4]byte
			binary.BigEndian.PutUint32(ep[:], v.Epoch)
			buf = append(buf, ep[:]...)
			buf = append(buf, wrap...)
			gotMsg := crypto.SHA256(buf)

			if hex.EncodeToString(gotMsg[:]) != v.ExpectedMsgHex {
				t.Fatalf("msg mismatch\n got %x\nwant %s", gotMsg[:], v.ExpectedMsgHex)
			}

			priv := ed25519.NewKeyFromSeed(seed)
			pub := priv.Public().(ed25519.PublicKey)
			if err := crypto.VerifyEd25519(pub, gotMsg[:], expectedSig); err != nil {
				t.Fatalf("Ed25519_verify failed for %q: %v", v.Name, err)
			}
		})
	}
}

func mustHexKAT(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("hex.Decode(%q): %v", s, err)
	}
	return b
}
