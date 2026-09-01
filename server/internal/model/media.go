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
	// Confirm generation used for server ordering only
	AlbumSeq *int64 `json:"-"`
	// per file thumb has its own DEK wrapped under same MK as the file
	// DEK. All four nullable : videos + pre §5.3 rows wont have thumbs
	ThumbWrapNonce []byte `json:"thumb_wrap_nonce,omitempty"`
	ThumbWrapTagCT []byte `json:"thumb_wrap_tag_ct,omitempty"`
	ThumbSize      *int64 `json:"thumb_size,omitempty"`
	ThumbSHA256    []byte `json:"thumb_sha256,omitempty"`
}

type MediaWithURL struct {
	Media
	DownloadURL string `json:"download_url"`
}
