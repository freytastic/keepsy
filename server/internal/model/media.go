package model

import (
	"time"

	"github.com/google/uuid"
)

type Media struct {
	ID          uuid.UUID  `json:"id"`
	AlbumID     uuid.UUID  `json:"album_id"`
	UploaderID  uuid.UUID  `json:"uploader_id"`
	StorageKey  string     `json:"storage_key"`
	ThumbKey    *string    `json:"thumb_key"`
	MediaType   string     `json:"media_type"` // "photo" || "video"
	MimeType    string     `json:"mime_type"`
	FileSize    int64      `json:"file_size"`
	Width       *int       `json:"width"`
	Height      *int       `json:"height"`
	DurationMS  *int       `json:"duration_ms"`
	TakenAt     *time.Time `json:"taken_at"`
	LocationLat *float64   `json:"location_lat"`
	LocationLng *float64   `json:"location_lng"`
	ContentHash *string    `json:"content_hash"`
	CreatedAt   time.Time  `json:"created_at"`
}

// MediaWithURL includes the temporary presigned download URL for the front
type MediaWithURL struct {
	Media
	DownloadURL string `json:"download_url"`
}
