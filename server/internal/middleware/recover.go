package middleware

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"runtime/debug"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/gorilla/mux"
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
			// Log the route pattern (e.g. /albums/{id}/epoch) instead of the
			// resolved path so album_id / media_id never leak into log lines
			slog.ErrorContext(r.Context(), "handler panic recovered",
				"request_id", GetRequestID(r.Context()),
				"route", routeTemplate(r),
				"method", r.Method,
				"cause", cause.Error(),
				"stack", string(debug.Stack()),
			)
			apierr.Write(w, r, apierr.Internal("internal server error").WithCause(cause))
		}()

		next.ServeHTTP(w, r)
	})
}

func routeTemplate(r *http.Request) string {
	if route := mux.CurrentRoute(r); route != nil {
		if t, err := route.GetPathTemplate(); err == nil && t != "" {
			return t
		}
	}
	return "?"
}

var ErrIfNotWritten = errors.New("handler returned without writing a response")
