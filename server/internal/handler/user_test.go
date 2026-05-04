package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
)

type stubUserStore struct {
	getByIDFn func(ctx context.Context, id uuid.UUID) (*model.User, error)
	updateFn  func(ctx context.Context, u *model.User) error
}

func (s *stubUserStore) GetByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.getByIDFn(ctx, id)
}
func (s *stubUserStore) Update(ctx context.Context, u *model.User) error {
	return s.updateFn(ctx, u)
}

// TestUpdateMe_RejectsE2EEFields proves PATCH /users/me cannot smuggle E2EE
// columns : bootstrap is supposed to flow through PUT /users/me/keys
func TestUpdateMe_RejectsE2EEFields(t *testing.T) {
	store := &stubUserStore{
		getByIDFn: func(_ context.Context, _ uuid.UUID) (*model.User, error) {
			t.Fatal("UpdateMe must reject before calling the store")
			return nil, nil
		},
		updateFn: func(_ context.Context, _ *model.User) error { return nil },
	}
	svc := service.NewUserService(store)
	h := NewUserHandler(svc)

	body := []byte(`{"name":"Alice","ik_pub":"AAAA"}`)
	req := httptest.NewRequest(http.MethodPatch, "/users/me", bytes.NewReader(body))
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()

	h.UpdateMe(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	var env struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&env)
	if env.Code != "E_VALIDATION" {
		t.Errorf("code = %q, want E_VALIDATION", env.Code)
	}
}

// TestUpdateMe_AcceptsProfileFields keeps the profile only happy path covered
func TestUpdateMe_AcceptsProfileFields(t *testing.T) {
	id := uuid.New()
	store := &stubUserStore{
		getByIDFn: func(_ context.Context, _ uuid.UUID) (*model.User, error) {
			return &model.User{ID: id, Email: "x@y.com", AccentColor: "#000", Theme: "dark"}, nil
		},
		updateFn: func(_ context.Context, _ *model.User) error { return nil },
	}
	svc := service.NewUserService(store)
	h := NewUserHandler(svc)

	body := []byte(`{"name":"Alice","accent_color":"#fff","theme":"light"}`)
	req := httptest.NewRequest(http.MethodPatch, "/users/me", bytes.NewReader(body))
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, id))
	rec := httptest.NewRecorder()

	h.UpdateMe(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}
