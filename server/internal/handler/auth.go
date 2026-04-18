package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

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
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	payload.Email = strings.ToLower(strings.TrimSpace(payload.Email))
	if payload.Email == "" {
		http.Error(w, "email is required", http.StatusBadRequest)
		return
	}

	err := h.AuthService.RequestOTP(r.Context(), payload.Email)
	if err != nil {
		if errors.Is(err, service.ErrTooManyRequests) {
			http.Error(w, err.Error(), http.StatusTooManyRequests)
			return
		}
		http.Error(w, "failed to request OTP", http.StatusInternalServerError)
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
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	payload.Email = strings.ToLower(strings.TrimSpace(payload.Email))
	if payload.Email == "" || payload.OTP == "" {
		http.Error(w, "email and otp are required", http.StatusBadRequest)
		return
	}

	token, expiresAt, err := h.AuthService.VerifyOTP(r.Context(), payload.Email, payload.OTP, payload.DeviceInfo)
	if err != nil {
		if errors.Is(err, service.ErrInvalidOTP) {
			http.Error(w, "invalid or expired OTP", http.StatusUnauthorized)
			return
		}
		http.Error(w, "failed to verify OTP", http.StatusInternalServerError)
		return
	}
	expiresAt := time.Now().Add(30 * 24 * time.Hour).Format(time.RFC3339)
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"token":        token,
		"refreshToken": token, // since token is opaque, it acts as both access and refresh token
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
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if payload.RefreshToken == "" {
		http.Error(w, "refresh token is required", http.StatusBadRequest)
		return
	}

	newToken, newRefreshToken, expiresAt, err := h.AuthService.RefreshSession(r.Context(), payload.RefreshToken, payload.DeviceInfo)
	if err != nil {
		http.Error(w, "invalid or expired refresh token", http.StatusUnauthorized)
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


