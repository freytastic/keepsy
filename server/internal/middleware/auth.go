package middleware

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

type contextKey string

const UserIDKey contextKey = "user_id"

// any struct that has this GetByToken method can now be used by the middleware
type SessionStore interface {
	GetByToken(ctx context.Context, token string) (*model.Session, error)
}

type AuthMiddleware struct {
	sessionRepo SessionStore
}

func NewAuthMiddleware(sessionRepo SessionStore) *AuthMiddleware {
	return &AuthMiddleware{sessionRepo: sessionRepo}
}

// Authenticate is the middleware func that wraps handlers
func (m *AuthMiddleware) Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, "Unauthorized: missing token", http.StatusUnauthorized)
			return
		}

		// format : Bearer <token>
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || parts[0] != "Bearer" {
			http.Error(w, "Unauthorized: invalid header format", http.StatusUnauthorized)
			return
		}

		token := parts[1]
		session, err := m.sessionRepo.GetByToken(r.Context(), token)
		if err != nil {
			http.Error(w, "Unauthorized: invalid token", http.StatusUnauthorized)
			return
		}

		// check if session has expired
		if time.Now().After(session.ExpiresAt) {
			http.Error(w, "Unauthorized: session expired", http.StatusUnauthorized)
			return
		}

		// inject UserID into context
		ctx := context.WithValue(r.Context(), UserIDKey, session.UserID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// retrieves the user_id from the context
func GetUserID(ctx context.Context) (uuid.UUID, bool) {
	userID, ok := ctx.Value(UserIDKey).(uuid.UUID)
	return userID, ok
}

// MustGetUserID retrieves the user_id from the context or writes an unauthorized error to the response
func MustGetUserID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	userID, ok := GetUserID(r.Context())
	if !ok {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return uuid.Nil, false
	}
	return userID, true
}
