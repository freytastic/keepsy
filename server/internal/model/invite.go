package model

import (
	"time"

	"github.com/google/uuid"
)

type InviteLink struct {
	ID        uuid.UUID  `json:"id" db:"id"`
	AlbumID   uuid.UUID  `json:"album_id" db:"album_id"`
	CreatedBy uuid.UUID  `json:"created_by" db:"created_by"`
	Code      string     `json:"code" db:"code"`
	MaxUses   *int       `json:"max_uses" db:"max_uses"`
	UseCount  int        `json:"use_count" db:"use_count"`
	ExpiresAt *time.Time `json:"expires_at" db:"expires_at"`
	IsActive  bool       `json:"is_active" db:"is_active"`
	CreatedAt time.Time  `json:"created_at" db:"created_at"`
}

// InvitePreview is what we show a guest before they join
type InvitePreview struct {
	AlbumName   string `json:"album_name"`
	CreatorName string `json:"creator_name"`
	MemberCount int    `json:"member_count"`
}
