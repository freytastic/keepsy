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

type AlbumWithMemberInfo struct {
	Album
	UserRole    string `json:"user_role"`
	MemberToken []byte `json:"member_token"`
}

// MemberProfile : public bytes other album members need to render the member
// Name lives encrypted as NameCT (locked under the album's MK so only members
// can read it). Avatar comes back in Phase 5 via the encrypted media pipeline
type MemberProfile struct {
	IKPub  []byte `json:"ik_pub"`
	LKPub  []byte `json:"lk_pub"`
	NameCT []byte `json:"name_ct,omitempty"`
}

type MemberWithProfile struct {
	MemberToken []byte        `json:"member_token"`
	Role        string        `json:"role"`
	Revoked     bool          `json:"revoked"`
	JoinedAt    time.Time     `json:"joined_at"`
	Profile     MemberProfile `json:"profile"`
}
