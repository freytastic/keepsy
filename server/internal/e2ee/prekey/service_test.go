package prekey

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

// mockStore implements the service's store interface with function field hooks
// in the spirit of internal/handler/album_members_test.go::mockAlbumStore
type mockStore struct {
	identityByIDFn      func(ctx context.Context, userID uuid.UUID) (*Identity, error)
	upsertIdentityFn    func(ctx context.Context, userID uuid.UUID, ik, lk, spk, sig []byte, ts int64) error
	rotateSPKFn         func(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64, audit SpkRotation) error
	createBatchAtomicFn func(ctx context.Context, opks []model.OneTimePrekey) error
	popRandomFn         func(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error)
	countFn             func(ctx context.Context, userID uuid.UUID) (int, error)
}

func (m *mockStore) IdentityByID(ctx context.Context, userID uuid.UUID) (*Identity, error) {
	return m.identityByIDFn(ctx, userID)
}
func (m *mockStore) UpsertIdentity(ctx context.Context, userID uuid.UUID, ik, lk, spk, sig []byte, ts int64) error {
	return m.upsertIdentityFn(ctx, userID, ik, lk, spk, sig, ts)
}
func (m *mockStore) RotateSPK(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64, audit SpkRotation) error {
	return m.rotateSPKFn(ctx, userID, spkPub, spkSig, spkTs, audit)
}
func (m *mockStore) CreateBatchAtomic(ctx context.Context, opks []model.OneTimePrekey) error {
	return m.createBatchAtomicFn(ctx, opks)
}
func (m *mockStore) PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error) {
	return m.popRandomFn(ctx, userID)
}
func (m *mockStore) Count(ctx context.Context, userID uuid.UUID) (int, error) {
	return m.countFn(ctx, userID)
}

const fixedTs int64 = 1_700_000_000

func fixedClock() time.Time { return time.Unix(fixedTs, 0) }

// genIdentity returns a fresh keypair + a valid {spk_pub, spk_sig, spk_ts} that
// passes the spk_sig self-signature check
func genIdentity(t *testing.T, ts int64) (ed25519.PublicKey, ed25519.PrivateKey, []byte, []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey: %v", err)
	}
	spk := make([]byte, 32)
	for i := range spk {
		spk[i] = byte(0xC0 + i)
	}
	sig := ed25519.Sign(priv, spkSelfMsg(spk, ts))
	return pub, priv, spk, sig
}

func TestUpsertIdentity_RejectsBadSig(t *testing.T) {
	ikPub, _, spk, _ := genIdentity(t, fixedTs)
	otherPub, otherPriv, _, _ := genIdentity(t, fixedTs)
	_ = otherPub
	// sign over some unrelated message; verification must reject
	badSig := ed25519.Sign(otherPriv, []byte("totally wrong message"))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{}, nil
		},
		upsertIdentityFn: func(_ context.Context, _ uuid.UUID, _, _, _, _ []byte, _ int64) error { return nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.UpsertIdentity(context.Background(), uuid.New(), UpsertIdentityInput{
		IKPub: ikPub, LKPub: make([]byte, 32), SPKPub: spk, SPKSig: badSig, SPKTs: fixedTs,
	})
	if !apierr.IsCode(err, "E_SIG_INVALID") {
		t.Fatalf("err = %v, want E_SIG_INVALID", err)
	}
}

func TestUpsertIdentity_RejectsTsSkew(t *testing.T) {
	ikPub, priv, spk, _ := genIdentity(t, fixedTs-600)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs-600))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{}, nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.UpsertIdentity(context.Background(), uuid.New(), UpsertIdentityInput{
		IKPub: ikPub, LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: fixedTs - 600,
	})
	if !apierr.IsCode(err, "E_TS_SKEW") {
		t.Fatalf("err = %v, want E_TS_SKEW", err)
	}
}

func TestUpsertIdentity_RejectsBadLength(t *testing.T) {
	_, priv, spk, _ := genIdentity(t, fixedTs)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))

	store := &mockStore{}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.UpsertIdentity(context.Background(), uuid.New(), UpsertIdentityInput{
		IKPub: make([]byte, 31), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: fixedTs,
	})
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestRotateSPK_RequiresRotationSig(t *testing.T) {
	ikPub, priv, spk, _ := genIdentity(t, fixedTs)
	cur := int64(fixedTs - 60)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), SPKPub: spk, SPKTs: &cur}, nil
		},
		rotateSPKFn: func(_ context.Context, _ uuid.UUID, _, _ []byte, _ int64, _ SpkRotation) error {
			t.Fatal("rotateSPKFn must not be called when rotation_sig is invalid")
			return nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	// supply all zero rotation_sig : it has the right length but wont verify
	err := svc.RotateSPK(context.Background(), uuid.New(), RotateSPKInput{
		SPKPub: spk, SPKSig: sig, SPKTs: fixedTs, RotationSig: make([]byte, 64),
	})
	if !apierr.IsCode(err, "E_SIG_INVALID") {
		t.Fatalf("err = %v, want E_SIG_INVALID", err)
	}
}

func TestRotateSPK_AuditRowWritten(t *testing.T) {
	ikPub, priv, spk, _ := genIdentity(t, fixedTs)
	cur := int64(fixedTs - 60)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))
	rsig := ed25519.Sign(priv, RotationMsg(spk, fixedTs))

	var got SpkRotation
	called := false
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), SPKPub: spk, SPKTs: &cur}, nil
		},
		rotateSPKFn: func(_ context.Context, _ uuid.UUID, _, _ []byte, _ int64, audit SpkRotation) error {
			called = true
			got = audit
			return nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.RotateSPK(context.Background(), uuid.New(), RotateSPKInput{
		SPKPub: spk, SPKSig: sig, SPKTs: fixedTs, RotationSig: rsig,
		IP: "10.0.0.1", UserAgent: "test/1.0",
	})
	if err != nil {
		t.Fatalf("RotateSPK: %v", err)
	}
	if !called {
		t.Fatal("repo.RotateSPK was not called")
	}
	if got.NewSpkTs != fixedTs {
		t.Errorf("NewSpkTs = %d, want %d", got.NewSpkTs, fixedTs)
	}
	if got.OldSpkTs == nil || *got.OldSpkTs != cur {
		t.Errorf("OldSpkTs = %v, want %d", got.OldSpkTs, cur)
	}
	if got.IP != "10.0.0.1" || got.UserAgent != "test/1.0" {
		t.Errorf("audit metadata not propagated: %+v", got)
	}
}

func TestReplenishOPKs_BadReplenishSig(t *testing.T) {
	ikPub, _, _, _ := genIdentity(t, fixedTs)
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub)}, nil
		},
		createBatchAtomicFn: func(_ context.Context, _ []model.OneTimePrekey) error {
			t.Fatal("createBatchAtomicFn must not be called when replenish_sig is invalid")
			return nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(0x10 + i)
	}
	err := svc.ReplenishOPKs(context.Background(), uuid.New(), ReplenishOPKsInput{
		OPKs:         []OPKUpload{{Idx: 0, KeyPub: pub}},
		ReplenishSig: make([]byte, 64),
	})
	if !apierr.IsCode(err, "E_SIG_INVALID") {
		t.Fatalf("err = %v, want E_SIG_INVALID", err)
	}
}

func TestReplenishOPKs_DuplicateIdx(t *testing.T) {
	ikPub, priv, _, _ := genIdentity(t, fixedTs)

	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(0x42)
	}
	pubs := [][]byte{pub}
	rsig := ed25519.Sign(priv, ReplenishMsg(pubs))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub)}, nil
		},
		createBatchAtomicFn: func(_ context.Context, _ []model.OneTimePrekey) error {
			return ErrOPKIndexTaken
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.ReplenishOPKs(context.Background(), uuid.New(), ReplenishOPKsInput{
		OPKs:         []OPKUpload{{Idx: 7, KeyPub: pub}},
		ReplenishSig: rsig,
	})
	if !apierr.IsCode(err, "E_OPK_INDEX_TAKEN") {
		t.Fatalf("err = %v, want E_OPK_INDEX_TAKEN", err)
	}
}

func TestRotateSPK_RejectsNonMonotonicTs(t *testing.T) {
	ikPub, priv, spk, _ := genIdentity(t, fixedTs)
	cur := int64(fixedTs)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))
	rsig := ed25519.Sign(priv, RotationMsg(spk, fixedTs))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), SPKPub: spk, SPKTs: &cur}, nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.RotateSPK(context.Background(), uuid.New(), RotateSPKInput{
		SPKPub: spk, SPKSig: sig, SPKTs: fixedTs, RotationSig: rsig,
	})
	if !apierr.IsCode(err, "E_TS_NOT_MONOTONIC") {
		t.Fatalf("err = %v, want E_TS_NOT_MONOTONIC", err)
	}
}

// guard : identity-not-set must trip *before* sig verification on rotate
func TestRotateSPK_RequiresIdentitySet(t *testing.T) {
	_, priv, spk, _ := genIdentity(t, fixedTs)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))
	rsig := ed25519.Sign(priv, RotationMsg(spk, fixedTs))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{}, nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	err := svc.RotateSPK(context.Background(), uuid.New(), RotateSPKInput{
		SPKPub: spk, SPKSig: sig, SPKTs: fixedTs, RotationSig: rsig,
	})
	if !apierr.IsCode(err, "E_IDENTITY_NOT_SET") {
		t.Fatalf("err = %v, want E_IDENTITY_NOT_SET", err)
	}
}

// sanity : ErrOPKIndexTaken is a value equality sentinel
func TestErrOPKIndexTakenSentinel(t *testing.T) {
	if !errors.Is(ErrOPKIndexTaken, ErrOPKIndexTaken) {
		t.Error("sentinel must equal itself")
	}
}
