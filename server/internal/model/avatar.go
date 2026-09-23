package model

import (
	"time"

	"github.com/google/uuid"
)

type MemberAvatar struct {
	AvatarID    uuid.UUID
	AlbumID     uuid.UUID
	MemberToken []byte
	StorageKey  string
	BlobSize    int64
	BlobSHA256  []byte
	KeyCT       []byte
	Confirmed   bool
	CreatedAt   time.Time
}

// What album members need to fetch and open an avatar. The storage key stays
// server side so every fetch goes through an authorized download URL
type AvatarRef struct {
	AvatarID   uuid.UUID
	BlobSize   int64
	BlobSHA256 []byte
	KeyCT      []byte
}
