package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"slices"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

type fakeAvatarRepo struct {
	rows      map[uuid.UUID]*model.MemberAvatar
	dropped   []uuid.UUID
	confirmed []uuid.UUID
	replaced  []string
}

func (f *fakeAvatarRepo) Reserve(_ context.Context, a *model.MemberAvatar) error {
	cp := *a
	f.rows[a.AvatarID] = &cp
	return nil
}

func (f *fakeAvatarRepo) Get(_ context.Context, albumID, avatarID uuid.UUID) (*model.MemberAvatar, error) {
	a, ok := f.rows[avatarID]
	if !ok || a.AlbumID != albumID {
		return nil, repository.ErrAvatarNotFound
	}
	cp := *a
	return &cp, nil
}

func (f *fakeAvatarRepo) Confirm(_ context.Context, _ uuid.UUID, _ []byte, avatarID uuid.UUID) ([]string, error) {
	f.confirmed = append(f.confirmed, avatarID)
	f.rows[avatarID].Confirmed = true
	return f.replaced, nil
}

func (f *fakeAvatarRepo) DropPending(_ context.Context, _ uuid.UUID, _ []byte, avatarID uuid.UUID) ([]string, error) {
	f.dropped = append(f.dropped, avatarID)
	key := f.rows[avatarID].StorageKey
	delete(f.rows, avatarID)
	return []string{key}, nil
}

func (f *fakeAvatarRepo) Remove(context.Context, uuid.UUID, []byte) ([]string, error) {
	return nil, nil
}

func (f *fakeAvatarRepo) QueueStalePending(context.Context, time.Time, int) ([]string, error) {
	return nil, nil
}

type avatarFixture struct {
	svc     *AvatarService
	repo    *fakeAvatarRepo
	s3      *fakeS3
	cleaner *recordingCleaner
	notif   *captureNotifier
	album   uuid.UUID
	caller  uuid.UUID
	peer    uuid.UUID
	token   []byte
}

func newAvatarFixture() *avatarFixture {
	f := &avatarFixture{
		repo:    &fakeAvatarRepo{rows: map[uuid.UUID]*model.MemberAvatar{}},
		s3:      &fakeS3{},
		cleaner: &recordingCleaner{},
		notif:   &captureNotifier{},
		album:   uuid.New(),
		caller:  uuid.New(),
		peer:    uuid.New(),
		token:   bytes.Repeat([]byte{0x11}, 32),
	}
	f.svc = NewAvatarService(f.repo, f.s3, f.cleaner, f.notif,
		&stubLookup{ids: []uuid.UUID{f.caller, f.peer}})
	return f
}

func (f *avatarFixture) input() AvatarUploadInput {
	return AvatarUploadInput{
		AvatarID:   uuid.New(),
		BlobSize:   131101,
		BlobSHA256: bytes.Repeat([]byte{0x22}, 32),
		KeyCT:      make([]byte, avatarKeyCTLen),
	}
}

func (f *avatarFixture) reserve(t *testing.T, in AvatarUploadInput) *model.MemberAvatar {
	t.Helper()
	if _, err := f.svc.RequestUploadURL(context.Background(), f.album, f.token, in); err != nil {
		t.Fatalf("request upload: %v", err)
	}
	return f.repo.rows[in.AvatarID]
}

func TestAvatarUpload_RejectsMalformedInput(t *testing.T) {
	f := newAvatarFixture()
	cases := map[string]func(*AvatarUploadInput){
		"no id":        func(in *AvatarUploadInput) { in.AvatarID = uuid.Nil },
		"empty":        func(in *AvatarUploadInput) { in.BlobSize = 0 },
		"too big":      func(in *AvatarUploadInput) { in.BlobSize = MaxAvatarBytes + 1 },
		"short sha":    func(in *AvatarUploadInput) { in.BlobSHA256 = make([]byte, 31) },
		"short key_ct": func(in *AvatarUploadInput) { in.KeyCT = make([]byte, avatarKeyCTLen-1) },
	}
	for name, mutate := range cases {
		in := f.input()
		mutate(&in)
		_, err := f.svc.RequestUploadURL(context.Background(), f.album, f.token, in)
		if !apierr.IsCode(err, "E_VALIDATION") {
			t.Errorf("%s: err = %v, want E_VALIDATION", name, err)
		}
	}
	if len(f.repo.rows) != 0 {
		t.Errorf("rejected input reached the repo: %d rows", len(f.repo.rows))
	}
}

func TestAvatarUpload_PresignsTheReservedKey(t *testing.T) {
	f := newAvatarFixture()
	row := f.reserve(t, f.input())
	if row == nil || row.StorageKey == "" {
		t.Fatal("no reservation")
	}
	if !slices.Equal(f.s3.presignKeys, []string{row.StorageKey}) {
		t.Errorf("presigned %v, want the reserved key %q", f.s3.presignKeys, row.StorageKey)
	}
}

func TestAvatarConfirm_MismatchDropsTheReservation(t *testing.T) {
	f := newAvatarFixture()
	in := f.input()
	row := f.reserve(t, in)
	f.s3.headSize = in.BlobSize
	f.s3.headSHA256B64 = base64.StdEncoding.EncodeToString(make([]byte, 32))

	err := f.svc.Confirm(context.Background(), f.album, f.caller, f.token, in.AvatarID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if len(f.repo.confirmed) != 0 {
		t.Error("a mismatched object must never be confirmed")
	}
	if !slices.Equal(f.repo.dropped, []uuid.UUID{in.AvatarID}) {
		t.Errorf("dropped = %v, want the reservation", f.repo.dropped)
	}
	if !slices.Contains(f.cleaner.keys, row.StorageKey) {
		t.Errorf("cleaned %v, want %q", f.cleaner.keys, row.StorageKey)
	}
}

func TestAvatarConfirm_OtherMembersCannotConfirm(t *testing.T) {
	f := newAvatarFixture()
	in := f.input()
	f.reserve(t, in)
	err := f.svc.Confirm(context.Background(), f.album, f.caller,
		bytes.Repeat([]byte{0x99}, 32), in.AvatarID)
	if !apierr.IsCode(err, "E_FORBIDDEN") {
		t.Fatalf("err = %v, want E_FORBIDDEN", err)
	}
}

func TestAvatarConfirm_SwapsCleansAndNotifiesOthers(t *testing.T) {
	f := newAvatarFixture()
	in := f.input()
	f.reserve(t, in)
	f.repo.replaced = []string{"old-key"}
	f.s3.headSize = in.BlobSize
	f.s3.headSHA256B64 = base64.StdEncoding.EncodeToString(in.BlobSHA256)

	if err := f.svc.Confirm(context.Background(), f.album, f.caller, f.token, in.AvatarID); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if !slices.Equal(f.cleaner.keys, []string{"old-key"}) {
		t.Errorf("cleaned %v, want the replaced key", f.cleaner.keys)
	}
	waitFor(t, func() bool { return len(f.notif.snapshot()) == 1 })
	got := f.notif.snapshot()[0]
	if got.typ != ws.EventMemberUpdated {
		t.Errorf("event = %q, want %q", got.typ, ws.EventMemberUpdated)
	}
	if !slices.Equal(got.users, []uuid.UUID{f.peer}) {
		t.Errorf("notified %v, want only the other member", got.users)
	}

	// A repeated confirm after a lost response must not notify again
	if err := f.svc.Confirm(context.Background(), f.album, f.caller, f.token, in.AvatarID); err != nil {
		t.Fatalf("repeat confirm: %v", err)
	}
	time.Sleep(20 * time.Millisecond)
	if n := len(f.notif.snapshot()); n != 1 {
		t.Errorf("emits = %d after a repeat confirm, want 1", n)
	}
}

func TestAvatarDownload_RefusesPendingUploads(t *testing.T) {
	f := newAvatarFixture()
	in := f.input()
	f.reserve(t, in)
	if _, err := f.svc.DownloadURL(context.Background(), f.album, in.AvatarID); !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
	if _, err := f.svc.DownloadURL(context.Background(), uuid.New(), in.AvatarID); !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("another album: err = %v, want E_NOT_FOUND", err)
	}
}
