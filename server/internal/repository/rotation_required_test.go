package repository_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/freytastic/keepsy/internal/e2ee/epoch"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
)

// Uses a real database because the debt is set and cleared under album locks
type rotationEnv struct {
	*summaryEnv
	epochs *epoch.Repo
	album  uuid.UUID
	owner  uuid.UUID
	admin  []byte
	member []byte
}

func newRotationEnv(t *testing.T) *rotationEnv {
	t.Helper()
	env := newSummaryEnv(t)
	ctx := context.Background()
	linker, err := userlink.New(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	owner := env.seedUser(t)
	joiner := env.seedUser(t)
	album, admin, err := env.repo.CreateWithAdmin(ctx, []byte("rotation"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	member, err := env.repo.AddMember(ctx, album.ID, joiner, "member")
	if err != nil {
		t.Fatalf("add member: %v", err)
	}
	e := &rotationEnv{
		summaryEnv: env,
		epochs:     epoch.NewRepo(env.pool, linker),
		album:      album.ID,
		owner:      owner,
		admin:      admin,
		member:     member,
	}
	if err := e.epochs.InsertEpoch(ctx, e.epochInput(0, admin, member)); err != nil {
		t.Fatalf("seed epoch 0: %v", err)
	}
	return e
}

func (e *rotationEnv) epochInput(n int, recipients ...[]byte) epoch.InsertEpochInput {
	wraps := make([]epoch.WrapInsert, len(recipients))
	for i, r := range recipients {
		wraps[i] = epoch.WrapInsert{
			RecipientToken: r,
			EkPub:          make([]byte, 32),
			WrapNonce:      make([]byte, 12),
			WrapTagCT:      make([]byte, 48),
			SenderSig:      make([]byte, 64),
		}
	}
	return epoch.InsertEpochInput{
		AlbumID:               e.album,
		Epoch:                 n,
		EpochSig:              make([]byte, 64),
		SenderToken:           e.admin,
		Wraps:                 wraps,
		ExpectedMemberSetHash: epoch.MemberSetHash(recipients),
	}
}

func (e *rotationEnv) required(t *testing.T) bool {
	t.Helper()
	got, err := e.epochs.RotationRequired(context.Background(), e.album)
	if err != nil {
		t.Fatalf("rotation required: %v", err)
	}
	return got
}

func (e *rotationEnv) summaryFlag(t *testing.T) bool {
	t.Helper()
	albums, err := e.repo.ListForUser(context.Background(), e.owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, a := range albums {
		if a.ID == e.album {
			return a.Summary.RotationRequired
		}
	}
	t.Fatal("album missing from the owner's listing")
	return false
}

func (e *rotationEnv) revokeMember(t *testing.T) {
	t.Helper()
	if _, _, err := e.repo.RevokeMemberTx(context.Background(), e.album, e.admin, e.member); err != nil {
		t.Fatalf("revoke: %v", err)
	}
}

func TestRotationRequired_SetByRevokeClearedByNextEpoch(t *testing.T) {
	e := newRotationEnv(t)
	if e.required(t) || e.summaryFlag(t) {
		t.Fatal("a fresh album owes no rotation")
	}

	e.revokeMember(t)
	if !e.required(t) || !e.summaryFlag(t) {
		t.Fatal("a revoke must leave the album owing a rotation")
	}

	if err := e.epochs.InsertEpoch(context.Background(), e.epochInput(1, e.admin)); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if e.required(t) || e.summaryFlag(t) {
		t.Fatal("an epoch for the exact active set settles the rotation")
	}
}

func TestRotationRequired_SurvivesErasedWraps(t *testing.T) {
	e := newRotationEnv(t)
	ctx := context.Background()
	e.revokeMember(t)

	// Account deletion erases the departed member's wraps, so drift disappears
	if _, err := e.pool.Exec(ctx,
		`DELETE FROM album_epoch_wraps WHERE album_id = $1 AND recipient_token = $2`,
		e.album, e.member,
	); err != nil {
		t.Fatalf("erase wraps: %v", err)
	}
	if !e.required(t) {
		t.Fatal("erased wraps must not clear a rotation the album still owes")
	}

	row := pendingRow(e.album, uuid.New(), e.admin, "key-"+uuid.NewString(), "thumb-"+uuid.NewString())
	if err := e.media.ReserveUploadRow(ctx, row, 0); !errors.Is(err, repository.ErrPendingRotation) {
		t.Fatalf("upload under the old key: got %v, want ErrPendingRotation", err)
	}
}

func (e *rotationEnv) reserve(t *testing.T) *model.Media {
	t.Helper()
	row := pendingRow(e.album, uuid.New(), e.admin,
		"key-"+uuid.NewString(), "thumb-"+uuid.NewString())
	if err := e.media.ReserveUploadRow(context.Background(), row, 0); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	return row
}

func TestConfirm_RefusedWhileARotationIsOwed(t *testing.T) {
	e := newRotationEnv(t)
	// The presigned upload was issued before the revoke and completes after it
	row := e.reserve(t)
	e.revokeMember(t)

	_, err := e.media.MarkConfirmed(
		context.Background(), row.ID, e.album, row.ReservationID)
	if !errors.Is(err, repository.ErrPendingRotation) {
		t.Fatalf("confirm under the departed member's key: got %v, want ErrPendingRotation", err)
	}
}

func TestConfirm_RefusedUnderASupersededEpoch(t *testing.T) {
	e := newRotationEnv(t)
	row := e.reserve(t)
	if err := e.epochs.InsertEpoch(
		context.Background(), e.epochInput(1, e.admin, e.member)); err != nil {
		t.Fatalf("rotate: %v", err)
	}

	_, err := e.media.MarkConfirmed(
		context.Background(), row.ID, e.album, row.ReservationID)
	if !errors.Is(err, repository.ErrEpochMismatch) {
		t.Fatalf("confirm under epoch 0: got %v, want ErrEpochMismatch", err)
	}
}

func TestConfirm_PublishesWhileTheEpochIsCurrent(t *testing.T) {
	e := newRotationEnv(t)
	row := e.reserve(t)

	gen, err := e.media.MarkConfirmed(
		context.Background(), row.ID, e.album, row.ReservationID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if gen < 1 {
		t.Fatalf("generation = %d, want the album to advance", gen)
	}
}

func TestRotationRequired_RejectedEpochDoesNotClear(t *testing.T) {
	e := newRotationEnv(t)
	e.revokeMember(t)

	// Still wraps for the removed member, so the member set drifts
	err := e.epochs.InsertEpoch(context.Background(), e.epochInput(1, e.admin, e.member))
	if !errors.Is(err, epoch.ErrMemberSetDrift) {
		t.Fatalf("got %v, want ErrMemberSetDrift", err)
	}
	if !e.required(t) {
		t.Fatal("a refused epoch must leave the rotation owed")
	}
}
