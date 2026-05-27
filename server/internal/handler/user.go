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
		"id":           u.ID,
		"keepsy_id":    u.KeepsyID,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
		"created_at":   u.CreatedAt,
		"updated_at":   u.UpdatedAt,
	})
}

// UpdateUserRequest is profile only. Name + avatar deliberately not in this
// endpoint (M7) : name lives in album_members.name_ct via PUT /albums/{id}/
// members/me/profile-ct : avatars come back in Phase 5 via the media pipeline
type UpdateUserRequest struct {
	AccentColor string `json:"accent_color"`
	Theme       string `json:"theme"`
}

func (h *UserHandler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&raw); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	// Reject E2EE keys : theyre owned by /users/me/keys + /spk
	for _, k := range []string{"ik_pub", "lk_pub", "spk_pub", "spk_sig", "spk_ts"} {
		if _, present := raw[k]; present {
			apierr.Write(w, r, apierr.Validation("E2EE fields are uploaded via PUT /users/me/keys"))
			return
		}
	}
	// Reject M7 fields explicitly so a stale client surfaces a clear error
	// instead of silently dropping the rename
	for _, k := range []string{"name", "avatar_key"} {
		if _, present := raw[k]; present {
			apierr.Write(w, r, apierr.Validation(k+" is no longer accepted here ; use the album scoped name endpoint"))
			return
		}
	}

	var req UpdateUserRequest
	if v, ok := raw["accent_color"]; ok {
		_ = json.Unmarshal(v, &req.AccentColor)
	}
	if v, ok := raw["theme"]; ok {
		_ = json.Unmarshal(v, &req.Theme)
	}

	u, err := h.userService.UpdateUser(r.Context(), userID, service.UserUpdate{
		AccentColor: req.AccentColor,
		Theme:       req.Theme,
	})
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update user").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           u.ID,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
	})
}
