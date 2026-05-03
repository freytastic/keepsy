package ws

import (
	"testing"

	"github.com/google/uuid"
)

// newTestConn creates a Conn with no real WebSocket for hub level tests
// Only the outbox channel is exercised: ws is nil and Run is never called
func newTestConn(userID uuid.UUID, hub *Hub) *Conn {
	return &Conn{
		userID: userID,
		hub:    hub,
		outbox: make(chan Event, sendBufSize),
	}
}

func TestHub_BroadcastReachesAllConnections(t *testing.T) {
	h := NewHub()
	userA, userB := uuid.New(), uuid.New()

	c1 := newTestConn(userA, h)
	c2 := newTestConn(userA, h) // second conn for userA
	c3 := newTestConn(userB, h)
	h.Register(userA, c1)
	h.Register(userA, c2)
	h.Register(userB, c3)

	ev, err := NewEvent(EventEpochChanged, map[string]any{"epoch": 1})
	if err != nil {
		t.Fatalf("NewEvent: %v", err)
	}
	h.Broadcast([]uuid.UUID{userA, userB}, ev)

	for _, tc := range []struct {
		name string
		c    *Conn
	}{
		{"c1", c1}, {"c2", c2}, {"c3", c3},
	} {
		select {
		case got := <-tc.c.outbox:
			if got.Type != EventEpochChanged {
				t.Errorf("%s: got type %q, want %q", tc.name, got.Type, EventEpochChanged)
			}
		default:
			t.Errorf("%s: outbox empty, broadcast missed", tc.name)
		}
	}
}

func TestHub_BroadcastSkipsExcludedUser(t *testing.T) {
	h := NewHub()
	userA, userB := uuid.New(), uuid.New()

	cA := newTestConn(userA, h)
	cB := newTestConn(userB, h)
	h.Register(userA, cA)
	h.Register(userB, cB)

	ev, _ := NewEvent(EventMemberRevoked, nil)
	h.Broadcast([]uuid.UUID{userA}, ev) // only userA

	select {
	case <-cA.outbox:
	default:
		t.Error("cA did not receive event")
	}
	select {
	case <-cB.outbox:
		t.Error("cB received event but should not have")
	default:
	}
}

func TestHub_UnregisterRemovesConnection(t *testing.T) {
	h := NewHub()
	userA := uuid.New()

	c1 := newTestConn(userA, h)
	c2 := newTestConn(userA, h)
	h.Register(userA, c1)
	h.Register(userA, c2)
	h.Unregister(userA, c1)

	ev, _ := NewEvent(EventOPKLow, nil)
	h.Broadcast([]uuid.UUID{userA}, ev)

	select {
	case <-c1.outbox:
		t.Error("c1 received event after unregister")
	default:
	}
	select {
	case got := <-c2.outbox:
		if got.Type != EventOPKLow {
			t.Errorf("c2 got wrong type %q", got.Type)
		}
	default:
		t.Error("c2 did not receive event")
	}
}

func TestHub_UnregisterLastConnDeletesMapEntry(t *testing.T) {
	h := NewHub()
	userA := uuid.New()

	c := newTestConn(userA, h)
	h.Register(userA, c)
	h.Unregister(userA, c)

	h.mu.RLock()
	_, exists := h.conns[userA]
	h.mu.RUnlock()
	if exists {
		t.Error("map entry should be deleted after last connection unregistered")
	}
}

func TestNewEvent_RejectsUnknownType(t *testing.T) {
	if _, err := NewEvent("not.an.event", nil); err == nil {
		t.Error("expected error for unknown event type, got nil")
	}
}

func TestNewEvent_AcceptsAllAllowedTypes(t *testing.T) {
	for _, typ := range []string{
		EventEpochChanged, EventManifestUpdated,
		EventMemberAdded, EventMemberRevoked, EventOPKLow,
	} {
		if _, err := NewEvent(typ, nil); err != nil {
			t.Errorf("type %q should be valid, got: %v", typ, err)
		}
	}
}
