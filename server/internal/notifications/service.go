package notifications

import (
	"context"
	"log/slog"

	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

type Service struct {
	repo *Repo
	hub  *ws.Hub
}

func NewService(repo *Repo, hub *ws.Hub) *Service {
	return &Service{repo: repo, hub: hub}
}

// EmitToUsers persists a notification for offline replay and immediately
// broadcasts it to any active WebSocket connections for each user
// DB persist failures are logged but do not prevent the live broadcast
func (s *Service) EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error {
	ev, err := ws.NewEvent(typ, payload)
	if err != nil {
		return err
	}
	for _, uid := range userIDs {
		if err := s.repo.Persist(ctx, uid, typ, payload); err != nil {
			slog.Default().Error("notifications: persist failed",
				"user_id", uid, "type", typ, "err", err)
		}
	}
	s.hub.Broadcast(userIDs, ev)
	return nil
}
