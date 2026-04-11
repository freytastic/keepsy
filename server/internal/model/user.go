package model

import (
	"time"

	"github.com/google/uuid"
)

type User struct {
	ID          uuid.UUID `json:"id" db:"id"`
	Email       string    `json:"email" db:"email"`
	Name        *string   `json:"name" db:"name"`
	AvatarKey   *string   `json:"avatar_key" db:"avatar_key"`
	AccentColor string    `json:"accent_color" db:"accent_color"`
	Theme       string    `json:"theme" db:"theme"`
	CreatedAt   time.Time `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time `json:"updated_at" db:"updated_at"`
}

type Session struct {
	ID         uuid.UUID `json:"id" db:"id"`
	UserID     uuid.UUID `json:"user_id" db:"user_id"`
	TokenHash  string    `json:"token_hash" db:"token_hash"`
	DeviceInfo string    `json:"device_info" db:"device_info"`
	ExpiresAt  time.Time `json:"expires_at" db:"expires_at"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}
