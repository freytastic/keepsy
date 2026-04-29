package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAuthHandler_RequestOTP_BadJSON_ReturnsValidationEnvelope(t *testing.T) {
	h := &AuthHandler{AuthService: nil}

	req := httptest.NewRequest(http.MethodPost, "/auth/otp/request",
		bytes.NewReader([]byte("{this is not json")))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	h.RequestOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if got, want := rec.Header().Get("Content-Type"), "application/json; charset=utf-8"; got != want {
		t.Errorf("content-type = %q, want %q", got, want)
	}

	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_VALIDATION" {
		t.Errorf("code = %q, want E_VALIDATION", body.Code)
	}
	if body.Message == "" {
		t.Errorf("message empty")
	}
}

// TestAuthHandler_RequestOTP_MissingEmail_ReturnsValidationEnvelope verifies
// the second validation branch
func TestAuthHandler_RequestOTP_MissingEmail_ReturnsValidationEnvelope(t *testing.T) {
	h := &AuthHandler{AuthService: nil}

	req := httptest.NewRequest(http.MethodPost, "/auth/otp/request",
		bytes.NewReader([]byte(`{"email":"   "}`)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	h.RequestOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_VALIDATION" {
		t.Errorf("code = %q, want E_VALIDATION", body.Code)
	}
	if body.Message != "email is required" {
		t.Errorf("message = %q, want %q", body.Message, "email is required")
	}
}
