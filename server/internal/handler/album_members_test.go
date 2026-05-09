package handler

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type mockAlbumStore struct {
	lookupMemberFn func(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error)
	listMembersFn  func(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error)
}

func (m *mockAlbumStore) LookupMember(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error) {
	return m.lookupMemberFn(ctx, userID, albumID)
}
func (m *mockAlbumStore) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	return m.listMembersFn(ctx, albumID)
}
func (m *mockAlbumStore) CreateWithAdmin(_ context.Context, _ []byte, _ uuid.UUID) (*model.Album, []byte, error) {
	return nil, nil, nil
}
func (m *mockAlbumStore) GetByID(_ context.Context, _ uuid.UUID) (*model.Album, error) {
	return nil, nil
}
func (m *mockAlbumStore) ListForUser(_ context.Context, _ uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return nil, nil
}
func (m *mockAlbumStore) AddMember(_ context.Context, _, _ uuid.UUID, _ string) ([]byte, error) {
	return nil, nil
}
func (m *mockAlbumStore) CountActiveMembers(_ context.Context, _ uuid.UUID) (int, error) {
	return 0, nil
}
func (m *mockAlbumStore) UpdateName(_ context.Context, _ uuid.UUID, _ []byte) error { return nil }
func (m *mockAlbumStore) UpdateMemberNameCT(_ context.Context, _ uuid.UUID, _, _ []byte) error {
	return nil
}
func (m *mockAlbumStore) Delete(_ context.Context, _ uuid.UUID) error { return nil }

func membersRouter(store *mockAlbumStore) http.Handler {
	svc := service.NewAlbumService(store)
	h := NewAlbumHandler(svc)
	r := mux.NewRouter()
	scoped := r.PathPrefix("/api/v1/albums/{id}").Subrouter()
	scoped.Use(middleware.RequireMember(store, "id"))
	scoped.HandleFunc("/members", h.ListAlbumMembers).Methods(http.MethodGet)
	return r
}

func TestListAlbumMembers_MemberGets200WithList(t *testing.T) {
	albumID := uuid.New()
	callerToken := []byte("callertoken12345678901234567890ab")

	store := &mockAlbumStore{
		lookupMemberFn: func(_ context.Context, _, _ uuid.UUID) ([]byte, string, error) {
			return callerToken, "admin", nil
		},
		listMembersFn: func(_ context.Context, _ uuid.UUID) ([]model.MemberWithProfile, error) {
			return []model.MemberWithProfile{
				{
					MemberToken: callerToken,
					Role:        "admin",
					Revoked:     false,
					JoinedAt:    time.Now(),
					Profile:     model.MemberProfile{},
				},
			}, nil
		},
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/albums/"+albumID.String()+"/members", nil)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	membersRouter(store).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var body []map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("len = %d, want 1", len(body))
	}
	if body[0]["role"] != "admin" {
		t.Errorf("role = %v, want admin", body[0]["role"])
	}
}

// TestListAlbumMembers_ProfileRoundTripsLKPub pins the §4.2 wire shape: ik_pub
// and lk_pub flow through the handler as base64 of the raw 32-byte keys
func TestListAlbumMembers_ProfileRoundTripsLKPub(t *testing.T) {
	albumID := uuid.New()
	callerToken := []byte("callertoken12345678901234567890ab")
	ikPub := bytes.Repeat([]byte{0x21}, 32)
	lkPub := bytes.Repeat([]byte{0x42}, 32)

	store := &mockAlbumStore{
		lookupMemberFn: func(_ context.Context, _, _ uuid.UUID) ([]byte, string, error) {
			return callerToken, "admin", nil
		},
		listMembersFn: func(_ context.Context, _ uuid.UUID) ([]model.MemberWithProfile, error) {
			return []model.MemberWithProfile{
				{
					MemberToken: callerToken,
					Role:        "admin",
					Revoked:     false,
					JoinedAt:    time.Now(),
					Profile:     model.MemberProfile{IKPub: ikPub, LKPub: lkPub},
				},
			}, nil
		},
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/albums/"+albumID.String()+"/members", nil)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	membersRouter(store).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var body []map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("len = %d, want 1", len(body))
	}
	prof, ok := body[0]["profile"].(map[string]any)
	if !ok {
		t.Fatalf("profile missing or wrong type: %T", body[0]["profile"])
	}
	wantIK := base64.StdEncoding.EncodeToString(ikPub)
	if prof["ik_pub"] != wantIK {
		t.Errorf("ik_pub = %v, want %v", prof["ik_pub"], wantIK)
	}
	wantLK := base64.StdEncoding.EncodeToString(lkPub)
	if prof["lk_pub"] != wantLK {
		t.Errorf("lk_pub = %v, want %v", prof["lk_pub"], wantLK)
	}
}

func TestListAlbumMembers_NonMemberGetsE_NOT_MEMBER(t *testing.T) {
	albumID := uuid.New()

	store := &mockAlbumStore{
		lookupMemberFn: func(_ context.Context, _, _ uuid.UUID) ([]byte, string, error) {
			return nil, "", repository.ErrMemberNotFound
		},
		listMembersFn: func(_ context.Context, _ uuid.UUID) ([]model.MemberWithProfile, error) {
			return nil, nil
		},
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/albums/"+albumID.String()+"/members", nil)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	membersRouter(store).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	var body struct{ Code string }
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_NOT_MEMBER" {
		t.Errorf("code = %q, want E_NOT_MEMBER", body.Code)
	}
}
