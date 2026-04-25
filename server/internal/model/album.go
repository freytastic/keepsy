package model

import (
	"time"

	"github.com/google/uuid"
)

type Album struct {
	ID           uuid.UUID              `json:"id"`
	Name         string                 `json:"name"`
	Description  string                 `json:"description"`
	CoverMediaID *uuid.UUID             `json:"cover_media_id,omitempty"`
	CreatorID    uuid.UUID              `json:"creator_id"`
	WidgetConfig map[string]interface{} `json:"widget_config"`
	CurrentEpoch int                    `json:"current_epoch"` // increments on membership changes / every x key rotation
	CreatedAt    time.Time              `json:"created_at"`
	UpdatedAt    time.Time              `json:"updated_at"`
}

type AlbumMember struct {
	AlbumID  uuid.UUID `json:"album_id"`
	UserID   uuid.UUID `json:"user_id"`
	Role     string    `json:"role"` // "owner", "co-owner", or "member"
	JoinedAt time.Time `json:"joined_at"`
}

// AlbumWithMemberInfo is a helper struct for when we want to return
// album details ALONG with the current user's role in it
type AlbumWithMemberInfo struct {
	Album
	UserRole string `json:"user_role"`
}
