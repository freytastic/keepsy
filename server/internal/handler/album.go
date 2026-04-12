package handler

import (
	"encoding/json"
	"net/http"

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
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	album, err := h.albumService.CreateAlbum(r.Context(), req.Name, req.Description, userID, req.WidgetConfig)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
		http.Error(w, "Invalid album ID", http.StatusBadRequest)
		return
	}

	album, err := h.albumService.GetAlbum(r.Context(), albumID, userID)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
		http.Error(w, "Invalid album ID", http.StatusBadRequest)
		return
	}

	var req struct {
		Name         string                 `json:"name"`
		Description  string                 `json:"description"`
		WidgetConfig map[string]interface{} `json:"widget_config"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	err = h.albumService.UpdateAlbum(r.Context(), albumID, userID, req.Name, req.Description, req.WidgetConfig)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
		http.Error(w, "Invalid album ID", http.StatusBadRequest)
		return
	}

	err = h.albumService.DeleteAlbum(r.Context(), albumID, userID)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
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
		http.Error(w, "Invalid album ID", http.StatusBadRequest)
		return
	}

	var req struct {
		UserID uuid.UUID `json:"user_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	err = h.albumService.AddMember(r.Context(), albumID, userID, req.UserID)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		if err == service.ErrAlbumFull {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
}
