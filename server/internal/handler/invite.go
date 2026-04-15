package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type InviteHandler struct {
	inviteService *service.InviteService
}

func NewInviteHandler(inviteService *service.InviteService) *InviteHandler {
	return &InviteHandler{inviteService: inviteService}
}

func (h *InviteHandler) CreateInvite(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.GetUserID(r.Context())
	if !ok {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	vars := mux.Vars(r)
	albumID, err := uuid.Parse(vars["id"])
	if err != nil {
		http.Error(w, "Invalid album ID", http.StatusBadRequest)
		return
	}

	var req struct {
		MaxUses   *int       `json:"max_uses"`
		ExpiresAt *time.Time `json:"expires_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// optional body
	}

	invite, err := h.inviteService.CreateInvite(r.Context(), albumID, userID, req.MaxUses, req.ExpiresAt)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(invite)
}

func (h *InviteHandler) GetPreview(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	code := vars["code"]

	preview, err := h.inviteService.GetInvitePreview(r.Context(), code)
	if err != nil {
		if errors.Is(err, repository.ErrInviteNotFound) {
			http.Error(w, "Invite not found", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(preview)
}

func (h *InviteHandler) JoinAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.GetUserID(r.Context())
	if !ok {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	vars := mux.Vars(r)
	code := vars["code"]

	err := h.inviteService.JoinByInvite(r.Context(), code, userID)
	if err != nil {
		if errors.Is(err, repository.ErrInviteNotFound) {
			http.Error(w, "Invite invalid or expired", http.StatusBadRequest)
			return
		}
		if errors.Is(err, service.ErrAlbumFull) {
			http.Error(w, "Album is full", http.StatusConflict)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
