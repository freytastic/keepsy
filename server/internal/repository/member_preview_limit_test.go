package repository_test

import (
	"testing"

	"github.com/freytastic/keepsy/internal/e2ee/invite"
	"github.com/freytastic/keepsy/internal/repository"
)

// Activity can treat previews as a roster only if they cover the invite cap
func TestMemberPreviewLimit_CoversTheMemberCap(t *testing.T) {
	if repository.MemberPreviewLimit < invite.MaxAlbumMembers {
		t.Fatalf("MemberPreviewLimit = %d, below MaxAlbumMembers = %d",
			repository.MemberPreviewLimit, invite.MaxAlbumMembers)
	}
}
