package handler

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type MediaHandler struct {
	mediaService *service.MediaService
}

func NewMediaHandler(mediaService *service.MediaService) *MediaHandler {
	return &MediaHandler{mediaService: mediaService}
}

func (h *MediaHandler) RequestUploadURL(w http.ResponseWriter, r *http.Request) {
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
		FileName    string `json:"file_name"`
		ContentType string `json:"content_type"`
		FileSize    int64  `json:"file_size"`
		MediaType   string `json:"media_type"`
		ContentHash string `json:"content_hash"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	uploadURL, media, err := h.mediaService.RequestUploadURL(r.Context(), service.UploadRequest{
		AlbumID:     albumID,
		UploaderID:  userID,
		FileName:    req.FileName,
		ContentType: req.ContentType,
		FileSize:    req.FileSize,
		MediaType:   req.MediaType,
		ContentHash: req.ContentHash,
	})

	if err != nil {
		if err == service.ErrDuplicateMedia {
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(map[string]string{"error": "Duplicate pic found"})
			return
		}
		if err == service.ErrUnauthorized {
			http.Error(w, "Unauthorized", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"upload_url": uploadURL,
		"media":      media,
	})
}

func (h *MediaHandler) ConfirmUpload(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.GetUserID(r.Context())
	if !ok {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var media model.Media
	if err := json.NewDecoder(r.Body).Decode(&media); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	err := h.mediaService.ConfirmUpload(r.Context(), &media, userID)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Unauthorized", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(media)
}

func (h *MediaHandler) ListMedia(w http.ResponseWriter, r *http.Request) {
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

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 50
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	media, err := h.mediaService.ListMedia(r.Context(), albumID, userID, limit, offset)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Unauthorized", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(media)
}

func (h *MediaHandler) DeleteMedia(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.GetUserID(r.Context())
	if !ok {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	vars := mux.Vars(r)
	mediaID, err := uuid.Parse(vars["mid"])
	if err != nil {
		http.Error(w, "Invalid media ID", http.StatusBadRequest)
		return
	}

	err = h.mediaService.DeleteMedia(r.Context(), mediaID, userID)
	if err != nil {
		if err == service.ErrUnauthorized {
			http.Error(w, "Unauthorized", http.StatusForbidden)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
