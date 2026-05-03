package ws

import (
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
