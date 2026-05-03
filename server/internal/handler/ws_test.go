package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

// mockTickets is a test double for ws.Tickets
type mockTickets struct {
	issueFunc   func(ctx context.Context, userID uuid.UUID) (string, time.Time, error)
	consumeFunc func(ctx context.Context, ticket string) (uuid.UUID, bool)
}

func (m *mockTickets) Issue(ctx context.Context, userID uuid.UUID) (string, time.Time, error) {
	return m.issueFunc(ctx, userID)
}
func (m *mockTickets) Consume(ctx context.Context, ticket string) (uuid.UUID, bool) {
	return m.consumeFunc(ctx, ticket)
}

func newTestWSHandler() *WSHandler {
	consumed := map[string]bool{}
	return NewWSHandler(ws.NewHub(), &mockTickets{
		issueFunc: func(_ context.Context, _ uuid.UUID) (string, time.Time, error) {
			return "valid-ticket", time.Now().Add(60 * time.Second), nil
		},
		consumeFunc: func(_ context.Context, ticket string) (uuid.UUID, bool) {
			if ticket == "valid-ticket" && !consumed[ticket] {
				consumed[ticket] = true
				return uuid.New(), true
			}
			return uuid.Nil, false
		},
	})
}

func withUserCtx(r *http.Request, userID uuid.UUID) *http.Request {
	ctx := context.WithValue(r.Context(), middleware.UserIDKey, userID)
	return r.WithContext(ctx)
}

func TestServeWS_MissingTicket_Returns401(t *testing.T) {
	h := newTestWSHandler()
	w := httptest.NewRecorder()
	h.ServeWS(w, httptest.NewRequest(http.MethodGet, "/api/v1/ws", nil))
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestServeWS_InvalidTicket_Returns401(t *testing.T) {
	h := newTestWSHandler()
	w := httptest.NewRecorder()
	h.ServeWS(w, httptest.NewRequest(http.MethodGet, "/api/v1/ws?ticket=bogus", nil))
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestIssueTicket_NoAuth_Returns401(t *testing.T) {
	h := newTestWSHandler()
	w := httptest.NewRecorder()
	h.IssueTicket(w, httptest.NewRequest(http.MethodPost, "/api/v1/ws-ticket", nil))
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestIssueTicket_AuthedUser_Returns200WithTicketField(t *testing.T) {
	h := newTestWSHandler()
	w := httptest.NewRecorder()
	r := withUserCtx(httptest.NewRequest(http.MethodPost, "/api/v1/ws-ticket", nil), uuid.New())
	h.IssueTicket(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", w.Code)
	}
	var body map[string]any
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["ticket"] == nil {
		t.Error("response missing ticket field")
	}
	if body["expires_at"] == nil {
		t.Error("response missing expires_at field")
	}
}

func TestServeWS_ConsumedTicket_Returns401OnSecondUse(t *testing.T) {
	h := newTestWSHandler()

	// First call: valid-ticket is consumed but websocket.Accept fails
	// (httptest.Recorder can't upgrade), thats fine:  ticket is already consumed
	w1 := httptest.NewRecorder()
	h.ServeWS(w1, httptest.NewRequest(http.MethodGet, "/api/v1/ws?ticket=valid-ticket", nil))
	// First call may succeed (consumed) or fail at WS upgrade (101/other),
	// but the ticket is now consumed regardless

	// Second call with the same ticket must always be 401
	w2 := httptest.NewRecorder()
	h.ServeWS(w2, httptest.NewRequest(http.MethodGet, "/api/v1/ws?ticket=valid-ticket", nil))
	if w2.Code != http.StatusUnauthorized {
		t.Errorf("second use: got %d, want 401", w2.Code)
	}
}
