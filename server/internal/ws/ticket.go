package ws

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const (
	ticketTTL    = 60 * time.Second
	ticketPrefix = "ws-ticket:"
)

type Tickets interface {
	Issue(ctx context.Context, userID uuid.UUID) (ticket string, expiresAt time.Time, err error)
	Consume(ctx context.Context, ticket string) (uuid.UUID, bool)
}

// TicketStore backs single use WS tickets in Redis
type TicketStore struct {
	rdb *redis.Client
}

func NewTicketStore(rdb *redis.Client) *TicketStore {
	return &TicketStore{rdb: rdb}
}

// Issue generates a 32-byte random ticket, stores it under ws-ticket:<ticket>
// with a 60s TTL, and returns the base64url-encoded ticket
func (s *TicketStore) Issue(ctx context.Context, userID uuid.UUID) (string, time.Time, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", time.Time{}, err
	}
	ticket := base64.RawURLEncoding.EncodeToString(raw)
	expiresAt := time.Now().Add(ticketTTL)
	if err := s.rdb.Set(ctx, ticketPrefix+ticket, userID.String(), ticketTTL).Err(); err != nil {
		return "", time.Time{}, err
	}
	return ticket, expiresAt, nil
}

// consumeScript atomically GETs and deletes the ticket key , single use even under concurrent claims
var consumeScript = redis.NewScript(`
	local v = redis.call("GET", KEYS[1])
	if v == false then return false end
	redis.call("DEL", KEYS[1])
	return v
`)

// Consume atomically retrieves and deletes a ticket. Returns (userID, true) on success
// Returns (uuid.Nil, false) if the ticket is missing, expired, or already consumed
func (s *TicketStore) Consume(ctx context.Context, ticket string) (uuid.UUID, bool) {
	val, err := consumeScript.Run(ctx, s.rdb, []string{ticketPrefix + ticket}).Text()
	if err != nil {
		return uuid.Nil, false
	}
	id, err := uuid.Parse(val)
	if err != nil {
		return uuid.Nil, false
	}
	return id, true
}
