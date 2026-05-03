package ws

import (
	"encoding/json"
	"fmt"
)

const (
	EventEpochChanged    = "e2ee.epoch_changed"
	EventManifestUpdated = "e2ee.manifest_updated"
	EventMemberAdded     = "e2ee.member_added"
	EventMemberRevoked   = "e2ee.member_revoked"
	EventOPKLow          = "e2ee.opk_low"
)

var allowedEventTypes = map[string]struct{}{
	EventEpochChanged:    {},
	EventManifestUpdated: {},
	EventMemberAdded:     {},
	EventMemberRevoked:   {},
	EventOPKLow:          {},
}

// Event is the JSON frame sent over the WebSocket
type Event struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// NewEvent constructs a validated Event. Returns an error for unknown type
func NewEvent(typ string, payload any) (Event, error) {
	if _, ok := allowedEventTypes[typ]; !ok {
		return Event{}, fmt.Errorf("ws: unknown event type %q", typ)
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return Event{}, err
	}
	return Event{Type: typ, Payload: b}, nil
}
