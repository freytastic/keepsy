package handler

import (
	"encoding/json"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
)

type UserHandler struct {
	userService *service.UserService
}

func NewUserHandler(s *service.UserService) *UserHandler {
	return &UserHandler{userService: s}
}

func (h *UserHandler) GetMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	u, err := h.userService.GetUserByID(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.NotFound("user not found").WithCause(err))
		return
	}
	// E2EE columns are not surfaced here : clients fetch peer bundles via
	// GET /users/{id}/prekey-bundle and track their own publish state locally.
	// Email + name + avatar intentionally absent : server stores email_hmac
	// (M8), display name lives encrypted per album in album_members.name_ct
	// (M7), avatar comes back in Phase 5. Client persists own email + name
	// keepsy_id IS surfaced : it's the user's own shareable discovery handle (§6.1)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":         u.ID,
		"keepsy_id":  u.KeepsyID,
		"created_at": u.CreatedAt,
		"updated_at": u.UpdatedAt,
	})
}
