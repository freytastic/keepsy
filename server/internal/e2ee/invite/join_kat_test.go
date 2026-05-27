package invite

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
)

// TestJoinCompleteKAT pins JoinCompleteMsg + Ed25519 against the shared fixture
// so the Go and Dart sides can never silently diverge
func TestJoinCompleteKAT(t *testing.T) {
	path := filepath.Join("..", "..", "..", "test_vectors", "join_complete_kat.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var k struct {
		Vectors []struct {
			Name           string `json:"name"`
			IKSeedHex      string `json:"ik_seed_hex"`
			AlbumIDHex     string `json:"album_id_hex"`
			Epoch          uint32 `json:"epoch"`
			EkPubAdminHex  string `json:"ek_pub_admin_hex"`
			ExpectedMsgHex string `json:"expected_msg_hex"`
			ExpectedSigHex string `json:"expected_sig_hex"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(k.Vectors) == 0 {
		t.Fatal("fixture has no vectors")
	}
	for _, v := range k.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			albumBytes := mustHexJK(t, v.AlbumIDHex)
			albumID, err := uuid.FromBytes(albumBytes)
			if err != nil {
				t.Fatal(err)
			}
			msg := JoinCompleteMsg(albumID, int(v.Epoch), mustHexJK(t, v.EkPubAdminHex))
			if got := hex.EncodeToString(msg); got != v.ExpectedMsgHex {
				t.Fatalf("msg = %s, want %s", got, v.ExpectedMsgHex)
			}
			priv := ed25519.NewKeyFromSeed(mustHexJK(t, v.IKSeedHex))
			sig := ed25519.Sign(priv, msg)
			if got := hex.EncodeToString(sig); got != v.ExpectedSigHex {
				t.Fatalf("sig = %s, want %s", got, v.ExpectedSigHex)
			}
		})
	}
}

func mustHexJK(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("hex %q: %v", s, err)
	}
	return b
}
