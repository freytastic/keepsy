package middleware

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type contextKey string

const UserIDKey contextKey = "user_id"

type SessionStore interface {
	GetByToken(ctx context.Context, token string) (*model.Session, error)
}

type AuthMiddleware struct {
	sessionRepo SessionStore
}

func NewAuthMiddleware(sessionRepo SessionStore) *AuthMiddleware {
	return &AuthMiddleware{sessionRepo: sessionRepo}
}

func (m *AuthMiddleware) Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			apierr.Write(w, r, apierr.Auth("missing bearer token"))
			return
		}

		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || parts[0] != "Bearer" {
			apierr.Write(w, r, apierr.Auth("invalid Authorization header format"))
			return
		}

		token := parts[1]
		session, err := m.sessionRepo.GetByToken(r.Context(), token)
		if err != nil {
			apierr.Write(w, r, apierr.Auth("invalid or expired session").WithCause(err))
			return
		}

		if time.Now().After(session.ExpiresAt) {
			apierr.Write(w, r, apierr.Auth("session expired"))
			return
		}

		ctx := context.WithValue(r.Context(), UserIDKey, session.UserID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func GetUserID(ctx context.Context) (uuid.UUID, bool) {
	userID, ok := ctx.Value(UserIDKey).(uuid.UUID)
	return userID, ok
}

func MustGetUserID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	userID, ok := GetUserID(r.Context())
	if !ok {
		apierr.Write(w, r, apierr.Auth("authentication required"))
		return uuid.Nil, false
	}
	return userID, true
}
