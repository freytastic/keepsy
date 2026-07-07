package service

import (
	"context"
	"errors"
	"testing"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

// removeMemberStore is a hand mock of AlbumStore focused on the RemoveMember
// authz surface. The atomic revoke (target read + admin count + revoke under
// the album lock) is one repo call : RevokeMemberTx
type removeMemberStore struct {
	lookupFn   func(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error)
	revokeTxFn func(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (role string, alreadyRevoked bool, err error)

	revokedToken []byte // captures the target token passed to RevokeMemberTx
	revokeCalls  int
	deleteCalls  int
}

func (m *removeMemberStore) LookupMember(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error) {
	return m.lookupFn(ctx, userID, albumID)
}
func (m *removeMemberStore) RevokeMemberTx(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (string, bool, error) {
	m.revokeCalls++
	m.revokedToken = targetToken
	return m.revokeTxFn(ctx, albumID, callerToken, targetToken)
}

// unused AlbumStore methods
func (m *removeMemberStore) CreateWithAdmin(context.Context, []byte, uuid.UUID) (*model.Album, []byte, error) {
	return nil, nil, nil
}
func (m *removeMemberStore) GetByID(context.Context, uuid.UUID) (*model.Album, error) {
	return nil, nil
}
func (m *removeMemberStore) ListForUser(context.Context, uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return nil, nil
}
func (m *removeMemberStore) ListMembers(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) {
	return nil, nil
}
func (m *removeMemberStore) UpdateName(context.Context, uuid.UUID, []byte) error { return nil }
func (m *removeMemberStore) UpdateMemberNameCT(context.Context, uuid.UUID, []byte, []byte) error {
	return nil
}
func (m *removeMemberStore) Delete(context.Context, uuid.UUID) error {
	m.deleteCalls++
	return nil
}

type stubPurger struct{ err error }

func (p stubPurger) PurgeAlbumObjects(context.Context, uuid.UUID) error { return p.err }

func okRevoke(role string) func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
	return func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) { return role, false, nil }
}

func TestRemoveMember_AdminKicksMember(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: okRevoke("member"),
	}
	svc := NewAlbumService(store)

	res, err := svc.RemoveMember(context.Background(), albumID, uuid.New(), target)
	if err != nil {
		t.Fatalf("RemoveMember: unexpected error %v", err)
	}
	if res.AlreadyRevoked {
		t.Errorf("AlreadyRevoked = true, want false")
	}
	if store.revokeCalls != 1 {
		t.Fatalf("RevokeMemberTx calls = %d, want 1", store.revokeCalls)
	}
	if string(store.revokedToken) != string(target) {
		t.Errorf("revoked token = %q, want target", store.revokedToken)
	}
}

func TestRemoveMember_PlainMemberCannotKickOther(t *testing.T) {
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("callercallercallercallercaller32"), "member", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be called for an unauthorized caller")
			return "", false, nil
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), target)
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
	if store.revokeCalls != 0 {
		t.Errorf("RevokeMemberTx should not be called, got %d", store.revokeCalls)
	}
}

// authz is evaluated BEFORE the already revoked no op. A non admin
// removing an already revoked member must get unauthorized, not a 204 : the
// revoke tx must not even be reached
func TestRemoveMember_PlainMemberCannotRemoveAlreadyRevoked(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("callercallercallercallercaller32"), "member", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be reached before the authz check")
			return "member", true, nil
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("targettargettargettargettarget32"))
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized (authz before no-op)", err)
	}
}

func TestRemoveMember_MemberCanLeave(t *testing.T) {
	self := []byte("selfselfselfselfselfselfselfsel1")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return self, "member", nil
		},
		revokeTxFn: okRevoke("member"),
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), self)
	if err != nil {
		t.Fatalf("self-leave: unexpected error %v", err)
	}
	if store.revokeCalls != 1 {
		t.Errorf("RevokeMemberTx calls = %d, want 1", store.revokeCalls)
	}
}

func TestRemoveMember_LastAdminRejectedByTx(t *testing.T) {
	self := []byte("adminadminadminadminadminadmin32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return self, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "admin", false, repository.ErrLastAdmin
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), self)
	if !errors.Is(err, ErrLastAdmin) {
		t.Fatalf("err = %v, want ErrLastAdmin", err)
	}
}

func TestRemoveMember_TargetNotFound(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrMemberNotFound
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("ghostghostghostghostghostghost32"))
	if !errors.Is(err, ErrMemberNotFound) {
		t.Fatalf("err = %v, want ErrMemberNotFound", err)
	}
}

func TestRemoveMember_AlreadyRevokedIsNoOp(t *testing.T) {
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "member", true, nil // already revoked
		},
	}
	svc := NewAlbumService(store)

	res, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), target)
	if err != nil {
		t.Fatalf("already-revoked: unexpected error %v", err)
	}
	if !res.AlreadyRevoked {
		t.Errorf("AlreadyRevoked = false, want true")
	}
}

// Hard delete semantics: if the S3 object purge fails, the album row must NOT
// be deleted (it's the only handle left to retry the object cleanup)
func TestDeleteAlbum_AbortsWhenObjectPurgeFails(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
	}
	svc := NewAlbumService(store)
	svc.SetObjectPurger(stubPurger{err: errors.New("minio down")})

	if err := svc.DeleteAlbum(context.Background(), uuid.New(), uuid.New()); err == nil {
		t.Fatal("DeleteAlbum returned nil, want error when purge fails")
	}
	if store.deleteCalls != 0 {
		t.Errorf("album row deleted despite purge failure (deleteCalls=%d)", store.deleteCalls)
	}
}

func TestDeleteAlbum_DeletesAfterSuccessfulPurge(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
	}
	svc := NewAlbumService(store)
	svc.SetObjectPurger(stubPurger{err: nil})

	if err := svc.DeleteAlbum(context.Background(), uuid.New(), uuid.New()); err != nil {
		t.Fatalf("DeleteAlbum: %v", err)
	}
	if store.deleteCalls != 1 {
		t.Errorf("album delete calls = %d, want 1", store.deleteCalls)
	}
}

// A caller who passes the (unlocked) role auth but is revoked by a concurrent
// removal before the locked commit must be rejected : the tx surfaces
// ErrCallerRevoked, which becomes E_MEMBER_REVOKED at the handler
func TestRemoveMember_CallerRevokedMidFlight(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrCallerRevoked
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("targettargettargettargettarget32"))
	if !errors.Is(err, ErrCallerRevoked) {
		t.Fatalf("err = %v, want ErrCallerRevoked", err)
	}
}
