package middleware

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

// MockSessionStore is solely for testing
type MockSessionStore struct {
	GetByTokenFunc func(ctx context.Context, token string) (*model.Session, error)
}

// GetByToken implements the SessionStore interface for the mock
func (m *MockSessionStore) GetByToken(ctx context.Context, token string) (*model.Session, error) {
	return m.GetByTokenFunc(ctx, token)
}

func TestAuthMiddleware_Authenticate(t *testing.T) {
	userID := uuid.New()

	// define all the test scenarios
	tests := []struct {
		name           string
		authHeader     string
		mockFunc       func(ctx context.Context, token string) (*model.Session, error)
		expectedStatus int
	}{
		{
			name:       "Success - Valid Token",
			authHeader: "Bearer valid-token",
			mockFunc: func(ctx context.Context, token string) (*model.Session, error) {
				return &model.Session{
					UserID:    userID,
					ExpiresAt: time.Now().Add(1 * time.Hour),
				}, nil
			},
			expectedStatus: http.StatusOK,
		},
		{
			name:           "Failure - Missing Header",
			authHeader:     "",
			expectedStatus: http.StatusUnauthorized,
		},
		{
			name:           "Failure - Invalid Format",
			authHeader:     "Token my-token", // missing "Bearer"
			expectedStatus: http.StatusUnauthorized,
		},
		{
			name:       "Failure - Token Not Found",
			authHeader: "Bearer ghost-token",
			mockFunc: func(ctx context.Context, token string) (*model.Session, error) {
				return nil, errors.New("not found")
			},
			expectedStatus: http.StatusUnauthorized,
		},
		{
			name:       "Failure - Token Expired",
			authHeader: "Bearer old-token",
			mockFunc: func(ctx context.Context, token string) (*model.Session, error) {
				return &model.Session{
					UserID:    userID,
					ExpiresAt: time.Now().Add(-1 * time.Hour), // 1h ago
				}, nil
			},
			expectedStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {

			mockRepo := &MockSessionStore{GetByTokenFunc: tt.mockFunc}
			middleware := NewAuthMiddleware(mockRepo)

			// dummy handler
			handler := middleware.Authenticate(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// middleware passed
				w.WriteHeader(http.StatusOK)

				// check if UserID was correctly injected into context
				gotID, ok := GetUserID(r.Context())
				if !ok || gotID != userID {
					t.Errorf("Authenticate() context did not have expected UserID")
				}
			}))

			// HTTP request
			req := httptest.NewRequest(http.MethodGet, "/any-path", nil)
			if tt.authHeader != "" {
				req.Header.Set("Authorization", tt.authHeader)
			}

			// "Recorder" to capture the response
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			if rr.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, rr.Code)
			}
		})
	}
}
