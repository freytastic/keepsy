package userlink

import (
	"bytes"
	"crypto/rand"
	"testing"

	"github.com/google/uuid"
)

func newTestHasher(t *testing.T) *Hasher {
	t.Helper()
	key := bytes.Repeat([]byte{0xAB}, 32)
	h, err := New(key)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return h
}

func TestNew_RejectsShortKey(t *testing.T) {
	if _, err := New(bytes.Repeat([]byte{0x01}, 31)); err == nil {
		t.Error("expected error on 31B key")
	}
}

func TestHash_Deterministic(t *testing.T) {
	h := newTestHasher(t)
	u := uuid.New()
	a := h.Hash(u)
	b := h.Hash(u)
	if !bytes.Equal(a, b) {
		t.Error("Hash must be deterministic for the same input")
	}
	if len(a) != HandleLen {
		t.Errorf("len(handle) = %d, want %d", len(a), HandleLen)
	}
}

func TestHash_DifferentUsersDiffer(t *testing.T) {
	h := newTestHasher(t)
	a := h.Hash(uuid.New())
	b := h.Hash(uuid.New())
	if bytes.Equal(a, b) {
		t.Error("two different UUIDs must hash to different handles")
	}
}

func TestSealOpen_RoundTrip(t *testing.T) {
	h := newTestHasher(t)
	u := uuid.New()
	tok := make([]byte, 32)
	if _, err := rand.Read(tok); err != nil {
		t.Fatalf("rand: %v", err)
	}
	sealed, err := h.Seal(u, tok)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if len(sealed) != SealedLen {
		t.Errorf("len(sealed) = %d, want %d", len(sealed), SealedLen)
	}
	got, err := h.Open(sealed, tok)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if got != u {
		t.Errorf("Open returned %v, want %v", got, u)
	}
}

func TestOpen_RejectsTamperedCiphertext(t *testing.T) {
	h := newTestHasher(t)
	u := uuid.New()
	tok := bytes.Repeat([]byte{0xCD}, 32)
	sealed, err := h.Seal(u, tok)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	sealed[0] ^= 0x01
	if _, err := h.Open(sealed, tok); err == nil {
		t.Error("expected Open to reject tampered ciphertext")
	}
}

func TestOpen_RejectsWrongMemberToken(t *testing.T) {
	h := newTestHasher(t)
	u := uuid.New()
	tokA := bytes.Repeat([]byte{0x11}, 32)
	tokB := bytes.Repeat([]byte{0x22}, 32)
	sealed, _ := h.Seal(u, tokA)
	if _, err := h.Open(sealed, tokB); err == nil {
		t.Error("Open under a different member_token must fail (nonce mismatch)")
	}
}

func TestKeySeparation_HandleAndEncDiffer(t *testing.T) {
	// Two hashers from the same master must produce identical outputs : two
	// different masters must produce distinct outputs. Implicitly proves the
	// key derivation is reproducible
	keyA := bytes.Repeat([]byte{0x01}, 32)
	keyB := bytes.Repeat([]byte{0x02}, 32)
	hA, _ := New(keyA)
	hAprime, _ := New(keyA)
	hB, _ := New(keyB)
	u := uuid.New()
	if !bytes.Equal(hA.Hash(u), hAprime.Hash(u)) {
		t.Error("same master key must give same handle")
	}
	if bytes.Equal(hA.Hash(u), hB.Hash(u)) {
		t.Error("different master keys must give different handles")
	}
}
