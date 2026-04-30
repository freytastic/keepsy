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

	IKPub  []byte `json:"ik_pub,omitempty" db:"ik_pub"`
	LKPub  []byte `json:"lk_pub,omitempty" db:"lk_pub"`
	SPKPub []byte `json:"spk_pub,omitempty" db:"spk_pub"`
	SPKSig []byte `json:"spk_sig,omitempty" db:"spk_sig"`
	SPKTs  *int64 `json:"spk_ts,omitempty" db:"spk_ts"`
}

type Session struct {
	ID         uuid.UUID `json:"id" db:"id"`
	UserID     uuid.UUID `json:"user_id" db:"user_id"`
	TokenHash  []byte    `json:"token_hash" db:"token_hash"`
	DeviceInfo string    `json:"device_info" db:"device_info"`
	ExpiresAt  time.Time `json:"expires_at" db:"expires_at"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}

type OneTimePrekey struct {
	ID        uuid.UUID `json:"id" db:"id"`
	UserID    uuid.UUID `json:"user_id" db:"user_id"`
	OPKIdx    int       `json:"opk_idx" db:"opk_idx"`
	KeyPub    []byte    `json:"key_pub" db:"key_pub"`
	Consumed  bool      `json:"consumed" db:"consumed"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

type PrekeyBundle struct {
	UserID uuid.UUID `json:"user_id"`
	IKPub  []byte    `json:"ik_pub"`
	LKPub  []byte    `json:"lk_pub"`
	SPKPub []byte    `json:"spk_pub"`
	SPKSig []byte    `json:"spk_sig"`
	SPKTs  int64     `json:"spk_ts"`
	OPK    *struct {
		Idx    int    `json:"idx"`
		KeyPub []byte `json:"key_pub"`
	} `json:"opk,omitempty"`
}
