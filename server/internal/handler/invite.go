package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
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
		apierr.Write(w, r, apierr.Auth("authentication required"))
		return
	}

	vars := mux.Vars(r)
	albumID, err := uuid.Parse(vars["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}

	var req struct {
		MaxUses   *int       `json:"max_uses"`
		ExpiresAt *time.Time `json:"expires_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// optional body , bad JSON shouldnt kill the call, fall through with zero values
		_ = err
	}

	invite, err := h.inviteService.CreateInvite(r.Context(), albumID, userID, req.MaxUses, req.ExpiresAt)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to create invite").WithCause(err))
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
			apierr.Write(w, r, apierr.NotFound("invite not found"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to fetch invite preview").WithCause(err))
		return
	}

	json.NewEncoder(w).Encode(preview)
}

func (h *InviteHandler) JoinAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	vars := mux.Vars(r)
	code := vars["code"]

	err := h.inviteService.JoinByInvite(r.Context(), code, userID)
	if err != nil {
		if errors.Is(err, repository.ErrInviteNotFound) {
			apierr.Write(w, r, apierr.InviteExpired("invite invalid or expired"))
			return
		}
		if errors.Is(err, service.ErrAlbumFull) {
			apierr.Write(w, r, apierr.AlbumFull(err.Error()))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to join album").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *InviteHandler) CreateInviteBlob(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	vars := mux.Vars(r)
	albumID, err := uuid.Parse(vars["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}

	var req struct {
		Payload   string    `json:"payload"`
		Signature string    `json:"signature"`
		ExpiresAt time.Time `json:"expires_at"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	blob, err := h.inviteService.CreateInviteBlob(r.Context(), albumID, userID, req.Payload, req.Signature, req.ExpiresAt)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can create an invite blob"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to create invite blob").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(blob)
}

func (h *InviteHandler) GetInviteBlob(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	albumID, err := uuid.Parse(vars["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}

	blob, err := h.inviteService.GetInviteBlob(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to fetch invite blob").WithCause(err))
		return
	}

	if blob == nil {
		apierr.Write(w, r, apierr.NotFound("invite blob not found"))
		return
	}

	json.NewEncoder(w).Encode(blob)
}
