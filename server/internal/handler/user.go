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
	// GET /users/{id}/prekey-bundle and track their own publish state locally
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           u.ID,
		"email":        u.Email,
		"name":         u.Name,
		"avatar_key":   u.AvatarKey,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
		"created_at":   u.CreatedAt,
		"updated_at":   u.UpdatedAt,
	})
}

// UpdateUserRequest is profile only : E2EE columns ship via PUT /users/me/keys
type UpdateUserRequest struct {
	Name        *string `json:"name"`
	AccentColor string  `json:"accent_color"`
	Theme       string  `json:"theme"`
}

func (h *UserHandler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	// Reject E2EE keys in this endpoint : theyre owned by /users/me/keys + /spk
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&raw); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	for _, k := range []string{"ik_pub", "lk_pub", "spk_pub", "spk_sig", "spk_ts"} {
		if _, present := raw[k]; present {
			apierr.Write(w, r, apierr.Validation("E2EE fields are uploaded via PUT /users/me/keys"))
			return
		}
	}

	var req UpdateUserRequest
	if v, ok := raw["name"]; ok {
		_ = json.Unmarshal(v, &req.Name)
	}
	if v, ok := raw["accent_color"]; ok {
		_ = json.Unmarshal(v, &req.AccentColor)
	}
	if v, ok := raw["theme"]; ok {
		_ = json.Unmarshal(v, &req.Theme)
	}

	in := service.UserUpdate{
		Name:        req.Name,
		AccentColor: req.AccentColor,
		Theme:       req.Theme,
	}
	u, err := h.userService.UpdateUser(r.Context(), userID, in)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update user").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           u.ID,
		"email":        u.Email,
		"name":         u.Name,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
	})
}
