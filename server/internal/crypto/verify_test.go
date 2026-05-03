package crypto

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestVerifyEd25519_ValidSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("test message")
	sig := ed25519.Sign(priv, msg)
	if err := VerifyEd25519(pub, msg, sig); err != nil {
		t.Errorf("expected valid, got: %v", err)
	}
}

func TestVerifyEd25519_RejectsTamperedMessage(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	sig := ed25519.Sign(priv, []byte("original"))
	if err := VerifyEd25519(pub, []byte("tampered"), sig); err == nil {
		t.Error("expected error on tampered message, got nil")
	}
}

func TestVerifyEd25519_RejectsTamperedSignature(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msg := []byte("test")
	sig := ed25519.Sign(priv, msg)
	sig[0] ^= 0x01
	if err := VerifyEd25519(pub, msg, sig); err == nil {
		t.Error("expected error on tampered signature, got nil")
	}
}

func TestVerifyEd25519_RejectsWrongSizeKey(t *testing.T) {
	if err := VerifyEd25519(make([]byte, 31), nil, make([]byte, 64)); err == nil {
		t.Error("expected error for wrong key size")
	}
}

func TestVerifyEd25519_RejectsWrongSizeSig(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := VerifyEd25519(pub, nil, make([]byte, 63)); err == nil {
		t.Error("expected error for wrong signature size")
	}
}

// SHA-256("") test vector from FIPS 180-4 Appendix B
func TestSHA256_EmptyVector(t *testing.T) {
	got := SHA256(nil)
	want := [32]byte{
		0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
		0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
		0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
		0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
	}
	if got != want {
		t.Errorf("SHA256(\"\") = %x, want %x", got, want)
	}
}

// SHA-256("abc") test vector from FIPS 180-4 Appendix B
func TestSHA256_AbcVector(t *testing.T) {
	got := SHA256([]byte("abc"))
	want := [32]byte{
		0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
		0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
		0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
		0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
	}
	if got != want {
		t.Errorf("SHA256(\"abc\") = %x, want %x", got, want)
	}
}

func TestConstantTimeEq(t *testing.T) {
	tests := []struct {
		name   string
		a, b   []byte
		expect bool
	}{
		{"equal", []byte{1, 2, 3}, []byte{1, 2, 3}, true},
		{"different content", []byte{1, 2, 3}, []byte{1, 2, 4}, false},
		{"different length", []byte{1, 2, 3}, []byte{1, 2}, false},
		{"both empty", []byte{}, []byte{}, true},
		{"one empty", []byte{}, []byte{1}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ConstantTimeEq(tc.a, tc.b); got != tc.expect {
				t.Errorf("got %v, want %v", got, tc.expect)
			}
		})
	}
}
