package middleware

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/mux"
)

func captureAccessLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	buf := &bytes.Buffer{}
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return buf
}

func decodeAccessLog(t *testing.T, buf *bytes.Buffer) map[string]any {
	t.Helper()
	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &line); err != nil {
		t.Fatalf("decode access log: %v", err)
	}
	return line
}

func TestAccessLogUsesRouteTemplateAndResponseMetadata(t *testing.T) {
	buf := captureAccessLogs(t)
	router := mux.NewRouter()
	router.Use(RequestID, AccessLog)
	api := router.PathPrefix("/api/v1").Subrouter()
	api.HandleFunc("/albums/{id}/media", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte("ok"))
	}).Methods(http.MethodGet)

	albumID := "6f1b7c2e-0000-4000-8000-000000000001"
	secret := "secret-ticket"
	request := httptest.NewRequest(
		http.MethodGet,
		"/api/v1/albums/"+albumID+"/media?ticket="+secret,
		nil,
	)
	request.Header.Set(RequestIDHeader, "abcdef0123456789abcdef0123456789")
	router.ServeHTTP(httptest.NewRecorder(), request)

	line := decodeAccessLog(t, buf)
	if line["route"] != "/api/v1/albums/{id}/media" {
		t.Fatalf("route = %v", line["route"])
	}
	if line["status"] != float64(http.StatusAccepted) || line["bytes"] != float64(2) {
		t.Fatalf("response metadata = status %v bytes %v", line["status"], line["bytes"])
	}
	if line["client_trace_id"] != "abcdef0123456789abcdef0123456789" {
		t.Fatalf("client_trace_id = %v", line["client_trace_id"])
	}
	if line["request_id"] == "" || line["request_id"] == line["client_trace_id"] {
		t.Fatalf("request_id must be server minted, got %v", line["request_id"])
	}
	if strings.Contains(buf.String(), albumID) || strings.Contains(buf.String(), secret) {
		t.Fatalf("private URL data reached the log: %s", buf.String())
	}
}

func TestAccessLogRecordsASuccessfulHijackAs101(t *testing.T) {
	recorder := &statusRecorder{
		ResponseWriter: okHijackableWriter{httptest.NewRecorder()},
		status:         http.StatusOK,
	}
	if _, _, err := recorder.Hijack(); err != nil {
		t.Fatalf("hijack error = %v", err)
	}
	if !recorder.hijacked {
		t.Fatal("a successful hijack was not recorded as hijacked")
	}
	if recorder.status != http.StatusSwitchingProtocols {
		t.Fatalf("status = %d, want %d", recorder.status, http.StatusSwitchingProtocols)
	}
}

func TestAccessLogRecordsAPanicAs500(t *testing.T) {
	buf := captureAccessLogs(t)
	router := mux.NewRouter()
	router.Use(AccessLog)
	router.HandleFunc("/boom", func(http.ResponseWriter, *http.Request) {
		panic("handler exploded")
	}).Methods(http.MethodGet)

	request := httptest.NewRequest(http.MethodGet, "/boom", nil)
	func() {
		defer func() {
			if recover() == nil {
				t.Error("panic must be re-raised for Recover to handle")
			}
		}()
		router.ServeHTTP(httptest.NewRecorder(), request)
	}()

	line := decodeAccessLog(t, buf)
	if line["status"] != float64(http.StatusInternalServerError) {
		t.Fatalf("status = %v, want 500", line["status"])
	}
	if line["panic"] != true {
		t.Fatalf("panic flag = %v", line["panic"])
	}
	if line["route"] != "/boom" {
		t.Fatalf("route = %v", line["route"])
	}
}

type okHijackableWriter struct{ http.ResponseWriter }

func (okHijackableWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return nil, nil, nil
}
