package service

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log"
	"math/big"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/handle"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

const maxKeepsyIDAttempts = 5

// Successful refreshes extend this sliding lifetime
const sessionTTL = 30 * 24 * time.Hour

var (
	ErrInvalidOTP      = errors.New("invalid or expired OTP")
	ErrAccountDeleting = errors.New("account is being deleted")
	ErrTooManyRequests = errors.New("too many requests, please try again later")
	// ErrSessionInvalid marks failures that may invalidate client credentials
	ErrSessionInvalid = errors.New("invalid or expired session")
)

// repository interfaces to allow for mocking in tests
type OTPStore interface {
	SetOTP(ctx context.Context, email, otp string, ttl time.Duration) error
	GetOTP(ctx context.Context, email string) (string, error)
	DeleteOTP(ctx context.Context, email string) error
	CheckRateLimit(ctx context.Context, email string) (bool, error)
}

type AuthUserStore interface {
	GetByEmailHMAC(ctx context.Context, hmac []byte) (*model.User, error)
	Create(ctx context.Context, user *model.User) error
}

type SessionStore interface {
	Create(ctx context.Context, session *model.Session) error
	GetByToken(ctx context.Context, token string) (*model.Session, error)
	DeleteByToken(ctx context.Context, token string) error
	ExtendByToken(ctx context.Context, token string, expiresAt time.Time) error
}

type AuthService struct {
	OTPRepo      OTPStore
	UserRepo     AuthUserStore
	SessionRepo  SessionStore
	EmailService EmailService
	emailHMACKey []byte
}

func NewAuthService(otpRepo OTPStore, userRepo AuthUserStore, sessionRepo SessionStore, emailService EmailService, emailHMACKey []byte) *AuthService {
	if len(emailHMACKey) < 32 {
		panic("auth service: emailHMACKey must be >= 32 bytes")
	}
	return &AuthService{
		OTPRepo:      otpRepo,
		UserRepo:     userRepo,
		SessionRepo:  sessionRepo,
		EmailService: emailService,
		emailHMACKey: emailHMACKey,
	}
}

// HashEmail computes HMAC-SHA256(emailHMACKey, lower(trim(email))). The
// caller must pass the user supplied email exactly once : after the HMAC
// is in hand the plaintext can be discarded
func (s *AuthService) HashEmail(email string) []byte {
	mac := hmac.New(sha256.New, s.emailHMACKey)
	mac.Write([]byte(strings.ToLower(strings.TrimSpace(email))))
	return mac.Sum(nil)
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

// VerifiedSession identifies the account before credentials are persisted
type VerifiedSession struct {
	UserID    uuid.UUID
	Token     string
	ExpiresAt time.Time
}

func (s *AuthService) VerifyOTP(ctx context.Context, email, otp string) (VerifiedSession, error) {
	storedOTP, err := s.OTPRepo.GetOTP(ctx, email)
	if err != nil {
		// Intentionally no email/otp in the log line
		return VerifiedSession{}, ErrInvalidOTP
	}

	if storedOTP != otp {
		// Same : no email, never the OTP value
		return VerifiedSession{}, ErrInvalidOTP
	}

	_ = s.OTPRepo.DeleteOTP(ctx, email)

	emailHMAC := s.HashEmail(email)
	user, err := s.UserRepo.GetByEmailHMAC(ctx, emailHMAC)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			user = &model.User{EmailHMAC: emailHMAC}
			if err := s.createWithKeepsyID(ctx, user); err != nil {
				log.Printf("VerifyOTP: user create failed: %v", err)
				return VerifiedSession{}, err
			}
		} else {
			log.Printf("VerifyOTP: user fetch failed: %v", err)
			return VerifiedSession{}, err
		}
	}
	if user.DeletingAt != nil {
		return VerifiedSession{}, ErrAccountDeleting
	}

	token, err := generateToken(32)
	if err != nil {
		return VerifiedSession{}, err
	}

	session := &model.Session{
		UserID:    user.ID,
		TokenHash: repository.HashToken(token),
		ExpiresAt: time.Now().Add(sessionTTL),
	}

	if err := s.SessionRepo.Create(ctx, session); err != nil {
		log.Printf("VerifyOTP: session create failed: %v", err)
		return VerifiedSession{}, err
	}

	return VerifiedSession{
		UserID:    user.ID,
		Token:     token,
		ExpiresAt: session.ExpiresAt,
	}, nil
}

// createWithKeepsyID assigns a fresh random keepsy_id and inserts, retrying on
// the (astronomically rare) UNIQUE collision so registration never fails for it
func (s *AuthService) createWithKeepsyID(ctx context.Context, user *model.User) error {
	var err error
	for range maxKeepsyIDAttempts {
		var id string
		if id, err = handle.Generate(rand.Reader); err != nil {
			return err
		}
		user.KeepsyID = id
		if err = s.UserRepo.Create(ctx, user); err == nil {
			return nil
		}
		if !errors.Is(err, repository.ErrKeepsyIDTaken) {
			return err
		}
	}
	return err
}

// RefreshSession extends in place so a lost response can be retried safely
func (s *AuthService) RefreshSession(ctx context.Context, refreshToken string) (string, string, time.Time, error) {
	session, err := s.SessionRepo.GetByToken(ctx, refreshToken)
	if errors.Is(err, repository.ErrSessionNotFound) {
		return "", "", time.Time{}, ErrSessionInvalid
	}
	if err != nil {
		// Preserve repository failures so the client keeps its credentials
		log.Printf("RefreshSession: session read failed: %v", err)
		return "", "", time.Time{}, err
	}

	if time.Now().After(session.ExpiresAt) {
		return "", "", time.Time{}, ErrSessionInvalid
	}

	newExpiresAt := time.Now().Add(sessionTTL)
	if err := s.SessionRepo.ExtendByToken(ctx, refreshToken, newExpiresAt); err != nil {
		if errors.Is(err, repository.ErrSessionNotFound) {
			return "", "", time.Time{}, ErrSessionInvalid
		}
		log.Printf("RefreshSession: session extend failed: %v", err)
		return "", "", time.Time{}, err
	}

	// opaque token acts as both access and refresh token
	return refreshToken, refreshToken, newExpiresAt, nil
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
