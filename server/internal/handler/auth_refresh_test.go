package handler

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
)

type refreshSessionStore struct {
	get    func(ctx context.Context, token string) (*model.Session, error)
	extend func(ctx context.Context, token string, expiresAt time.Time) error
}

func (s *refreshSessionStore) Create(context.Context, *model.Session) error { return nil }
func (s *refreshSessionStore) GetByToken(ctx context.Context, t string) (*model.Session, error) {
	return s.get(ctx, t)
}
func (s *refreshSessionStore) DeleteByToken(context.Context, string) error { return nil }
func (s *refreshSessionStore) ExtendByToken(ctx context.Context, t string, e time.Time) error {
	if s.extend != nil {
		return s.extend(ctx, t, e)
	}
	return nil
}

type stubOTP struct{}

func (stubOTP) SetOTP(context.Context, string, string, time.Duration) error { return nil }
func (stubOTP) GetOTP(context.Context, string) (string, error)              { return "", nil }
func (stubOTP) DeleteOTP(context.Context, string) error                     { return nil }
func (stubOTP) CheckRateLimit(context.Context, string) (bool, error)        { return true, nil }

type stubUsers struct{}

func (stubUsers) GetByEmailHMAC(context.Context, []byte) (*model.User, error) { return nil, nil }
func (stubUsers) Create(context.Context, *model.User) error                   { return nil }

type stubEmail struct{}

func (stubEmail) SendOTP(string, string) error { return nil }

// Database failures must not become a 401 that logs out the client
func TestRefresh_StatusSeparatesDeadSessionFromInternalFailure(t *testing.T) {
	live := func(context.Context, string) (*model.Session, error) {
		return &model.Session{ExpiresAt: time.Now().Add(time.Hour)}, nil
	}

	tests := []struct {
		name  string
		store *refreshSessionStore
		want  int
	}{
		{
			name: "unknown session",
			store: &refreshSessionStore{
				get: func(context.Context, string) (*model.Session, error) {
					return nil, repository.ErrSessionNotFound
				},
			},
			want: http.StatusUnauthorized,
		},
		{
			name: "expired session",
			store: &refreshSessionStore{
				get: func(context.Context, string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(-time.Hour)}, nil
				},
			},
			want: http.StatusUnauthorized,
		},
		{
			name: "database unreachable on read",
			store: &refreshSessionStore{
				get: func(context.Context, string) (*model.Session, error) {
					return nil, errors.New("connection refused")
				},
			},
			want: http.StatusInternalServerError,
		},
		{
			name: "database unreachable on write",
			store: &refreshSessionStore{
				get: live,
				extend: func(context.Context, string, time.Time) error {
					return errors.New("connection refused")
				},
			},
			want: http.StatusInternalServerError,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := service.NewAuthService(stubOTP{}, stubUsers{}, tt.store,
				stubEmail{}, []byte("test-email-hmac-key-32-bytes!!!!"))
			h := NewAuthHandler(svc)

			req := httptest.NewRequest(http.MethodPost, "/auth/otp/refresh",
				strings.NewReader(`{"refreshToken":"tok"}`))
			rec := httptest.NewRecorder()
			h.Refresh(rec, req)

			if rec.Code != tt.want {
				t.Errorf("status = %d, want %d (body %s)", rec.Code, tt.want, rec.Body.String())
			}
		})
	}
}
