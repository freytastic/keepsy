package handler

import (
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
)

// Media handlers are stubs in P0.2 (acc to implementation plan)
// Full E2EE upload/download flow lands in P5.1 / P5.2 / P5.3 against the
// new schema (uploader_token, wrap_nonce, wrap_tag_ct, blob_size, blob_sha256).

type MediaHandler struct{}

func NewMediaHandler() *MediaHandler { return &MediaHandler{} }

func (h *MediaHandler) RequestUploadURL(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("media upload lands in P5.1"))
}

func (h *MediaHandler) ConfirmUpload(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("media upload lands in P5.1"))
}

func (h *MediaHandler) ListMedia(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("media listing lands in P5.2"))
}

func (h *MediaHandler) DeleteMedia(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("media deletion lands in P5.x"))
}
