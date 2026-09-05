package middleware

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
)

type requestIDCtxKey string

const RequestIDKey requestIDCtxKey = "request_id"
const ClientTraceIDKey requestIDCtxKey = "client_trace_id"
const RequestIDHeader = "X-Request-ID"

// RequestID mints a server ID and stores a valid client ID separately for
// trace correlation
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := newRequestID()
		w.Header().Set(RequestIDHeader, rid)
		ctx := context.WithValue(r.Context(), RequestIDKey, rid)
		if client := r.Header.Get(RequestIDHeader); looksLikeRequestID(client) {
			ctx = context.WithValue(ctx, ClientTraceIDKey, client)
		}
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func GetClientTraceID(ctx context.Context) string {
	if v, ok := ctx.Value(ClientTraceIDKey).(string); ok {
		return v
	}
	return ""
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
