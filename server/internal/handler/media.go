package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/freytastic/keepsy/internal/apierr"
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
		FileName    string `json:"file_name"`
		ContentType string `json:"content_type"`
		FileSize    int64  `json:"file_size"`
		MediaType   string `json:"media_type"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	uploadURL, media, err := h.mediaService.RequestUploadURL(r.Context(), service.UploadRequest{
		AlbumID:     albumID,
		UploaderID:  userID,
		FileName:    req.FileName,
		ContentType: req.ContentType,
		FileSize:    req.FileSize,
		MediaType:   req.MediaType,
	})

	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to request upload url").WithCause(err))
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
		apierr.Write(w, r, apierr.Auth("authentication required"))
		return
	}

	var media model.Media
	if err := json.NewDecoder(r.Body).Decode(&media); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	err := h.mediaService.ConfirmUpload(r.Context(), &media, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to confirm upload").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(media)
}

func (h *MediaHandler) ListMedia(w http.ResponseWriter, r *http.Request) {
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

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 50
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	media, err := h.mediaService.ListMedia(r.Context(), albumID, userID, limit, offset)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to list media").WithCause(err))
		return
	}

	json.NewEncoder(w).Encode(media)
}

func (h *MediaHandler) DeleteMedia(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}

	vars := mux.Vars(r)
	mediaID, err := uuid.Parse(vars["mid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid media id").WithCause(err))
		return
	}

	err = h.mediaService.DeleteMedia(r.Context(), mediaID, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only uploader or album admin can delete media"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to delete media").WithCause(err))
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
