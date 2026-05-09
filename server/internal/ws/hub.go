package ws

import (
	"context"
	"sync"

	"github.com/google/uuid"
)

// Hub manages all active WebSocket connections, keyed by user ID
// One user may hold multiple connections (future multi-device: tolerated now)
type Hub struct {
	mu    sync.RWMutex
	conns map[uuid.UUID][]*Conn
}

func NewHub() *Hub {
	return &Hub{conns: make(map[uuid.UUID][]*Conn)}
}

func (h *Hub) Register(userID uuid.UUID, c *Conn) {
	h.mu.Lock()
	h.conns[userID] = append(h.conns[userID], c)
	h.mu.Unlock()
}

func (h *Hub) Unregister(userID uuid.UUID, c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	list := h.conns[userID]
	out := list[:0]
	for _, existing := range list {
		if existing != c {
			out = append(out, existing)
		}
	}
	if len(out) == 0 {
		delete(h.conns, userID)
	} else {
		h.conns[userID] = out
	}
}

// Broadcast delivers event to every active connection for the given users
// Slow clients (full outbox) are skipped , the event is dropped for them
func (h *Hub) Broadcast(userIDs []uuid.UUID, event Event) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, uid := range userIDs {
		for _, c := range h.conns[uid] {
			c.send(event)
		}
	}
}

// EmitToUsers builds the validated event and broadcasts it. Live only ; offline
// recipients catch up via pull on next reconnect (epoch_processor.catchUpAll).
// Replaces the deleted notifications package which used to also persist a row
// per emit ; that row was an indexed social graph audit log nothing read
func (h *Hub) EmitToUsers(_ context.Context, userIDs []uuid.UUID, typ string, payload any) error {
	ev, err := NewEvent(typ, payload)
	if err != nil {
		return err
	}
	h.Broadcast(userIDs, ev)
	return nil
}
