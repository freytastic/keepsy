package middleware

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"runtime/debug"

	"github.com/freytastic/keepsy/internal/apierr"
)

// Recover converts handler panics into E_INTERNAL responses
func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			rec := recover()
			if rec == nil {
				return
			}
			var cause error
			switch v := rec.(type) {
			case error:
				cause = v
			default:
				cause = fmt.Errorf("panic: %v", v)
			}
			slog.ErrorContext(r.Context(), "handler panic recovered",
				"request_id", GetRequestID(r.Context()),
				"path", r.URL.Path,
				"method", r.Method,
				"cause", cause.Error(),
				"stack", string(debug.Stack()),
			)
			apierr.Write(w, r, apierr.Internal("internal server error").WithCause(cause))
		}()

		next.ServeHTTP(w, r)
	})
}

var ErrIfNotWritten = errors.New("handler returned without writing a response")
