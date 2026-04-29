package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/service"
)

type AuthHandler struct {
	AuthService *service.AuthService
}

func NewAuthHandler(authService *service.AuthService) *AuthHandler {
	return &AuthHandler{AuthService: authService}
}

type RequestOTPPayload struct {
	Email string `json:"email"`
}

func (h *AuthHandler) RequestOTP(w http.ResponseWriter, r *http.Request) {
	var payload RequestOTPPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	payload.Email = strings.ToLower(strings.TrimSpace(payload.Email))
	if payload.Email == "" {
		apierr.Write(w, r, apierr.Validation("email is required"))
		return
	}

	err := h.AuthService.RequestOTP(r.Context(), payload.Email)
	if err != nil {
		if errors.Is(err, service.ErrTooManyRequests) {
			apierr.Write(w, r, apierr.RateLimited(err.Error()))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to request OTP").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"message": "OTP sent"})
}

type VerifyOTPPayload struct {
	Email      string `json:"email"`
	OTP        string `json:"otp"`
	DeviceInfo string `json:"device_info"`
}

func (h *AuthHandler) VerifyOTP(w http.ResponseWriter, r *http.Request) {
	var payload VerifyOTPPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	payload.Email = strings.ToLower(strings.TrimSpace(payload.Email))
	if payload.Email == "" || payload.OTP == "" {
		apierr.Write(w, r, apierr.Validation("email and otp are required"))
		return
	}

	token, err := h.AuthService.VerifyOTP(r.Context(), payload.Email, payload.OTP, payload.DeviceInfo)
	if err != nil {
		if errors.Is(err, service.ErrInvalidOTP) {
			apierr.Write(w, r, apierr.Auth("invalid or expired OTP"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to verify OTP").WithCause(err))
		return
	}
	expiresAt := time.Now().Add(30 * 24 * time.Hour).Format(time.RFC3339)
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"token":        token,
		"refreshToken": token,
		"expiresAt":    expiresAt,
	})
}

type RefreshRequest struct {
	RefreshToken string `json:"refreshToken"`
	DeviceInfo   string `json:"deviceInfo"`
}

type RefreshResponse struct {
	Token        string `json:"token"`
	RefreshToken string `json:"refreshToken"`
	ExpiresAt    string `json:"expiresAt"`
}

func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var payload RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	if payload.RefreshToken == "" {
		apierr.Write(w, r, apierr.Validation("refresh token is required"))
		return
	}

	newToken, newRefreshToken, expiresAt, err := h.AuthService.RefreshSession(r.Context(), payload.RefreshToken, payload.DeviceInfo)
	if err != nil {
		apierr.Write(w, r, apierr.Auth("invalid or expired refresh token").WithCause(err))
		return
	}

	resp := RefreshResponse{
		Token:        newToken,
		RefreshToken: newRefreshToken,
		ExpiresAt:    expiresAt.Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}
