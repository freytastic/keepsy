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

// Media handlers (§5.1 upload + §5.2 download foundation). Photos work end to
// end : video player UI + video specific picker land in v2 alongside §5.x

// M9 PRIVACY RULE : storage_key is server generated random opaque (set in
// service.RequestUploadURL via newStorageKey). NEVER include album_id or
// media_id in the S3 key path : the storage host can group objects by key
// string even though the body is ciphertext

// M11 PRIVACY RULE for §5.x follow up : the client should pad ciphertext to
// size buckets (50 KB / 500 KB / 5 MB / 50 MB) before upload so blob_size only
// reveals the bucket, not the precise byte count. Per file precise size
// fingerprints individual photos / videos to a snapshot adversary

type MediaHandler struct {
	svc *service.MediaService
}

func NewMediaHandler(svc *service.MediaService) *MediaHandler {
	return &MediaHandler{svc: svc}
}

type requestUploadReq struct {
	MediaID    string `json:"media_id"`
	BlobSize   int64  `json:"blob_size"`
	BlobSHA256 string `json:"blob_sha256"`
	MimeType   string `json:"mime_type"`
	MediaType  string `json:"media_type"`
	WrapNonce  string `json:"wrap_nonce"`
	WrapTagCT  string `json:"wrap_tag_ct"`
	EpochTag   int    `json:"epoch_tag"`
	// §5.3 : present-as-a-group for photos with thumb, absent for videos
	// or any non thumbnailable media. Service validates the all-or-nothing rule
	ThumbSize      int64  `json:"thumb_size,omitempty"`
	ThumbSHA256    string `json:"thumb_sha256,omitempty"`
	ThumbWrapNonce string `json:"thumb_wrap_nonce,omitempty"`
	ThumbWrapTagCT string `json:"thumb_wrap_tag_ct,omitempty"`
}

func (h *MediaHandler) RequestUploadURL(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	memberToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return
	}
	var req requestUploadReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	mediaID, err := parseOptionalUUID(req.MediaID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid media_id").WithCause(err))
		return
	}
	sha, err := base64.StdEncoding.DecodeString(req.BlobSHA256)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("blob_sha256 must be base64").WithCause(err))
		return
	}
	wrapNonce, err := base64.StdEncoding.DecodeString(req.WrapNonce)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("wrap_nonce must be base64").WithCause(err))
		return
	}
	wrapTagCT, err := base64.StdEncoding.DecodeString(req.WrapTagCT)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("wrap_tag_ct must be base64").WithCause(err))
		return
	}
	// decoded only when present. Empty string → zero length
	// slice, which the service treats as "no thumb"
	thumbSHA256, err := decodeOptionalBase64(req.ThumbSHA256, "thumb_sha256")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	thumbWrapNonce, err := decodeOptionalBase64(req.ThumbWrapNonce, "thumb_wrap_nonce")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	thumbWrapTagCT, err := decodeOptionalBase64(req.ThumbWrapTagCT, "thumb_wrap_tag_ct")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}

	res, err := h.svc.RequestUploadURL(r.Context(), albumID, memberToken, service.RequestUploadInput{
		MediaID:        mediaID,
		BlobSize:       req.BlobSize,
		BlobSHA256:     sha,
		MimeType:       req.MimeType,
		MediaType:      req.MediaType,
		WrapNonce:      wrapNonce,
		WrapTagCT:      wrapTagCT,
		EpochTag:       req.EpochTag,
		ThumbSize:      req.ThumbSize,
		ThumbSHA256:    thumbSHA256,
		ThumbWrapNonce: thumbWrapNonce,
		ThumbWrapTagCT: thumbWrapTagCT,
	})
	if err != nil {
		apierr.Write(w, r, err)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	out := map[string]any{
		"media_id":        res.MediaID,
		"upload_url":      res.UploadURL,
		"required_header": res.RequiredHeader,
	}
	if res.ThumbUploadURL != "" {
		out["thumb_upload_url"] = res.ThumbUploadURL
		out["thumb_required_header"] = res.ThumbRequiredHeader
	}
	_ = json.NewEncoder(w).Encode(out)
}

type confirmUploadReq struct {
	MediaID string `json:"media_id"`
}

func (h *MediaHandler) ConfirmUpload(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	uploaderUserID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req confirmUploadReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	mediaID, err := uuid.Parse(req.MediaID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid media_id").WithCause(err))
		return
	}
	if err := h.svc.ConfirmUpload(r.Context(), albumID, mediaID, uploaderUserID); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *MediaHandler) ListMedia(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	rows, err := h.svc.ListMedia(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	out := make([]map[string]any, len(rows))
	for i, m := range rows {
		row := map[string]any{
			"id":             m.ID,
			"album_id":       m.AlbumID,
			"uploader_token": base64.StdEncoding.EncodeToString(m.UploaderToken),
			"wrap_nonce":     base64.StdEncoding.EncodeToString(m.WrapNonce),
			"wrap_tag_ct":    base64.StdEncoding.EncodeToString(m.WrapTagCT),
			"epoch_tag":      m.EpochTag,
			"blob_size":      m.BlobSize,
			"blob_sha256":    base64.StdEncoding.EncodeToString(m.BlobSHA256),
			"media_type":     m.MediaType,
			"mime_type":      m.MimeType,
			"created_at":     m.CreatedAt,
		}
		//thumb fields emitted only when the row has a thumb. Client
		// uses presence to decide between EncryptedThumbnail (fast grid) and
		// falling back to EncryptedImage (no thumb available)
		if m.ThumbSize != nil {
			row["thumb_wrap_nonce"] = base64.StdEncoding.EncodeToString(m.ThumbWrapNonce)
			row["thumb_wrap_tag_ct"] = base64.StdEncoding.EncodeToString(m.ThumbWrapTagCT)
			row["thumb_size"] = *m.ThumbSize
			row["thumb_sha256"] = base64.StdEncoding.EncodeToString(m.ThumbSHA256)
		}
		out[i] = row
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// RequestDownloadURL handles POST /albums/{id}/media/{mid}/download-url
// Returns {url, expires_at}. URL is short lived (15 min) : client downloads
// immediately. Refuses media that hasnt been confirmed. ?asset=thumb on the
// query string returns the thumb URL : default = file
func (h *MediaHandler) RequestDownloadURL(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	mediaID, err := uuid.Parse(mux.Vars(r)["mid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid media id").WithCause(err))
		return
	}
	asset := r.URL.Query().Get("asset")
	if asset == "" {
		asset = "file"
	}
	res, err := h.svc.RequestDownloadURL(r.Context(), albumID, mediaID, asset)
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

func (h *MediaHandler) DeleteMedia(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	mediaID, err := uuid.Parse(mux.Vars(r)["mid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid media id").WithCause(err))
		return
	}
	if err := h.svc.DeleteMedia(r.Context(), albumID, mediaID); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func scopedAlbumID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return uuid.Nil, false
	}
	return id, true
}

func parseOptionalUUID(s string) (uuid.UUID, error) {
	if s == "" {
		return uuid.Nil, nil
	}
	return uuid.Parse(s)
}

// Empty string → nil slice (= "field not present"). Service treats a nil/empty
// thumb_wrap_nonce as the trigger to skip thumb logic entirely
func decodeOptionalBase64(s, name string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, apierr.Validation(name + " must be base64").WithCause(err)
	}
	return b, nil
}
