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

	// set after app generates keys, nil until then
	IKPub  *string `json:"ik_pub,omitempty" db:"ik_pub"`   // Ed25519 identity key (signing)
	LKPub  *string `json:"lk_pub,omitempty" db:"lk_pub"`   // X25519 long term key (key agreement)
	SPKPub *string `json:"spk_pub,omitempty" db:"spk_pub"` // X25519 signed prekey (rotatable)
	SPKSig *string `json:"spk_sig,omitempty" db:"spk_sig"` // Ed25519 signature over SPKPub
	SPKTs  *int64  `json:"spk_ts,omitempty" db:"spk_ts"`   // Unix timestamp when SPK was signed
}

type Session struct {
	ID         uuid.UUID `json:"id" db:"id"`
	UserID     uuid.UUID `json:"user_id" db:"user_id"`
	TokenHash  string    `json:"token_hash" db:"token_hash"`
	DeviceInfo string    `json:"device_info" db:"device_info"`
	ExpiresAt  time.Time `json:"expires_at" db:"expires_at"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}

type OneTimePrekey struct {
	ID         uuid.UUID `json:"id" db:"id"`
	UserID     uuid.UUID `json:"user_id" db:"user_id"`
	KeyContent string    `json:"key_content" db:"key_content"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}

type PrekeyBundle struct {
	UserID uuid.UUID `json:"user_id"`
	IKPub  string    `json:"ik_pub"`
	LKPub  string    `json:"lk_pub"`
	SPKPub string    `json:"spk_pub"`
	SPKSig string    `json:"spk_sig"`
	SPKTs  int64     `json:"spk_ts"`
	OPK    *struct {
		ID         uuid.UUID `json:"id"`
		KeyContent string    `json:"key_content"`
	} `json:"opk,omitempty"`
}
