package ws

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

const (
	writeTimeout = 10 * time.Second
	pingInterval = 30 * time.Second
	pingTimeout  = 5 * time.Second
	sendBufSize  = 64
)

// Conn wraps a single WebSocket connection for one authenticated user
type Conn struct {
	userID uuid.UUID
	ws     *websocket.Conn
	hub    *Hub
	outbox chan Event
}

// NewConn constructs a Conn. Caller must call hub.Register then conn.Run
func NewConn(userID uuid.UUID, ws *websocket.Conn, hub *Hub) *Conn {
	return &Conn{
		userID: userID,
		ws:     ws,
		hub:    hub,
		outbox: make(chan Event, sendBufSize),
	}
}

// send queues an event without blocking. the event is dropped if the outbox is full
func (c *Conn) send(e Event) {
	select {
	case c.outbox <- e:
	default:
	}
}

// Run drives the write loop until the peer disconnects or ctx is cancelled
// CloseRead starts a background reader that handles incoming control frames
// (pings, pongs, close) so the connection stays alive without a separate goroutine
func (c *Conn) Run(ctx context.Context) {
	defer func() {
		c.hub.Unregister(c.userID, c)
		c.ws.Close(websocket.StatusNormalClosure, "")
	}()

	ctx = c.ws.CloseRead(ctx)

	pingTick := time.NewTicker(pingInterval)
	defer pingTick.Stop()

	for {
		select {
		case <-ctx.Done():
			return

		case <-pingTick.C:
			pCtx, cancel := context.WithTimeout(ctx, pingTimeout)
			err := c.ws.Ping(pCtx)
			cancel()
			if err != nil {
				return
			}

		case ev, ok := <-c.outbox:
			if !ok {
				return
			}
			b, err := json.Marshal(ev)
			if err != nil {
				slog.Default().Error("ws: marshal event", "type", ev.Type, "err", err)
				continue
			}
			wCtx, cancel := context.WithTimeout(ctx, writeTimeout)
			err = c.ws.Write(wCtx, websocket.MessageText, b)
			cancel()
			if err != nil {
				return
			}
		}
	}
}
