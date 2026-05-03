package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

type WSHandler struct {
	hub     *ws.Hub
	tickets ws.Tickets
}

func NewWSHandler(hub *ws.Hub, tickets ws.Tickets) *WSHandler {
	return &WSHandler{hub: hub, tickets: tickets}
}

// IssueTicket handles POST /api/v1/ws-ticket
// Requires bearer auth (mounted inside the authenticated subrouter)
// Returns a single use ticket valid for 60s that the client uses to open a WS
func (h *WSHandler) IssueTicket(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	ticket, expiresAt, err := h.tickets.Issue(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to issue ws ticket").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"ticket":     ticket,
		"expires_at": expiresAt.UTC().Format(time.RFC3339),
	})
}

// ServeWS handles GET /api/v1/ws?ticket=<value>
// Authenticates via the one-time ticket , no bearer auth in URL
func (h *WSHandler) ServeWS(w http.ResponseWriter, r *http.Request) {
	ticket := r.URL.Query().Get("ticket")
	if ticket == "" {
		apierr.Write(w, r, apierr.Auth("missing ticket"))
		return
	}
	userID, ok := h.tickets.Consume(r.Context(), ticket)
	if !ok {
		apierr.Write(w, r, apierr.Auth("invalid or expired ticket"))
		return
	}
	wsConn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns: []string{"*"},
	})
	if err != nil {
		// Accept writes its own HTTP error on failure: nothing more to do
		return
	}
	conn := ws.NewConn(userID, wsConn, h.hub)
	h.hub.Register(userID, conn)
	conn.Run(r.Context())
}

// TestEmitEvent handles POST /test/emit-event: dev builds only
// Pushes an event directly to any active connection for the given user_id
func (h *WSHandler) TestEmitEvent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		UserID  string          `json:"user_id"`
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body"))
		return
	}
	userID, err := uuid.Parse(req.UserID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid user_id"))
		return
	}
	ev, err := ws.NewEvent(req.Type, req.Payload)
	if err != nil {
		apierr.Write(w, r, apierr.Validation(err.Error()))
		return
	}
	h.hub.Broadcast([]uuid.UUID{userID}, ev)
	w.WriteHeader(http.StatusNoContent)
}
