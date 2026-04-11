package service

import (
	"context"
	"errors"
	"testing"
	"time"

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
	GetByEmailFunc func(ctx context.Context, email string) (*model.User, error)
	CreateFunc     func(ctx context.Context, user *model.User) error
}

func (m *MockUserStore) GetByEmail(ctx context.Context, e string) (*model.User, error) {
	return m.GetByEmailFunc(ctx, e)
}
func (m *MockUserStore) Create(ctx context.Context, u *model.User) error { return m.CreateFunc(ctx, u) }

type MockSessionStore struct {
	CreateFunc func(ctx context.Context, session *model.Session) error
}

func (m *MockSessionStore) Create(ctx context.Context, s *model.Session) error {
	return m.CreateFunc(ctx, s)
}

type MockEmailService struct {
	SendOTPFunc func(email, otp string) error
}

func (m *MockEmailService) SendOTP(e, o string) error { return m.SendOTPFunc(e, o) }

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
					GetByEmailFunc: func(ctx context.Context, e string) (*model.User, error) {
						return &model.User{ID: uuid.New(), Email: email}, nil
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
					GetByEmailFunc: func(ctx context.Context, e string) (*model.User, error) {
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
			s := NewAuthService(tt.mockOTP(), tt.mockUser(), tt.mockSession(), &MockEmailService{})

			token, err := s.VerifyOTP(context.Background(), email, tt.otp, "test-device")

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("VerifyOTP() error = %v, wantErr %v", err, tt.wantErr)
				}
				return
			}

			if err != nil {
				t.Fatalf("VerifyOTP() unexpected error: %v", err)
			}

			if token == "" {
				t.Errorf("VerifyOTP() returned empty token on success")
			}
		})
	}
}
