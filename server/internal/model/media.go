package model

import (
	"time"

	"github.com/google/uuid"
)

type Media struct {
	ID            uuid.UUID `json:"id"`
	AlbumID       uuid.UUID `json:"album_id"`
	UploaderToken []byte    `json:"uploader_token"`
	StorageKey    string    `json:"storage_key"`
	ThumbKey      *string   `json:"thumb_key,omitempty"`
	WrapNonce     []byte    `json:"wrap_nonce"`
	WrapTagCT     []byte    `json:"wrap_tag_ct"`
	EpochTag      int       `json:"epoch_tag"`
	BlobSize      int64     `json:"blob_size"`
	BlobSHA256    []byte    `json:"blob_sha256"`
	MediaType     string    `json:"media_type"`
	MimeType      *string   `json:"mime_type,omitempty"`
	Confirmed     bool      `json:"confirmed"`
	CreatedAt     time.Time `json:"created_at"`
}

type MediaWithURL struct {
	Media
	DownloadURL string `json:"download_url"`
}
