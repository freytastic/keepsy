package handler

import (
	"encoding/json"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type UserHandler struct {
	userService *service.UserService
}

func NewUserHandler(userService *service.UserService) *UserHandler {
	return &UserHandler{userService: userService}
}

func (h *UserHandler) GetMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	user, err := h.userService.GetUserByID(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.NotFound("user not found").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(user)
}

type UpdateUserRequest struct {
	Name        *string `json:"name"`
	AccentColor string  `json:"accent_color"`
	Theme       string  `json:"theme"`
	IKPub       *string `json:"ik_pub"`
	LKPub       *string `json:"lk_pub"`
	SPKPub      *string `json:"spk_pub"`
	SPKSig      *string `json:"spk_sig"`
	SPKTs       *int64  `json:"spk_ts"`
}

func (h *UserHandler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	var req UpdateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	user, err := h.userService.UpdateUser(r.Context(), userID,
		req.Name, req.AccentColor, req.Theme,
		req.IKPub, req.LKPub, req.SPKPub, req.SPKSig, req.SPKTs,
	)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update user").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(user)
}

func (h *UserHandler) GetPrekeyBundle(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	targetID, err := uuid.Parse(vars["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid user id").WithCause(err))
		return
	}

	bundle, err := h.userService.GetPrekeyBundle(r.Context(), targetID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to fetch prekey bundle").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(bundle)
}

func (h *UserHandler) ReplenishOPKs(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	var req struct {
		Keys []string `json:"keys"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	if len(req.Keys) == 0 {
		apierr.Write(w, r, apierr.Validation("no keys provided"))
		return
	}

	err := h.userService.ReplenishOPKs(r.Context(), userID, req.Keys)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to replenish OPKs").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusCreated)
}

func (h *UserHandler) GetOPKCount(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	count, err := h.userService.GetOPKCount(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to count OPKs").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int{"count": count})
}
