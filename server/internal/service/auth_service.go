package service

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"log"
	"math/big"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
)

var (
	ErrInvalidOTP      = errors.New("invalid or expired OTP")
	ErrTooManyRequests = errors.New("too many requests, please try again later")
)

// repository interfaces to allow for mocking in tests
type OTPStore interface {
	SetOTP(ctx context.Context, email, otp string, ttl time.Duration) error
	GetOTP(ctx context.Context, email string) (string, error)
	DeleteOTP(ctx context.Context, email string) error
	CheckRateLimit(ctx context.Context, email string) (bool, error)
}

type AuthUserStore interface {
	GetByEmail(ctx context.Context, email string) (*model.User, error)
	Create(ctx context.Context, user *model.User) error
}

type SessionStore interface {
	Create(ctx context.Context, session *model.Session) error
	GetByToken(ctx context.Context, token string) (*model.Session, error)
	DeleteByToken(ctx context.Context, token string) error
}

type AuthService struct {
	OTPRepo      OTPStore
	UserRepo     AuthUserStore
	SessionRepo  SessionStore
	EmailService EmailService
}

func NewAuthService(otpRepo OTPStore, userRepo AuthUserStore, sessionRepo SessionStore, emailService EmailService) *AuthService {
	return &AuthService{
		OTPRepo:      otpRepo,
		UserRepo:     userRepo,
		SessionRepo:  sessionRepo,
		EmailService: emailService,
	}
}

func (s *AuthService) RequestOTP(ctx context.Context, email string) error {
	// Internal failure logs intentionally drop the email + OTP : the server is
	// the one place these two are joinable to a real identity, and a leaked
	// log line should never become a re identification attack
	allowed, err := s.OTPRepo.CheckRateLimit(ctx, email)
	if err != nil {
		log.Printf("RequestOTP: rate limit check failed: %v", err)
		return err
	}
	if !allowed {
		return ErrTooManyRequests
	}

	otp, err := generateOTP(6)
	if err != nil {
		log.Printf("RequestOTP: generate failed: %v", err)
		return err
	}

	if err := s.OTPRepo.SetOTP(ctx, email, otp, 5*time.Minute); err != nil {
		log.Printf("RequestOTP: store failed: %v", err)
		return err
	}

	if err := s.EmailService.SendOTP(email, otp); err != nil {
		log.Printf("RequestOTP: send failed: %v", err)
		return err
	}

	return nil
}

func (s *AuthService) VerifyOTP(ctx context.Context, email, otp string) (string, error) {
	storedOTP, err := s.OTPRepo.GetOTP(ctx, email)
	if err != nil {
		// Intentionally no email/otp in the log line
		return "", ErrInvalidOTP
	}

	if storedOTP != otp {
		// Same : no email, never the OTP value
		return "", ErrInvalidOTP
	}

	_ = s.OTPRepo.DeleteOTP(ctx, email)

	user, err := s.UserRepo.GetByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			user = &model.User{
				Email:       email,
				AccentColor: "#2dd4bf",
				Theme:       "dark",
			}
			if err := s.UserRepo.Create(ctx, user); err != nil {
				log.Printf("VerifyOTP: user create failed: %v", err)
				return "", err
			}
		} else {
			log.Printf("VerifyOTP: user fetch failed: %v", err)
			return "", err
		}
	}

	token, err := generateToken(32)
	if err != nil {
		return "", err
	}

	session := &model.Session{
		UserID:    user.ID,
		TokenHash: repository.HashToken(token),
		ExpiresAt: time.Now().Add(30 * 24 * time.Hour),
	}

	if err := s.SessionRepo.Create(ctx, session); err != nil {
		log.Printf("VerifyOTP: session create failed: %v", err)
		return "", err
	}

	return token, nil
}

func (s *AuthService) RefreshSession(ctx context.Context, refreshToken string) (string, string, time.Time, error) {
	session, err := s.SessionRepo.GetByToken(ctx, refreshToken)
	if err != nil {
		return "", "", time.Time{}, errors.New("unauthorized")
	}

	if time.Now().After(session.ExpiresAt) {
		return "", "", time.Time{}, errors.New("unauthorized")
	}

	_ = s.SessionRepo.DeleteByToken(ctx, refreshToken)

	newToken, err := generateToken(32)
	if err != nil {
		return "", "", time.Time{}, err
	}

	newExpiresAt := time.Now().Add(30 * 24 * time.Hour)
	newSession := &model.Session{
		UserID:    session.UserID,
		TokenHash: repository.HashToken(newToken),
		ExpiresAt: newExpiresAt,
	}

	if err := s.SessionRepo.Create(ctx, newSession); err != nil {
		log.Printf("RefreshSession: session create failed: %v", err)
		return "", "", time.Time{}, err
	}

	// opaque token acts as both access and refresh token
	return newToken, newToken, newExpiresAt, nil
}

func generateOTP(length int) (string, error) {
	const digits = "0123456789"
	result := make([]byte, length)
	for i := range result {
		num, err := rand.Int(rand.Reader, big.NewInt(int64(len(digits))))
		if err != nil {
			return "", err
		}
		result[i] = digits[num.Int64()]
	}
	return string(result), nil
}

func generateToken(length int) (string, error) {
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.URLEncoding.EncodeToString(b), nil
}
