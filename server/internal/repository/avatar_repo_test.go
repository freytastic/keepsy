package repository_test

import (
	"bytes"
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
)

type avatarEnv struct {
	*summaryEnv
	avatars *repository.AvatarRepository
	album   uuid.UUID
	owner   uuid.UUID
	pal     uuid.UUID
	admin   []byte
	friend  []byte
}

func newAvatarEnv(t *testing.T) *avatarEnv {
	t.Helper()
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, admin, err := env.repo.CreateWithAdmin(ctx, []byte("avatars"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	pal := env.seedUser(t)
	friend, err := env.repo.AddMember(ctx, album.ID, pal, "member")
	if err != nil {
		t.Fatalf("add member: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx,
			`DELETE FROM media_object_cleanup WHERE storage_key LIKE 'avatar-%'`)
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	return &avatarEnv{
		summaryEnv: env,
		avatars:    repository.NewAvatarRepository(env.pool),
		album:      album.ID,
		owner:      owner,
		pal:        pal,
		admin:      admin,
		friend:     friend,
	}
}

func (e *avatarEnv) row(token []byte, key string, sha byte) *model.MemberAvatar {
	return &model.MemberAvatar{
		AvatarID:    uuid.New(),
		AlbumID:     e.album,
		MemberToken: token,
		StorageKey:  key,
		BlobSize:    131101,
		BlobSHA256:  bytes.Repeat([]byte{sha}, 32),
		KeyCT:       make([]byte, 65),
	}
}

func (e *avatarEnv) upload(t *testing.T, token []byte, key string) *model.MemberAvatar {
	t.Helper()
	ctx := context.Background()
	a := e.row(token, key, key[len(key)-1])
	if err := e.avatars.Reserve(ctx, a); err != nil {
		t.Fatalf("reserve %s: %v", key, err)
	}
	if _, err := e.avatars.Confirm(ctx, e.album, token, a.AvatarID); err != nil {
		t.Fatalf("confirm %s: %v", key, err)
	}
	return a
}

func (e *avatarEnv) queued(t *testing.T, key string) bool {
	t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM media_object_cleanup WHERE storage_key = $1`, key,
	).Scan(&n); err != nil {
		t.Fatalf("read cleanup queue: %v", err)
	}
	return n == 1
}

func (e *avatarEnv) rosterAvatar(t *testing.T, token []byte) *model.AvatarRef {
	t.Helper()
	members, err := e.repo.ListMembers(context.Background(), e.album)
	if err != nil {
		t.Fatalf("list members: %v", err)
	}
	for _, m := range members {
		if bytes.Equal(m.MemberToken, token) {
			return m.Profile.Avatar
		}
	}
	t.Fatalf("member missing from roster")
	return nil
}

func TestAvatar_PendingIsHiddenUntilConfirmed(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()

	a := e.row(e.admin, "avatar-a", 1)
	if err := e.avatars.Reserve(ctx, a); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if got := e.rosterAvatar(t, e.admin); got != nil {
		t.Fatalf("pending avatar leaked into the roster: %+v", got)
	}

	if _, err := e.avatars.Confirm(ctx, e.album, e.admin, a.AvatarID); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	got := e.rosterAvatar(t, e.admin)
	if got == nil || got.AvatarID != a.AvatarID || got.BlobSize != a.BlobSize ||
		!bytes.Equal(got.KeyCT, a.KeyCT) || !bytes.Equal(got.BlobSHA256, a.BlobSHA256) {
		t.Fatalf("roster avatar = %+v, want the confirmed row", got)
	}

	albums, err := e.repo.ListForUser(ctx, e.owner)
	if err != nil {
		t.Fatalf("list albums: %v", err)
	}
	var preview *model.AvatarRef
	for _, al := range albums {
		for _, p := range al.Summary.MemberPreviews {
			if al.ID == e.album && bytes.Equal(p.MemberToken, e.admin) {
				preview = p.Avatar
			}
		}
	}
	if preview == nil || preview.AvatarID != a.AvatarID {
		t.Fatalf("member preview avatar = %+v, want %s", preview, a.AvatarID)
	}
}

func TestAvatar_ConfirmReplacesAndQueuesTheOldObject(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	e.upload(t, e.admin, "avatar-1")

	next := e.row(e.admin, "avatar-2", 2)
	if err := e.avatars.Reserve(ctx, next); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	replaced, err := e.avatars.Confirm(ctx, e.album, e.admin, next.AvatarID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if !slices.Equal(replaced, []string{"avatar-1"}) {
		t.Errorf("replaced = %v, want [avatar-1]", replaced)
	}
	if !e.queued(t, "avatar-1") {
		t.Error("the replaced object must be queued in the same transaction")
	}
	if got := e.rosterAvatar(t, e.admin); got == nil || got.AvatarID != next.AvatarID {
		t.Fatalf("roster avatar = %+v, want the replacement", got)
	}

	again, err := e.avatars.Confirm(ctx, e.album, e.admin, next.AvatarID)
	if err != nil || len(again) != 0 {
		t.Fatalf("repeat confirm = %v, %v, want a no op", again, err)
	}
}

func TestAvatar_RetryOfSameBytesKeepsItsKeyLive(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()

	first := e.row(e.admin, "avatar-kept", 7)
	if err := e.avatars.Reserve(ctx, first); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	retry := *first
	retry.StorageKey = "avatar-fresh"
	if err := e.avatars.Reserve(ctx, &retry); err != nil {
		t.Fatalf("retry reserve: %v", err)
	}
	if retry.StorageKey != "avatar-kept" {
		t.Errorf("storage_key = %q, want the uploaded key kept", retry.StorageKey)
	}
	if e.queued(t, "avatar-kept") {
		t.Error("a reused key must not be queued for deletion")
	}

	other := e.row(e.admin, "avatar-other", 8)
	if err := e.avatars.Reserve(ctx, other); err != nil {
		t.Fatalf("second upload: %v", err)
	}
	if !e.queued(t, "avatar-kept") {
		t.Error("a superseded pending upload must be queued")
	}
}

func TestAvatar_AnotherMemberCannotTakeAnAvatarID(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	a := e.upload(t, e.admin, "avatar-mine")

	stolen := e.row(e.friend, "avatar-theirs", 9)
	stolen.AvatarID = a.AvatarID
	if err := e.avatars.Reserve(ctx, stolen); !errors.Is(err, repository.ErrAvatarNotOwned) {
		t.Fatalf("reserve = %v, want ErrAvatarNotOwned", err)
	}
	if _, err := e.avatars.Confirm(ctx, e.album, e.friend, a.AvatarID); !errors.Is(err, repository.ErrAvatarNotFound) {
		t.Fatalf("confirm = %v, want ErrAvatarNotFound", err)
	}
}

func TestAvatar_RevokeRemovesTheMembersAvatar(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	e.upload(t, e.friend, "avatar-gone")

	if _, _, err := e.repo.RevokeMemberTx(ctx, e.album, e.admin, e.friend); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if got := e.rosterAvatar(t, e.friend); got != nil {
		t.Errorf("revoked member still has an avatar: %+v", got)
	}
	if !e.queued(t, "avatar-gone") {
		t.Error("revoke must queue the avatar object")
	}
	if err := e.avatars.Reserve(ctx, e.row(e.friend, "avatar-late", 3)); !errors.Is(err, repository.ErrCallerRevoked) {
		t.Fatalf("reserve after revoke = %v, want ErrCallerRevoked", err)
	}
}

func TestAvatar_DeleteAlbumQueuesAvatarObjects(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	e.upload(t, e.admin, "avatar-x")
	e.upload(t, e.friend, "avatar-y")

	removed, err := e.repo.DeleteAlbumTx(ctx, e.album, e.admin)
	if err != nil {
		t.Fatalf("delete album: %v", err)
	}
	for _, key := range []string{"avatar-x", "avatar-y"} {
		if !slices.Contains(removed.Keys, key) || !e.queued(t, key) {
			t.Errorf("%s was not returned and queued: %v", key, removed.Keys)
		}
	}
}

func TestAvatar_StalePendingIsRetired(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	live := e.upload(t, e.admin, "avatar-live")
	pending := e.row(e.admin, "avatar-stale", 4)
	if err := e.avatars.Reserve(ctx, pending); err != nil {
		t.Fatalf("reserve: %v", err)
	}

	keys, err := e.avatars.QueueStalePending(ctx, time.Now().Add(time.Hour), 100)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if !slices.Contains(keys, "avatar-stale") || slices.Contains(keys, "avatar-live") {
		t.Errorf("swept keys = %v, want only the pending one", keys)
	}
	if got := e.rosterAvatar(t, e.admin); got == nil || got.AvatarID != live.AvatarID {
		t.Errorf("sweep touched the confirmed avatar: %+v", got)
	}
}

func TestAvatar_AccountDeletionLeavesWithoutAnAvatar(t *testing.T) {
	e := newAvatarEnv(t)
	ctx := context.Background()
	e.upload(t, e.friend, "avatar-leaver")
	linker, err := userlink.New(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	deletions := repository.NewAccountDeletionRepository(e.pool, linker)

	out, err := deletions.RemoveMembership(ctx, e.pal, e.album)
	if err != nil {
		t.Fatalf("remove membership: %v", err)
	}
	if out.Outcome != repository.OutcomeLeave {
		t.Fatalf("outcome = %v, want leave", out.Outcome)
	}
	if !slices.Contains(out.Keys, "avatar-leaver") || !e.queued(t, "avatar-leaver") {
		t.Errorf("avatar was not returned and queued: %v", out.Keys)
	}
}
