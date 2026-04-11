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

type AuthService struct {
	OTPRepo      *repository.OTPRepository
	UserRepo     *repository.UserRepository
	SessionRepo  *repository.SessionRepository
	EmailService EmailService
}

func NewAuthService(otpRepo *repository.OTPRepository, userRepo *repository.UserRepository, sessionRepo *repository.SessionRepository, emailService EmailService) *AuthService {
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
