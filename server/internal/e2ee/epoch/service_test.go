package epoch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/google/uuid"
)

type mockStore struct {
	currentEpochFn         func(ctx context.Context, albumID uuid.UUID) (int, bool, time.Time, error)
	adminIKByMemberTokenFn func(ctx context.Context, memberToken []byte) ([]byte, error)
	insertEpochFn          func(ctx context.Context, in InsertEpochInput) error
	getWrapFn              func(ctx context.Context, albumID uuid.UUID, epoch int, recipient []byte) (*Wrap, error)
}

func (m *mockStore) CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, bool, time.Time, error) {
	return m.currentEpochFn(ctx, albumID)
}
func (m *mockStore) AdminIKByMemberToken(ctx context.Context, t []byte) ([]byte, error) {
	return m.adminIKByMemberTokenFn(ctx, t)
}
func (m *mockStore) InsertEpoch(ctx context.Context, in InsertEpochInput) error {
	return m.insertEpochFn(ctx, in)
}
func (m *mockStore) GetWrap(ctx context.Context, albumID uuid.UUID, epoch int, recipient []byte) (*Wrap, error) {
	return m.getWrapFn(ctx, albumID, epoch, recipient)
}

// fixture builds a deterministic-ish admin (pub, priv) and a recipient token
type fixture struct {
	adminPub  ed25519.PublicKey
	adminPriv ed25519.PrivateKey
	albumID   uuid.UUID
	caller    []byte
	recip     []byte
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey: %v", err)
	}
	caller := make([]byte, tokenLen)
	recip := make([]byte, tokenLen)
	for i := range caller {
		caller[i] = byte(0xAA)
		recip[i] = byte(0xBB)
	}
	return &fixture{
		adminPub:  pub,
		adminPriv: priv,
		albumID:   uuid.New(),
		caller:    caller,
		recip:     recip,
	}
}

// validRequest builds a SetEpochInput with one wrap to the recipient + a valid
// envelope_sig over (album_id ‖ epoch ‖ member_set_hash ‖ wraps_hash)
func (f *fixture) validRequest(t *testing.T, epoch int) SetEpochInput {
	t.Helper()
	wrapBlob := append([]byte{verAesGcm}, bytes.Repeat([]byte{0x11}, gcmNonceLen)...)
	wrapBlob = append(wrapBlob, bytes.Repeat([]byte{0x22}, gcmTagLen+32)...) // tag+ct = 16+32

	ek := bytes.Repeat([]byte{0x33}, keyLen)
	senderSig := bytes.Repeat([]byte{0x44}, sigLen)
	wraps := []WrapInput{{
		RecipientToken: f.recip,
		EkPub:          ek,
		Wrap:           wrapBlob,
		SenderSig:      senderSig,
	}}
	tokens := [][]byte{f.recip}
	memHash := MemberSetHash(tokens)
	wHash := WrapsHash(wraps)
	msg := EnvelopeSignMsg(f.albumID, epoch, memHash, wHash)
	envSig := ed25519.Sign(f.adminPriv, msg)

	return SetEpochInput{
		Epoch:         epoch,
		MemberSetHash: memHash,
		Wraps:         wraps,
		EnvelopeSig:   envSig,
	}
}

func okStore(f *fixture) *mockStore {
	return &mockStore{
		adminIKByMemberTokenFn: func(_ context.Context, _ []byte) ([]byte, error) {
			return []byte(f.adminPub), nil
		},
		insertEpochFn: func(_ context.Context, _ InsertEpochInput) error { return nil },
	}
}

func TestSetEpoch_RejectsNonAdmin(t *testing.T) {
	f := newFixture(t)
	svc := NewService(okStore(f))
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "member", f.validRequest(t, 0))
	if !apierr.IsCode(err, "E_FORBIDDEN") {
		t.Fatalf("err = %v, want E_FORBIDDEN", err)
	}
}

func TestSetEpoch_AcceptsAdminAndCoAdmin(t *testing.T) {
	f := newFixture(t)
	for _, role := range []string{"admin", "co-admin"} {
		var called bool
		store := okStore(f)
		store.insertEpochFn = func(_ context.Context, _ InsertEpochInput) error {
			called = true
			return nil
		}
		svc := NewService(store)
		if err := svc.SetEpoch(context.Background(), f.albumID, f.caller, role, f.validRequest(t, 0)); err != nil {
			t.Fatalf("role=%s: err = %v", role, err)
		}
		if !called {
			t.Fatalf("role=%s: InsertEpoch not called", role)
		}
	}
}

func TestSetEpoch_RejectsTamperedEnvelopeSig(t *testing.T) {
	f := newFixture(t)
	svc := NewService(okStore(f))
	in := f.validRequest(t, 0)
	in.EnvelopeSig = bytes.Clone(in.EnvelopeSig)
	in.EnvelopeSig[0] ^= 0x01
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", in)
	if !apierr.IsCode(err, "E_SIG_INVALID") {
		t.Fatalf("err = %v, want E_SIG_INVALID", err)
	}
}

func TestSetEpoch_RejectsBadMemberSetHash(t *testing.T) {
	f := newFixture(t)
	svc := NewService(okStore(f))
	in := f.validRequest(t, 0)
	in.MemberSetHash = bytes.Repeat([]byte{0xDE}, 32) // doesnt match recipients
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", in)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestSetEpoch_RejectsBadVERPrefix(t *testing.T) {
	f := newFixture(t)
	svc := NewService(okStore(f))
	in := f.validRequest(t, 0)
	in.Wraps[0].Wrap[0] = 0x02 // VER=0x02 (chacha) not allowed for MK wraps (where i belong 'chacha' also means uncle)
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", in)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestSetEpoch_RejectsDuplicateRecipient(t *testing.T) {
	f := newFixture(t)
	svc := NewService(okStore(f))
	in := f.validRequest(t, 0)
	in.Wraps = append(in.Wraps, in.Wraps[0]) // duplicate
	// member_set_hash + envelope_sig were computed on the original 1 wrap form
	// so this fails on the duplicate check before getting to sig verify
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", in)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestSetEpoch_TranslatesEpochReplay(t *testing.T) {
	f := newFixture(t)
	store := okStore(f)
	store.insertEpochFn = func(_ context.Context, _ InsertEpochInput) error {
		return ErrEpochReplay
	}
	svc := NewService(store)
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", f.validRequest(t, 5))
	if !apierr.IsCode(err, "E_EPOCH_REPLAY") {
		t.Fatalf("err = %v, want E_EPOCH_REPLAY", err)
	}
}

func TestSetEpoch_TranslatesMemberSetDrift(t *testing.T) {
	f := newFixture(t)
	store := okStore(f)
	store.insertEpochFn = func(_ context.Context, _ InsertEpochInput) error {
		return ErrMemberSetDrift
	}
	svc := NewService(store)
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", f.validRequest(t, 0))
	if !apierr.IsCode(err, "E_MEMBER_SET_DRIFT") {
		t.Fatalf("err = %v, want E_MEMBER_SET_DRIFT", err)
	}
}

func TestSetEpoch_AdminWithoutIdentity(t *testing.T) {
	f := newFixture(t)
	store := okStore(f)
	store.adminIKByMemberTokenFn = func(_ context.Context, _ []byte) ([]byte, error) {
		return nil, ErrAdminNotFound
	}
	svc := NewService(store)
	err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", f.validRequest(t, 0))
	if !apierr.IsCode(err, "E_IDENTITY_NOT_SET") {
		t.Fatalf("err = %v, want E_IDENTITY_NOT_SET", err)
	}
}

func TestSetEpoch_PassesCorrectInsertInput(t *testing.T) {
	f := newFixture(t)
	var captured InsertEpochInput
	store := okStore(f)
	store.insertEpochFn = func(_ context.Context, in InsertEpochInput) error {
		captured = in
		return nil
	}
	svc := NewService(store)
	in := f.validRequest(t, 7)
	if err := svc.SetEpoch(context.Background(), f.albumID, f.caller, "admin", in); err != nil {
		t.Fatalf("err = %v", err)
	}
	if captured.AlbumID != f.albumID {
		t.Errorf("AlbumID mismatch")
	}
	if captured.Epoch != 7 {
		t.Errorf("Epoch = %d, want 7", captured.Epoch)
	}
	if !bytes.Equal(captured.SenderToken, f.caller) {
		t.Errorf("SenderToken mismatch")
	}
	if !bytes.Equal(captured.ExpectedMemberSetHash, in.MemberSetHash) {
		t.Errorf("ExpectedMemberSetHash mismatch")
	}
	if len(captured.Wraps) != 1 {
		t.Fatalf("len(Wraps) = %d, want 1", len(captured.Wraps))
	}
	w := captured.Wraps[0]
	if !bytes.Equal(w.RecipientToken, f.recip) {
		t.Errorf("RecipientToken mismatch")
	}
	if len(w.WrapNonce) != gcmNonceLen {
		t.Errorf("WrapNonce len = %d, want 12", len(w.WrapNonce))
	}
	// tag+ct: original blob is 1 (VER) + 12 (NONCE) + 16 (TAG) + 32 (CT) = 61
	if want := gcmTagLen + 32; len(w.WrapTagCT) != want {
		t.Errorf("WrapTagCT len = %d, want %d", len(w.WrapTagCT), want)
	}
}

func TestMemberSetHash_OrderIndependent(t *testing.T) {
	a := []byte{0x01, 0x02}
	b := []byte{0x03, 0x04}
	h1 := MemberSetHash([][]byte{a, b})
	h2 := MemberSetHash([][]byte{b, a})
	if !bytes.Equal(h1, h2) {
		t.Errorf("hash differs by input order: %x vs %x", h1, h2)
	}
}

func TestWrapsHash_OrderIndependent(t *testing.T) {
	mk := func(recip byte) WrapInput {
		return WrapInput{
			RecipientToken: bytes.Repeat([]byte{recip}, tokenLen),
			EkPub:          bytes.Repeat([]byte{0x01}, keyLen),
			Wrap:           append([]byte{verAesGcm}, bytes.Repeat([]byte{0x02}, gcmNonceLen+gcmTagLen+32)...),
			SenderSig:      bytes.Repeat([]byte{0x03}, sigLen),
		}
	}
	a := mk(0xAA)
	b := mk(0xBB)
	h1 := WrapsHash([]WrapInput{a, b})
	h2 := WrapsHash([]WrapInput{b, a})
	if !bytes.Equal(h1, h2) {
		t.Errorf("hash differs by input order: %x vs %x", h1, h2)
	}
}

func TestGetWrap_TranslatesNotFound(t *testing.T) {
	f := newFixture(t)
	store := &mockStore{
		getWrapFn: func(_ context.Context, _ uuid.UUID, _ int, _ []byte) (*Wrap, error) {
			return nil, ErrWrapNotFound
		},
	}
	svc := NewService(store)
	_, err := svc.GetWrap(context.Background(), f.albumID, 3, f.caller)
	if !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
}

func TestGetWrap_RejectsNegativeEpoch(t *testing.T) {
	f := newFixture(t)
	svc := NewService(&mockStore{})
	_, err := svc.GetWrap(context.Background(), f.albumID, -1, f.caller)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

// sentinel: confirms the package's exported sentinels are distinct so
// errors.Is in the service layer maps each to the correct apierr code
func TestSentinelsDistinct(t *testing.T) {
	if errors.Is(ErrEpochReplay, ErrMemberSetDrift) {
		t.Fatalf("ErrEpochReplay should not be ErrMemberSetDrift")
	}
}
