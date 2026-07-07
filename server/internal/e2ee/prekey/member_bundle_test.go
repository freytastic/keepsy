package prekey

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
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type stubMemberResolver struct {
	fn func(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error)
}

func (s stubMemberResolver) UserIDByAlbumMemberToken(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error) {
	return s.fn(ctx, albumID, token)
}

func memberBundleRouter(h *Handler) http.Handler {
	r := mux.NewRouter()
	r.HandleFunc("/albums/{id}/members/{token}/prekey-bundle", h.GetPrekeyBundleByMemberToken).Methods(http.MethodGet)
	return r
}

func memberBundleReq(albumID uuid.UUID, tokenPath string, userID uuid.UUID, role string, memberToken []byte) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/albums/"+albumID.String()+"/members/"+tokenPath+"/prekey-bundle", nil)
	ctx := context.WithValue(req.Context(), middleware.UserIDKey, userID)
	ctx = middleware.WithMemberContext(ctx, memberToken, role)
	return req.WithContext(ctx)
}

func TestBundleByMemberToken_AdminGetsBundleWithTokenIdentity(t *testing.T) {
	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	target := uuid.New()
	albumID := uuid.New()
	token := make([]byte, 32)
	for i := range token {
		token[i] = byte(0x40 + i)
	}

	store := &mockStore{
		identityByIDFn: func(context.Context, uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(context.Context, uuid.UUID) (*model.OneTimePrekey, error) {
			return &model.OneTimePrekey{ID: uuid.New(), OPKIdx: 1, KeyPub: make([]byte, 32)}, nil
		},
		countFn: func(context.Context, uuid.UUID) (int, error) { return 5, nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	resolver := stubMemberResolver{fn: func(_ context.Context, _ uuid.UUID, _ []byte) (uuid.UUID, error) {
		return target, nil
	}}
	h := NewHandler(svc, nil, nil, resolver)

	rec := httptest.NewRecorder()
	req := memberBundleReq(albumID, base64.RawURLEncoding.EncodeToString(token), uuid.New(), "admin", []byte("callercallercallercallercaller32"))
	memberBundleRouter(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// identity field must be the member_token, never the real user UUID
	wantID := base64.StdEncoding.EncodeToString(token)
	if body["user_id"] != wantID {
		t.Errorf("user_id = %v, want member_token %v", body["user_id"], wantID)
	}
	if body["user_id"] == target.String() {
		t.Errorf("response leaked real user UUID")
	}
	if body["spk_pub"] == nil {
		t.Errorf("bundle missing spk_pub")
	}
}

func TestBundleByMemberToken_NonAdminForbidden(t *testing.T) {
	store := &mockStore{}
	svc := NewService(store)
	resolver := stubMemberResolver{fn: func(context.Context, uuid.UUID, []byte) (uuid.UUID, error) {
		t.Fatal("resolver must not be called for a non-admin caller")
		return uuid.Nil, nil
	}}
	h := NewHandler(svc, nil, nil, resolver)

	token := make([]byte, 32)
	rec := httptest.NewRecorder()
	req := memberBundleReq(uuid.New(), base64.RawURLEncoding.EncodeToString(token), uuid.New(), "member", []byte("callercallercallercallercaller32"))
	memberBundleRouter(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestBundleByMemberToken_UnknownTokenNotFound(t *testing.T) {
	store := &mockStore{}
	svc := NewService(store)
	resolver := stubMemberResolver{fn: func(context.Context, uuid.UUID, []byte) (uuid.UUID, error) {
		return uuid.Nil, repository.ErrMemberNotFound
	}}
	h := NewHandler(svc, nil, nil, resolver)

	token := make([]byte, 32)
	rec := httptest.NewRecorder()
	req := memberBundleReq(uuid.New(), base64.RawURLEncoding.EncodeToString(token), uuid.New(), "co-admin", []byte("callercallercallercallercaller32"))
	memberBundleRouter(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}
