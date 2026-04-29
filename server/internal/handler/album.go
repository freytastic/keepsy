package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type AlbumHandler struct {
	albumService *service.AlbumService
}

func NewAlbumHandler(albumService *service.AlbumService) *AlbumHandler {
	return &AlbumHandler{albumService: albumService}
}

func (h *AlbumHandler) CreateAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	var req struct {
		Name         string                 `json:"name"`
		Description  string                 `json:"description"`
		WidgetConfig map[string]interface{} `json:"widget_config"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	album, err := h.albumService.CreateAlbum(r.Context(), req.Name, req.Description, userID, req.WidgetConfig)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to create album").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(album)
}

func (h *AlbumHandler) GetAlbum(w http.ResponseWriter, r *http.Request) {
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

	album, err := h.albumService.GetAlbum(r.Context(), albumID, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to fetch album").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(album)
}

func (h *AlbumHandler) ListAlbums(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	albums, err := h.albumService.ListUserAlbums(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to list albums").WithCause(err))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(albums)
}

func (h *AlbumHandler) UpdateAlbum(w http.ResponseWriter, r *http.Request) {
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
		Name         string                 `json:"name"`
		Description  string                 `json:"description"`
		WidgetConfig map[string]interface{} `json:"widget_config"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	err = h.albumService.UpdateAlbum(r.Context(), albumID, userID, req.Name, req.Description, req.WidgetConfig)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only album admin can update this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to update album").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *AlbumHandler) DeleteAlbum(w http.ResponseWriter, r *http.Request) {
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

	err = h.albumService.DeleteAlbum(r.Context(), albumID, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only album admin can delete this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to delete album").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (h *AlbumHandler) AddMember(w http.ResponseWriter, r *http.Request) {
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
		UserID uuid.UUID `json:"user_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	err = h.albumService.AddMember(r.Context(), albumID, userID, req.UserID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can add members"))
			return
		}
		if errors.Is(err, service.ErrAlbumFull) {
			apierr.Write(w, r, apierr.AlbumFull(err.Error()))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to add member").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusCreated)
}

func (h *AlbumHandler) RotateAlbumEpoch(w http.ResponseWriter, r *http.Request) {
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

	newEpoch, err := h.albumService.RotateAlbumEpoch(r.Context(), albumID, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can rotate epoch"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to rotate epoch").WithCause(err))
		return
	}

	json.NewEncoder(w).Encode(map[string]int{"current_epoch": newEpoch})
}
