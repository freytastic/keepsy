package middleware

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestRecover_PanicBecomesEnvelope : a handler that panics must produce an
// E_INTERNAL JSON envelope, not crash the goroutine and not leak the stack
func TestRecover_PanicBecomesEnvelope(t *testing.T) {
	bad := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	})
	wrapped := Recover(bad)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	// Must not crash the test process
	wrapped.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_INTERNAL" {
		t.Errorf("code = %q, want E_INTERNAL", body.Code)
	}
	// Critical : stack trace must NOT leak into the response body
	if body.Message == "boom" {
		t.Errorf("panic value leaked into response: %q", body.Message)
	}
}

// TestRequestID_GeneratesAndEchoes : an empty header gets a fresh ID; the
// same ID is echoed back in the response and made readable via GetRequestID
func TestRequestID_GeneratesAndEchoes(t *testing.T) {
	var seen string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = GetRequestID(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	wrapped := RequestID(inner)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if seen == "" {
		t.Fatalf("GetRequestID = empty, want non-empty")
	}
	if got := rec.Header().Get(RequestIDHeader); got != seen {
		t.Errorf("response header = %q, want %q", got, seen)
	}
}

// TestRequestID_HonorsClientHeader : a well formed client provided ID is
// preserved (useful for log correlation across services)
func TestRequestID_HonorsClientHeader(t *testing.T) {
	const provided = "deadbeefcafebabe1234567890abcdef"
	var seen string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = GetRequestID(r.Context())
	})
	wrapped := RequestID(inner)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(RequestIDHeader, provided)
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if seen != provided {
		t.Errorf("GetRequestID = %q, want %q", seen, provided)
	}
}

// TestRequestID_RejectsMalformedClientHeader : junk client IDs get replaced
func TestRequestID_RejectsMalformedClientHeader(t *testing.T) {
	var seen string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = GetRequestID(r.Context())
	})
	wrapped := RequestID(inner)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(RequestIDHeader, "not-hex-and-has<bad>chars")
	rec := httptest.NewRecorder()
	wrapped.ServeHTTP(rec, req)

	if seen == "not-hex-and-has<bad>chars" {
		t.Errorf("malformed client id was accepted: %q", seen)
	}
	if len(seen) < 16 {
		t.Errorf("replaced id is too short: %q", seen)
	}
}
