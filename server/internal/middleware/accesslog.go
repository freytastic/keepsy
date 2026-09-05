package middleware

import (
	"bufio"
	"log/slog"
	"net"
	"net/http"
	"time"
)

// AccessLog records route templates so identifiers and query data stay private
func AccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		// Log before re-panicking; Recover writes its 500 after this defer runs
		defer func() {
			panicked := recover()
			if panicked != nil && !recorder.written {
				recorder.status = http.StatusInternalServerError
			}
			level := slog.LevelInfo
			if recorder.status >= 500 {
				level = slog.LevelError
			} else if recorder.status >= 400 {
				level = slog.LevelWarn
			}
			slog.Log(r.Context(), level, "http request",
				"request_id", GetRequestID(r.Context()),
				"client_trace_id", GetClientTraceID(r.Context()),
				"method", r.Method,
				"route", routeTemplate(r),
				"status", recorder.status,
				"bytes", recorder.bytes,
				// WebSocket duration is the full session lifetime
				"hijacked", recorder.hijacked,
				"panic", panicked != nil,
				"dur_ms", time.Since(start).Milliseconds(),
			)
			if panicked != nil {
				panic(panicked)
			}
		}()
		next.ServeHTTP(recorder, r)
	})
}

// statusRecorder preserves interfaces used by WebSocket upgrades
type statusRecorder struct {
	http.ResponseWriter
	status   int
	bytes    int
	written  bool
	hijacked bool
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.written {
		return
	}
	s.written = true
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(body []byte) (int, error) {
	s.written = true
	n, err := s.ResponseWriter.Write(body)
	s.bytes += n
	return n, err
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (s *statusRecorder) Flush() {
	if flusher, ok := s.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := s.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, http.ErrNotSupported
	}
	conn, buf, err := hijacker.Hijack()
	if err == nil {
		// Upgrades bypass WriteHeader
		s.hijacked = true
		s.status = http.StatusSwitchingProtocols
	}
	return conn, buf, err
}
