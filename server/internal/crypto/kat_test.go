package crypto

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

// katFile is outside both the server/ and frontend/ trees so it just feeds
// both runners. it has to be in this path to sync with the Dart KAT loader
const katFile = "../../../test_vectors/crypto_kat.json"

type katVectors struct {
	AeadAesGcmDecrypt     []aeadVector          `json:"aead_aes_gcm_decrypt"`
	AeadChachaPolyDecrypt []aeadVector          `json:"aead_chacha_poly_decrypt"`
	HkdfSha256            []hkdfVector          `json:"hkdf_sha256"`
	X25519                []x25519Vector        `json:"x25519"`
	Ed25519               []ed25519Vector       `json:"ed25519"`
	X3dh4DH               []x3dhVector          `json:"x3dh_4dh"`
	X3dh3DH               []x3dhVector          `json:"x3dh_3dh"`
	SafetyNumbers         []safetyNumberVector  `json:"safety_numbers"`
	CanonicalJSON         []canonicalJSONVector `json:"canonical_json"`
}

type safetyNumberVector struct {
	Name       string `json:"name"`
	IkPubAHex  string `json:"ik_pub_a_hex"`
	IkPubBHex  string `json:"ik_pub_b_hex"`
	AlbumIDHex string `json:"album_id_hex"`
	Digits     string `json:"digits"`
}

type canonicalJSONVector struct {
	Name         string `json:"name"`
	InputJSON    string `json:"input_json"`
	ExpectedUTF8 string `json:"expected_utf8"`
}

type x3dhVector struct {
	Name            string `json:"name"`
	LkASeedHex      string `json:"lk_a_seed_hex"`
	EkASeedHex      string `json:"ek_a_seed_hex"`
	LkBSeedHex      string `json:"lk_b_seed_hex"`
	SpkBSeedHex     string `json:"spk_b_seed_hex"`
	OpkBSeedHex     string `json:"opk_b_seed_hex"` // empty for 3-DH
	AlbumIDHex      string `json:"album_id_hex"`
	LkAPubHex       string `json:"lk_a_pub_hex"`
	LkBPubHex       string `json:"lk_b_pub_hex"`
	EkAPubHex       string `json:"ek_a_pub_hex"`
	SpkBPubHex      string `json:"spk_b_pub_hex"`
	OpkBPubHex      string `json:"opk_b_pub_hex"` // empty for 3-DH
	SharedSecretHex string `json:"shared_secret_hex"`
}

type aeadVector struct {
	Name     string `json:"name"`
	KeyHex   string `json:"key_hex"`
	NonceHex string `json:"nonce_hex"`
	AadHex   string `json:"aad_hex"`
	CtHex    string `json:"ct_hex"`
	TagHex   string `json:"tag_hex"`
	PtHex    string `json:"pt_hex"`
}

type hkdfVector struct {
	Name    string `json:"name"`
	IkmHex  string `json:"ikm_hex"`
	SaltHex string `json:"salt_hex"`
	InfoHex string `json:"info_hex"`
	Length  int    `json:"length"`
	OkmHex  string `json:"okm_hex"`
}

type x25519Vector struct {
	Name      string `json:"name"`
	ScalarHex string `json:"scalar_hex"`
	UHex      string `json:"u_hex"`
	SharedHex string `json:"shared_hex"`
}

type ed25519Vector struct {
	Name      string `json:"name"`
	SeedHex   string `json:"seed_hex"`
	PubKeyHex string `json:"pubkey_hex"`
	MsgHex    string `json:"msg_hex"`
	SigHex    string `json:"sig_hex"`
}

func loadKatVectors(t *testing.T) *katVectors {
	t.Helper()
	abs, err := filepath.Abs(katFile)
	if err != nil {
		t.Fatalf("resolve kat path: %v", err)
	}
	f, err := os.Open(abs)
	if err != nil {
		t.Fatalf("open KAT file %q: %v", abs, err)
	}
	defer f.Close()
	var v katVectors
	if err := json.NewDecoder(f).Decode(&v); err != nil {
		t.Fatalf("decode KAT JSON: %v", err)
	}
	return &v
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("decode hex %q: %v", s, err)
	}
	return b
}

func TestKAT_AesGcmDecrypt(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.AeadAesGcmDecrypt {
		t.Run(tv.Name, func(t *testing.T) {
			block, err := aes.NewCipher(mustHex(t, tv.KeyHex))
			if err != nil {
				t.Fatal(err)
			}
			gcm, err := cipher.NewGCM(block)
			if err != nil {
				t.Fatal(err)
			}
			ct := append(mustHex(t, tv.CtHex), mustHex(t, tv.TagHex)...)
			pt, err := gcm.Open(nil, mustHex(t, tv.NonceHex), ct, mustHex(t, tv.AadHex))
			if err != nil {
				t.Fatalf("decrypt failed: %v", err)
			}
			if !bytes.Equal(pt, mustHex(t, tv.PtHex)) {
				t.Errorf("pt = %x, want %s", pt, tv.PtHex)
			}
		})
	}
}

func TestKAT_ChachaPolyDecrypt(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.AeadChachaPolyDecrypt {
		t.Run(tv.Name, func(t *testing.T) {
			aead, err := chacha20poly1305.New(mustHex(t, tv.KeyHex))
			if err != nil {
				t.Fatal(err)
			}
			ct := append(mustHex(t, tv.CtHex), mustHex(t, tv.TagHex)...)
			pt, err := aead.Open(nil, mustHex(t, tv.NonceHex), ct, mustHex(t, tv.AadHex))
			if err != nil {
				t.Fatalf("decrypt failed: %v", err)
			}
			if !bytes.Equal(pt, mustHex(t, tv.PtHex)) {
				t.Errorf("pt = %x, want %s", pt, tv.PtHex)
			}
		})
	}
}

func TestKAT_HkdfSha256(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.HkdfSha256 {
		t.Run(tv.Name, func(t *testing.T) {
			r := hkdf.New(sha256.New,
				mustHex(t, tv.IkmHex),
				mustHex(t, tv.SaltHex),
				mustHex(t, tv.InfoHex))
			out := make([]byte, tv.Length)
			if _, err := io.ReadFull(r, out); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(out, mustHex(t, tv.OkmHex)) {
				t.Errorf("okm = %x, want %s", out, tv.OkmHex)
			}
		})
	}
}

func TestKAT_X25519(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.X25519 {
		t.Run(tv.Name, func(t *testing.T) {
			out, err := curve25519.X25519(mustHex(t, tv.ScalarHex), mustHex(t, tv.UHex))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(out, mustHex(t, tv.SharedHex)) {
				t.Errorf("shared = %x, want %s", out, tv.SharedHex)
			}
		})
	}
}

func TestKAT_Ed25519(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.Ed25519 {
		t.Run(tv.Name, func(t *testing.T) {
			seed := mustHex(t, tv.SeedHex)
			priv := ed25519.NewKeyFromSeed(seed)
			pub := priv.Public().(ed25519.PublicKey)
			if !bytes.Equal(pub, mustHex(t, tv.PubKeyHex)) {
				t.Errorf("pubkey from seed = %x, want %s", pub, tv.PubKeyHex)
			}
			msg := mustHex(t, tv.MsgHex)
			sig := ed25519.Sign(priv, msg)
			if !bytes.Equal(sig, mustHex(t, tv.SigHex)) {
				t.Errorf("deterministic sig = %x, want %s", sig, tv.SigHex)
			}
			if err := VerifyEd25519(pub, msg, mustHex(t, tv.SigHex)); err != nil {
				t.Errorf("verify failed: %v", err)
			}
		})
	}
}

// runX3dhKat re derives the X3DH shared secret from the fixed seeds in the KAT
// and asserts it matches the frozen byte value. If the Dart side and Go side
// both pass on the same vector, byte-level X3DH parity holds
func runX3dhKat(t *testing.T, tv x3dhVector, withOpk bool) {
	t.Helper()
	lkASeed := mustHex(t, tv.LkASeedHex)
	ekASeed := mustHex(t, tv.EkASeedHex)
	lkBSeed := mustHex(t, tv.LkBSeedHex)
	spkBSeed := mustHex(t, tv.SpkBSeedHex)
	albumID := mustHex(t, tv.AlbumIDHex)

	dh := func(scalar, peer []byte) []byte {
		out, err := curve25519.X25519(scalar, peer)
		if err != nil {
			t.Fatalf("x25519: %v", err)
		}
		return out
	}
	pub := func(scalar []byte) []byte { return dh(scalar, curve25519.Basepoint) }

	// Pubkey parity : seed→pub must match the frozen pub bytes
	if got, want := pub(lkASeed), mustHex(t, tv.LkAPubHex); !bytes.Equal(got, want) {
		t.Fatalf("lk_a pub: got %x, want %s", got, tv.LkAPubHex)
	}
	if got, want := pub(lkBSeed), mustHex(t, tv.LkBPubHex); !bytes.Equal(got, want) {
		t.Fatalf("lk_b pub: got %x, want %s", got, tv.LkBPubHex)
	}

	lkAPub := pub(lkASeed)
	ekAPub := pub(ekASeed)
	lkBPub := pub(lkBSeed)
	spkBPub := pub(spkBSeed)

	// Initiator and responder must produce identical KMs : verify both paths
	dh1A := dh(lkASeed, spkBPub)
	dh2A := dh(ekASeed, lkBPub)
	dh3A := dh(ekASeed, spkBPub)
	dh1B := dh(spkBSeed, lkAPub)
	dh2B := dh(lkBSeed, ekAPub)
	dh3B := dh(spkBSeed, ekAPub)
	if !bytes.Equal(dh1A, dh1B) || !bytes.Equal(dh2A, dh2B) || !bytes.Equal(dh3A, dh3B) {
		t.Fatal("initiator/responder DH outputs disagree (DH1..DH3)")
	}

	km := append(append(append([]byte{}, dh1A...), dh2A...), dh3A...)
	if withOpk {
		opkBSeed := mustHex(t, tv.OpkBSeedHex)
		opkBPub := pub(opkBSeed)
		dh4A := dh(ekASeed, opkBPub)
		dh4B := dh(opkBSeed, ekAPub)
		if !bytes.Equal(dh4A, dh4B) {
			t.Fatal("initiator/responder DH4 disagree")
		}
		km = append(km, dh4A...)
	}

	info, err := X3dhInfo(lkAPub, lkBPub, albumID)
	if err != nil {
		t.Fatalf("X3dhInfo: %v", err)
	}
	r := hkdf.New(sha256.New, km, SaltX3dh, info)
	got := make([]byte, 32)
	if _, err := io.ReadFull(r, got); err != nil {
		t.Fatal(err)
	}
	if want := mustHex(t, tv.SharedSecretHex); !bytes.Equal(got, want) {
		t.Errorf("shared = %x, want %s", got, tv.SharedSecretHex)
	}
}

func TestKAT_X3DH_4DH(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.X3dh4DH {
		t.Run(tv.Name, func(t *testing.T) { runX3dhKat(t, tv, true) })
	}
}

func TestKAT_X3DH_3DH(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.X3dh3DH {
		t.Run(tv.Name, func(t *testing.T) { runX3dhKat(t, tv, false) })
	}
}

func TestKAT_SafetyNumber(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.SafetyNumbers {
		t.Run(tv.Name, func(t *testing.T) {
			got, err := SafetyNumber(
				mustHex(t, tv.IkPubAHex),
				mustHex(t, tv.IkPubBHex),
				mustHex(t, tv.AlbumIDHex),
			)
			if err != nil {
				t.Fatal(err)
			}
			if got != tv.Digits {
				t.Errorf("digits = %s, want %s", got, tv.Digits)
			}
		})
	}
}

func TestKAT_CanonicalJSON(t *testing.T) {
	v := loadKatVectors(t)
	for _, tv := range v.CanonicalJSON {
		t.Run(tv.Name, func(t *testing.T) {
			var parsed any
			if err := json.Unmarshal([]byte(tv.InputJSON), &parsed); err != nil {
				t.Fatalf("parse input: %v", err)
			}
			// json.Unmarshal returns float64 for all JSON numbers : convert
			// integer-valued floats back to int64 so the canonical serializer
			// does not reject them
			parsed = floatsToInts(parsed)
			got, err := CanonicalSerialize(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tv.ExpectedUTF8 {
				t.Errorf("got %q, want %q", string(got), tv.ExpectedUTF8)
			}
		})
	}
}

// floatsToInts walks a parsed JSON tree and converts integer-valued float64
// (the only number type encoding/json produces by default) to int64. Callers
// of CanonicalSerialize in production pass typed structs, so this is a test
// helper only : the canonical serializer itself rejects floats by design
func floatsToInts(v any) any {
	switch x := v.(type) {
	case float64:
		i := int64(x)
		if float64(i) == x {
			return i
		}
		return x
	case []any:
		for i, e := range x {
			x[i] = floatsToInts(e)
		}
		return x
	case map[string]any:
		for k, e := range x {
			x[k] = floatsToInts(e)
		}
		return x
	default:
		return v
	}
}
