package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/service"
	"github.com/google/uuid"
)

type stubUserStore struct {
	getByIDFn func(ctx context.Context, id uuid.UUID) (*model.User, error)
}

func (s *stubUserStore) GetByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.getByIDFn(ctx, id)
}

// TestGetMe_IncludesMiuchioID locks the §6.1 discovery handle into the /me
// response : the profile screen reads it from here, so a dropped field hides
// the user's shareable miuchio ID
func TestGetMe_IncludesMiuchioID(t *testing.T) {
	id := uuid.New()
	store := &stubUserStore{
		getByIDFn: func(_ context.Context, _ uuid.UUID) (*model.User, error) {
			return &model.User{ID: id, MiuchioID: "K7F29QXM"}, nil
		},
	}
	h := NewUserHandler(service.NewUserService(store))

	req := httptest.NewRequest(http.MethodGet, "/users/me", nil)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, id))
	rec := httptest.NewRecorder()
	h.GetMe(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d want 200", rec.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["miuchio_id"] != "K7F29QXM" {
		t.Fatalf("miuchio_id = %v, want K7F29QXM (must reach /me so the profile can show it)", body["miuchio_id"])
	}
}
