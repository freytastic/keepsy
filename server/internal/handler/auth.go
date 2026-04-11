package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

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

	token, err := h.AuthService.VerifyOTP(r.Context(), payload.Email, payload.OTP, payload.DeviceInfo)
	if err != nil {
		if errors.Is(err, service.ErrInvalidOTP) {
			http.Error(w, "invalid or expired OTP", http.StatusUnauthorized)
			return
		}
		http.Error(w, "failed to verify OTP", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"token": token})
}
