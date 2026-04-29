package apierr

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
)

type ctxKey string

const requestIDKey ctxKey = "request_id"

// Write serializes err as JSON and writes it to w
func Write(w http.ResponseWriter, r *http.Request, err error) {
	var ae *APIError
	if !errors.As(err, &ae) {
		ae = Internal("internal error").WithCause(err)
	}

	logEnvelope(r.Context(), ae)

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(ae.HTTPStatus)

	body := struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Detail  map[string]any `json:"detail,omitempty"`
	}{
		Code:    ae.Code,
		Message: ae.Message,
		Detail:  ae.Detail,
	}
	if encErr := json.NewEncoder(w).Encode(body); encErr != nil {
		slog.ErrorContext(r.Context(), "apierr.Write: encode failed",
			"code", ae.Code, "encode_error", encErr.Error())
	}
}

func logEnvelope(ctx context.Context, ae *APIError) {
	rid, _ := ctx.Value(requestIDKey).(string)
	level := slog.LevelInfo
	switch ae.Code {
	case "E_INTERNAL":
		level = slog.LevelError
	case "E_VALIDATION", "E_AUTH":
		level = slog.LevelInfo
	default:
		level = slog.LevelWarn
	}
	attrs := []any{
		"code", ae.Code,
		"http_status", ae.HTTPStatus,
		"message", ae.Message,
	}
	if rid != "" {
		attrs = append(attrs, "request_id", rid)
	}
	if ae.Cause != nil {
		attrs = append(attrs, "cause", ae.Cause.Error())
	}
	if ae.Detail != nil {
		attrs = append(attrs, "detail", ae.Detail)
	}
	slog.Log(ctx, level, "apierr", attrs...)
}
