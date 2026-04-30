package model

import (
	"time"

	"github.com/google/uuid"
)

type InviteBlob struct {
	ID          uuid.UUID  `json:"id"`
	AlbumID     uuid.UUID  `json:"album_id"`
	Payload     []byte     `json:"payload"`
	SignerToken []byte     `json:"signer_token"`
	Signature   []byte     `json:"signature"`
	ExpiresAt   time.Time  `json:"expires_at"`
	ConsumedAt  *time.Time `json:"consumed_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

type InviteLink struct {
	Code      string    `json:"code"`
	BlobID    uuid.UUID `json:"blob_id"`
	ExpiresAt time.Time `json:"expires_at"`
	CreatedAt time.Time `json:"created_at"`
}

type InvitePreview struct {
	AlbumID   uuid.UUID `json:"album_id"`
	ExpiresAt time.Time `json:"expires_at"`
}
