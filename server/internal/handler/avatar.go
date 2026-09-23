package handler

import (
	"encoding/base64"
	"encoding/json"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Avatars follow the media M9 rule: storage keys are opaque and never returned

type AvatarHandler struct {
	svc *service.AvatarService
}

func NewAvatarHandler(svc *service.AvatarService) *AvatarHandler {
	return &AvatarHandler{svc: svc}
}

func (h *AvatarHandler) RequestUploadURL(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	memberToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return
	}
	var req struct {
		AvatarID   string `json:"avatar_id"`
		BlobSize   int64  `json:"blob_size"`
		BlobSHA256 string `json:"blob_sha256"`
		KeyCT      string `json:"key_ct"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	avatarID, err := uuid.Parse(req.AvatarID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid avatar_id").WithCause(err))
		return
	}
	sha, err := base64.StdEncoding.DecodeString(req.BlobSHA256)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("blob_sha256 must be base64").WithCause(err))
		return
	}
	keyCT, err := base64.StdEncoding.DecodeString(req.KeyCT)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("key_ct must be base64").WithCause(err))
		return
	}
	pre, err := h.svc.RequestUploadURL(r.Context(), albumID, memberToken, service.AvatarUploadInput{
		AvatarID:   avatarID,
		BlobSize:   req.BlobSize,
		BlobSHA256: sha,
		KeyCT:      keyCT,
	})
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"upload_url":      pre.URL,
		"required_header": pre.RequiredHeader,
	})
}

func (h *AvatarHandler) Confirm(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	memberToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return
	}
	var req struct {
		AvatarID string `json:"avatar_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	avatarID, err := uuid.Parse(req.AvatarID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid avatar_id").WithCause(err))
		return
	}
	if err := h.svc.Confirm(r.Context(), albumID, userID, memberToken, avatarID); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *AvatarHandler) Remove(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	memberToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return
	}
	if err := h.svc.Remove(r.Context(), albumID, userID, memberToken); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *AvatarHandler) DownloadURL(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	avatarID, err := uuid.Parse(mux.Vars(r)["aid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid avatar id").WithCause(err))
		return
	}
	res, err := h.svc.DownloadURL(r.Context(), albumID, avatarID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"url":        res.URL,
		"expires_at": res.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
	})
}
