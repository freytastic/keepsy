package model

import (
	"time"

	"github.com/google/uuid"
)

type Album struct {
	ID        uuid.UUID `json:"id"`
	NameCT    []byte    `json:"name_ct"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type AlbumMember struct {
	AlbumID     uuid.UUID  `json:"album_id"`
	MemberToken []byte     `json:"member_token"`
	Role        string     `json:"role"`
	RevokedAt   *time.Time `json:"revoked_at,omitempty"`
}

type AlbumMemberIdentity struct {
	MemberToken []byte    `json:"member_token"`
	UserID      uuid.UUID `json:"user_id"`
	AlbumID     uuid.UUID `json:"album_id"`
	JoinedAt    time.Time `json:"joined_at"`
}

type AlbumWithMemberInfo struct {
	Album
	UserRole    string `json:"user_role"`
	MemberToken []byte `json:"member_token"`
}
