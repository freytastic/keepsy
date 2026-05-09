package handler

import (
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
)

// Media handlers are stubs in P0.2 (acc to implementation plan)
// Full E2EE upload/download flow lands in P5.1 / P5.2 / P5.3 against the
// new schema (uploader_token, wrap_nonce, wrap_tag_ct, blob_size, blob_sha256).

// M9 PRIVACY RULE for P5.1 : the storage_key written to media.storage_key MUST
// be a server generated random opaque value (e.g. hex(rand(16))), NEVER a
// pattern like "albums/<album_id>/<media_id>". Putting album_id in the S3 key
// lets the storage host group objects per album by inspecting key strings,
// even tho the ciphertext is opaque. The DB row already binds the object
// to its album : the S3 key only needs to be unique

// M11 PRIVACY RULE for P5.1 : the client MUST pad ciphertext to size buckets
// (50 KB / 500 KB / 5 MB / 50 MB or similar) before upload so blob_size only
// reveals the bucket, not the precise byte count. Per file precise size
// fingerprints individual photos / videos to a snapshot adversary

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
