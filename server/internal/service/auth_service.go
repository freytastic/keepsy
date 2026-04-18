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
	// check rate limit
	allowed, err := s.OTPRepo.CheckRateLimit(ctx, email)
	if err != nil {
		log.Printf("Error checking rate limit: %v", err)
		return err
	}
	if !allowed {
		return ErrTooManyRequests
	}

	otp, err := generateOTP(6)
	if err != nil {
		log.Printf("Error generating OTP: %v", err)
		return err
	}

	// store OTP in Redis with 5 mins TTL
	err = s.OTPRepo.SetOTP(ctx, email, otp, 5*time.Minute)
	if err != nil {
		log.Printf("Error storing OTP in Redis: %v", err)
		return err
	}

	// send the email
	err = s.EmailService.SendOTP(email, otp)
	if err != nil {
		log.Printf("Error sending email: %v", err)
		return err
	}

	return nil
}

func (s *AuthService) VerifyOTP(ctx context.Context, email, otp, deviceInfo string) (string, error) {
	storedOTP, err := s.OTPRepo.GetOTP(ctx, email)
	if err != nil {
		log.Printf("VerifyOTP: OTP not found in Redis for %s: %v", email, err)
		return "", ErrInvalidOTP
	}

	if storedOTP != otp {
		log.Printf("VerifyOTP: OTP mismatch for %s. Expected %s, got %s", email, storedOTP, otp)
		return "", ErrInvalidOTP
	}

	// success, del OTP from redis so it cant be used again
	_ = s.OTPRepo.DeleteOTP(ctx, email)

	// OTP verified, check if user exists or create new one
	user, err := s.UserRepo.GetByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			log.Printf("VerifyOTP: Creating new user for %s", email)
			// create new user
			user = &model.User{
				Email:       email,
				AccentColor: "#2dd4bf",
				Theme:       "dark",
			}
			err = s.UserRepo.Create(ctx, user)
			if err != nil {
				log.Printf("VerifyOTP: Failed to create user: %v", err)
				return "", err
			}
		} else {
			log.Printf("VerifyOTP: Database error fetching user: %v", err)
			return "", err
		}
	}

	// create session
	token, err := generateToken(32)
	if err != nil {
		return "", err
	}

	session := &model.Session{
		UserID:     user.ID,
		TokenHash:  repository.HashToken(token),
		DeviceInfo: deviceInfo,
		ExpiresAt:  time.Now().Add(30 * 24 * time.Hour), // 30 days
	}

	err = s.SessionRepo.Create(ctx, session)
	if err != nil {
		log.Printf("VerifyOTP: Failed to create session: %v", err)
		return "", err
	}

	return token, nil
}

func (s *AuthService) RefreshSession(ctx context.Context, refreshToken, deviceInfo string) (string, string, time.Time, error) {
	session, err := s.SessionRepo.GetByToken(ctx, refreshToken)

	if err != nil {
		log.Printf("RefreshSession: session not found or db error: %v", err)
		return "", "", time.Time{}, errors.New("unauthorized")
	}

	if time.Now().After(session.ExpiresAt) {
		log.Printf("RefreshSession: session expired")
		return "", "", time.Time{}, errors.New("unauthorized")
	}

	// delete old session
	_ = s.SessionRepo.DeleteByToken(ctx, refreshToken)
	
	// create new session sliding it by another 30 days
	newToken, err := generateToken(32)
	if err != nil {
		return "", "", time.Time{}, err
	}

	newExpiresAt := time.Now().Add(30 * 24 * time.Hour)
	newSession := &model.Session{
		UserID:     session.UserID,
		TokenHash:  repository.HashToken(newToken),
		DeviceInfo: deviceInfo,
		ExpiresAt:  newExpiresAt,
	}

	err = s.SessionRepo.Create(ctx, newSession)
	if err != nil {
		log.Printf("RefreshSession: failed to create new session: %v", err)
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
