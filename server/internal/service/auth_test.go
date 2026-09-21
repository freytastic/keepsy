package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/handle"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

type MockOTPStore struct {
	SetOTPFunc         func(ctx context.Context, email, otp string, ttl time.Duration) error
	GetOTPFunc         func(ctx context.Context, email string) (string, error)
	DeleteOTPFunc      func(ctx context.Context, email string) error
	CheckRateLimitFunc func(ctx context.Context, email string) (bool, error)
}

func (m *MockOTPStore) SetOTP(ctx context.Context, e, o string, t time.Duration) error {
	return m.SetOTPFunc(ctx, e, o, t)
}
func (m *MockOTPStore) GetOTP(ctx context.Context, e string) (string, error) {
	return m.GetOTPFunc(ctx, e)
}
func (m *MockOTPStore) DeleteOTP(ctx context.Context, e string) error { return m.DeleteOTPFunc(ctx, e) }
func (m *MockOTPStore) CheckRateLimit(ctx context.Context, e string) (bool, error) {
	return m.CheckRateLimitFunc(ctx, e)
}

type MockUserStore struct {
	GetByEmailHMACFunc func(ctx context.Context, hmac []byte) (*model.User, error)
	CreateFunc         func(ctx context.Context, user *model.User) error
}

func (m *MockUserStore) GetByEmailHMAC(ctx context.Context, h []byte) (*model.User, error) {
	return m.GetByEmailHMACFunc(ctx, h)
}
func (m *MockUserStore) Create(ctx context.Context, u *model.User) error { return m.CreateFunc(ctx, u) }

type MockSessionStore struct {
	CreateFunc        func(ctx context.Context, session *model.Session) error
	GetByTokenFunc    func(ctx context.Context, token string) (*model.Session, error)
	DeleteByTokenFunc func(ctx context.Context, token string) error
	ExtendByTokenFunc func(ctx context.Context, token string, expiresAt time.Time) error
}

func (m *MockSessionStore) ExtendByToken(ctx context.Context, token string, expiresAt time.Time) error {
	if m.ExtendByTokenFunc != nil {
		return m.ExtendByTokenFunc(ctx, token, expiresAt)
	}
	return nil
}

func (m *MockSessionStore) Create(ctx context.Context, s *model.Session) error {
	return m.CreateFunc(ctx, s)
}
func (m *MockSessionStore) GetByToken(ctx context.Context, token string) (*model.Session, error) {
	if m.GetByTokenFunc != nil {
		return m.GetByTokenFunc(ctx, token)
	}
	return nil, errors.New("not implemented")
}
func (m *MockSessionStore) DeleteByToken(ctx context.Context, token string) error {
	if m.DeleteByTokenFunc != nil {
		return m.DeleteByTokenFunc(ctx, token)
	}
	return nil
}

type MockEmailService struct {
	SendOTPFunc func(email, otp string) error
}

func (m *MockEmailService) SendOTP(e, o string) error { return m.SendOTPFunc(e, o) }

// testHMACKey : 32 bytes, deterministic so tests are reproducible
var testHMACKey = []byte("test-email-hmac-key-32-bytes!!!!")

func TestAuthService_VerifyOTP(t *testing.T) {
	email := "test@example.com"
	correctOTP := "123456"

	tests := []struct {
		name          string
		otp           string
		mockOTP       func() *MockOTPStore
		mockUser      func() *MockUserStore
		mockSession   func() *MockSessionStore
		wantErr       error
		expectNewUser bool
	}{
		{
			name: "Success : Existing User",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					GetOTPFunc:    func(ctx context.Context, e string) (string, error) { return correctOTP, nil },
					DeleteOTPFunc: func(ctx context.Context, e string) error { return nil },
				}
			},
			mockUser: func() *MockUserStore {
				return &MockUserStore{
					GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
						return &model.User{ID: uuid.New()}, nil
					},
				}
			},
			mockSession: func() *MockSessionStore {
				return &MockSessionStore{
					CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
				}
			},
			wantErr:       nil,
			expectNewUser: false,
		},
		{
			name: "Success : New User Created",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					GetOTPFunc:    func(ctx context.Context, e string) (string, error) { return correctOTP, nil },
					DeleteOTPFunc: func(ctx context.Context, e string) error { return nil },
				}
			},
			mockUser: func() *MockUserStore {
				return &MockUserStore{
					GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
						return nil, repository.ErrUserNotFound
					},
					CreateFunc: func(ctx context.Context, u *model.User) error {
						u.ID = uuid.New()
						return nil
					},
				}
			},
			mockSession: func() *MockSessionStore {
				return &MockSessionStore{
					CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
				}
			},
			wantErr:       nil,
			expectNewUser: true,
		},
		{
			name: "Failure : Wrong OTP",
			otp:  "wrong",
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					GetOTPFunc: func(ctx context.Context, e string) (string, error) { return correctOTP, nil },
				}
			},
			mockUser:    func() *MockUserStore { return &MockUserStore{} },
			mockSession: func() *MockSessionStore { return &MockSessionStore{} },
			wantErr:     ErrInvalidOTP,
		},
		{
			name: "Failure : OTP Expired (Not in Redis)",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					GetOTPFunc: func(ctx context.Context, e string) (string, error) { return "", errors.New("not found") },
				}
			},
			mockUser:    func() *MockUserStore { return &MockUserStore{} },
			mockSession: func() *MockSessionStore { return &MockSessionStore{} },
			wantErr:     ErrInvalidOTP,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAuthService(tt.mockOTP(), tt.mockUser(), tt.mockSession(), &MockEmailService{}, testHMACKey)

			got, err := s.VerifyOTP(context.Background(), email, tt.otp)

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("VerifyOTP() error = %v, wantErr %v", err, tt.wantErr)
				}
				return
			}

			if err != nil {
				t.Fatalf("VerifyOTP() unexpected error: %v", err)
			}

			if got.Token == "" {
				t.Errorf("VerifyOTP() returned empty token on success")
			}
		})
	}
}

func TestAuthService_VerifyOTP_KeepsyIDCollisionRetry(t *testing.T) {
	correctOTP := "123456"
	calls := 0
	var lastUser *model.User

	userStore := &MockUserStore{
		GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
			return nil, repository.ErrUserNotFound
		},
		CreateFunc: func(ctx context.Context, u *model.User) error {
			calls++
			lastUser = u
			if calls == 1 {
				return repository.ErrKeepsyIDTaken
			}
			u.ID = uuid.New()
			return nil
		},
	}
	otpStore := &MockOTPStore{
		GetOTPFunc:    func(ctx context.Context, e string) (string, error) { return correctOTP, nil },
		DeleteOTPFunc: func(ctx context.Context, e string) error { return nil },
	}
	sessStore := &MockSessionStore{
		CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
	}

	s := NewAuthService(otpStore, userStore, sessStore, &MockEmailService{}, testHMACKey)
	got, err := s.VerifyOTP(context.Background(), "new@example.com", correctOTP)
	if err != nil {
		t.Fatalf("VerifyOTP unexpected err: %v", err)
	}
	if got.Token == "" {
		t.Fatal("empty token on success")
	}
	if calls != 2 {
		t.Fatalf("Create called %d times, want 2 (collision + retry)", calls)
	}
	if lastUser == nil || len(lastUser.KeepsyID) != handle.Length {
		t.Fatalf("user.KeepsyID not set to a valid handle: %+v", lastUser)
	}
}

// VerifyOTP must identify the account before the client persists credentials
func TestAuthService_VerifyOTP_ReturnsUserIDAndSessionExpiry(t *testing.T) {
	correctOTP := "123456"
	userID := uuid.New()
	var created *model.Session

	otpStore := &MockOTPStore{
		GetOTPFunc:    func(ctx context.Context, e string) (string, error) { return correctOTP, nil },
		DeleteOTPFunc: func(ctx context.Context, e string) error { return nil },
	}
	userStore := &MockUserStore{
		GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
			return &model.User{ID: userID}, nil
		},
	}
	sessStore := &MockSessionStore{
		CreateFunc: func(ctx context.Context, s *model.Session) error {
			created = s
			return nil
		},
	}

	s := NewAuthService(otpStore, userStore, sessStore, &MockEmailService{}, testHMACKey)
	got, err := s.VerifyOTP(context.Background(), "test@example.com", correctOTP)
	if err != nil {
		t.Fatalf("VerifyOTP unexpected error: %v", err)
	}

	if got.UserID != userID {
		t.Errorf("UserID = %v, want %v", got.UserID, userID)
	}
	if got.Token == "" {
		t.Error("Token is empty")
	}
	// Return the exact persisted expiry
	if !got.ExpiresAt.Equal(created.ExpiresAt) {
		t.Errorf("ExpiresAt = %v, want the created session's %v", got.ExpiresAt, created.ExpiresAt)
	}
}

// A lost refresh response must be retryable with the same token
func TestAuthService_RefreshSession_ExtendsInPlaceAndIsRetrySafe(t *testing.T) {
	const token = "existing-opaque-token"
	userID := uuid.New()
	oldExpiry := time.Now().Add(10 * 24 * time.Hour)
	deleted := false
	var extendedTo time.Time

	sessStore := &MockSessionStore{
		GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
			if tk != token {
				return nil, errors.New("not found")
			}
			return &model.Session{UserID: userID, ExpiresAt: oldExpiry}, nil
		},
		DeleteByTokenFunc: func(ctx context.Context, tk string) error {
			deleted = true
			return nil
		},
		ExtendByTokenFunc: func(ctx context.Context, tk string, exp time.Time) error {
			extendedTo = exp
			return nil
		},
	}

	s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, sessStore, &MockEmailService{}, testHMACKey)
	gotToken, gotRefresh, gotExpiry, err := s.RefreshSession(context.Background(), token)
	if err != nil {
		t.Fatalf("RefreshSession unexpected error: %v", err)
	}

	if gotToken != token || gotRefresh != token {
		t.Errorf("token rotated to %q/%q, want the same %q kept valid", gotToken, gotRefresh, token)
	}
	if deleted {
		t.Error("DeleteByToken was called: a retried refresh would find the session gone")
	}
	if !gotExpiry.After(oldExpiry) {
		t.Errorf("expiry %v did not slide past %v", gotExpiry, oldExpiry)
	}
	if !extendedTo.Equal(gotExpiry) {
		t.Errorf("persisted expiry %v does not match returned %v", extendedTo, gotExpiry)
	}
}

// A session deleted during refresh must not be reported as renewed
func TestAuthService_RefreshSession_FailsWhenTheSessionVanished(t *testing.T) {
	const token = "vanishing-token"
	sessStore := &MockSessionStore{
		GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
			return &model.Session{
				UserID:    uuid.New(),
				ExpiresAt: time.Now().Add(10 * 24 * time.Hour),
			}, nil
		},
		ExtendByTokenFunc: func(ctx context.Context, tk string, exp time.Time) error {
			return repository.ErrSessionNotFound
		},
	}

	s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, sessStore, &MockEmailService{}, testHMACKey)
	gotToken, _, _, err := s.RefreshSession(context.Background(), token)
	if err == nil {
		t.Fatal("RefreshSession reported success for a session that no longer exists")
	}
	if gotToken != "" {
		t.Errorf("token = %q, want empty on failure", gotToken)
	}
}

// Database failures must not become ErrSessionInvalid and trigger logout
func TestAuthService_RefreshSession_SeparatesDeadSessionFromBrokenDatabase(t *testing.T) {
	dbDown := errors.New("connection refused")

	tests := []struct {
		name        string
		sess        *MockSessionStore
		wantInvalid bool
	}{
		{
			name: "unknown token is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return nil, repository.ErrSessionNotFound
				},
			},
			wantInvalid: true,
		},
		{
			name: "expired session is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(-time.Hour)}, nil
				},
			},
			wantInvalid: true,
		},
		{
			name: "session that vanished mid refresh is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(time.Hour)}, nil
				},
				ExtendByTokenFunc: func(ctx context.Context, tk string, e time.Time) error {
					return repository.ErrSessionNotFound
				},
			},
			wantInvalid: true,
		},
		{
			name: "a read failure is NOT an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return nil, dbDown
				},
			},
			wantInvalid: false,
		},
		{
			name: "a write failure is NOT an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(time.Hour)}, nil
				},
				ExtendByTokenFunc: func(ctx context.Context, tk string, e time.Time) error {
					return dbDown
				},
			},
			wantInvalid: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, tt.sess, &MockEmailService{}, testHMACKey)
			_, _, _, err := s.RefreshSession(context.Background(), "tok")
			if err == nil {
				t.Fatal("expected an error")
			}
			if got := errors.Is(err, ErrSessionInvalid); got != tt.wantInvalid {
				t.Errorf("errors.Is(err, ErrSessionInvalid) = %v, want %v (err = %v)",
					got, tt.wantInvalid, err)
			}
		})
	}
}
