package middleware

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
)

type requestIDCtxKey string

const RequestIDKey requestIDCtxKey = "request_id"
const RequestIDHeader = "X-Request-ID"

// RequestID injects a 128 bit hex request ID into the context and response header
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := r.Header.Get(RequestIDHeader)
		if !looksLikeRequestID(rid) {
			rid = newRequestID()
		}
		w.Header().Set(RequestIDHeader, rid)
		ctx := context.WithValue(r.Context(), RequestIDKey, rid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func GetRequestID(ctx context.Context) string {
	if v, ok := ctx.Value(RequestIDKey).(string); ok {
		return v
	}
	return ""
}

func newRequestID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func looksLikeRequestID(s string) bool {
	if len(s) < 16 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'f':
		case c >= 'A' && c <= 'F':
		case c == '-':
		default:
			return false
		}
	}
	return true
}
