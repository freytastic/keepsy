package handler

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type emitCall struct {
	users   []uuid.UUID
	typ     string
	payload any
}

type mockNotifier struct{ calls []emitCall }

func (m *mockNotifier) EmitToUsers(_ context.Context, users []uuid.UUID, typ string, payload any) error {
	m.calls = append(m.calls, emitCall{users: users, typ: typ, payload: payload})
	return nil
}

type mockResolver struct {
	fn func(ctx context.Context, tokens [][]byte) ([]uuid.UUID, error)
}

func (m *mockResolver) UserIDsByMemberTokens(ctx context.Context, tokens [][]byte) ([]uuid.UUID, error) {
	if m.fn != nil {
		return m.fn(ctx, tokens)
	}
	return nil, nil
}

func removeRouter(store *mockAlbumStore, notifier *mockNotifier, resolver *mockResolver) http.Handler {
	svc := service.NewAlbumService(store)
	h := NewAlbumHandler(svc, notifier, resolver)
	r := mux.NewRouter()
	scoped := r.PathPrefix("/api/v1/albums/{id}").Subrouter()
	scoped.Use(middleware.RequireMember(store, "id"))
	scoped.HandleFunc("/members/{token}", h.RemoveAlbumMember).Methods(http.MethodDelete)
	return r
}

func doDelete(h http.Handler, albumID uuid.UUID, tokenPath string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodDelete, "/api/v1/albums/"+albumID.String()+"/members/"+tokenPath, nil)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestRemoveAlbumMember_AdminKicksMember(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	target := []byte("targettargettargettargettarget32")
	removedUser := uuid.New()

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "member", false, nil
		},
		listMembersFn: func(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) {
			return nil, nil // no remaining members in fixture, removed token still notified
		},
	}
	notifier := &mockNotifier{}
	resolver := &mockResolver{fn: func(_ context.Context, tokens [][]byte) ([]uuid.UUID, error) {
		return []uuid.UUID{removedUser}, nil
	}}

	rec := doDelete(removeRouter(store, notifier, resolver), albumID, base64.RawURLEncoding.EncodeToString(target))

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	if len(notifier.calls) != 1 {
		t.Fatalf("emit calls = %d, want 1", len(notifier.calls))
	}
	c := notifier.calls[0]
	if c.typ != ws.EventMemberRevoked {
		t.Errorf("event type = %q, want %q", c.typ, ws.EventMemberRevoked)
	}
	// the removed member must be among the notified users (learns it's out)
	found := false
	for _, u := range c.users {
		if u == removedUser {
			found = true
		}
	}
	if !found {
		t.Errorf("removed user not in notified set %v", c.users)
	}
}

func TestRemoveAlbumMember_LastAdminForbidden(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "admin", false, repository.ErrLastAdmin
		},
	}
	rec := doDelete(removeRouter(store, &mockNotifier{}, &mockResolver{}), albumID, base64.RawURLEncoding.EncodeToString(admin))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestRemoveAlbumMember_TargetNotFound(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	ghost := []byte("ghostghostghostghostghostghost32")

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrMemberNotFound
		},
	}
	rec := doDelete(removeRouter(store, &mockNotifier{}, &mockResolver{}), albumID, base64.RawURLEncoding.EncodeToString(ghost))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestRemoveAlbumMember_CallerRevokedMidFlightGivesMemberRevoked(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	target := []byte("targettargettargettargettarget32")

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrCallerRevoked
		},
	}
	rec := doDelete(removeRouter(store, &mockNotifier{}, &mockResolver{}), albumID, base64.RawURLEncoding.EncodeToString(target))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	var body struct{ Code string }
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_MEMBER_REVOKED" {
		t.Errorf("code = %q, want E_MEMBER_REVOKED", body.Code)
	}
}

func TestRemoveAlbumMember_PlainMemberForbidden(t *testing.T) {
	albumID := uuid.New()
	caller := []byte("callercallercallercallercaller32")
	target := []byte("targettargettargettargettarget32")

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return caller, "member", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be called for an unauthorized caller")
			return "", false, nil
		},
	}
	rec := doDelete(removeRouter(store, &mockNotifier{}, &mockResolver{}), albumID, base64.RawURLEncoding.EncodeToString(target))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}
