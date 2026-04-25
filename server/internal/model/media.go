package model

import (
	"time"

	"github.com/google/uuid"
)

type Media struct {
	ID          uuid.UUID `json:"id"`
	AlbumID     uuid.UUID `json:"album_id"`
	UploaderID  uuid.UUID `json:"uploader_id"`
	StorageKey  string    `json:"storage_key"`
	ThumbKey    *string   `json:"thumb_key"`
	MediaType   string    `json:"media_type"` // "photo" || "video"
	MimeType    string    `json:"mime_type"`
	FileSize    int64     `json:"file_size"`
	Width       *int      `json:"width"`
	Height      *int      `json:"height"`
	DurationMS  *int      `json:"duration_ms"`
	ContentHash *string   `json:"content_hash"`
	CreatedAt   time.Time `json:"created_at"`

	// populated when encryption is active
	// WrappedDEK is the AES-GCM encrypted Data Encryption Key (only album members can unwrap it)
	WrappedDEK *string `json:"wrapped_dek,omitempty"`
	// EpochTag indicates which epoch's Master Key was used to wrap this DEK
	EpochTag *int `json:"epoch_tag,omitempty"`
}

// MediaWithURL includes the temporary presigned download URL for the front
type MediaWithURL struct {
	Media
	DownloadURL string `json:"download_url"`
}
