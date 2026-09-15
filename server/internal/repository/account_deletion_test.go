package repository_test

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
)

type emitted struct {
	users []uuid.UUID
	typ   string
	data  map[string]any
}

type recordingNotifier struct {
	mu    sync.Mutex
	calls []emitted
}

func (n *recordingNotifier) EmitToUsers(_ context.Context, users []uuid.UUID, typ string, payload any) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls = append(n.calls, emitted{users: users, typ: typ, data: payload.(map[string]any)})
	return nil
}

func (n *recordingNotifier) of(typ string, album uuid.UUID) []emitted {
	n.mu.Lock()
	defer n.mu.Unlock()
	var out []emitted
	for _, c := range n.calls {
		if c.typ == typ && c.data["album_id"] == album.String() {
			out = append(out, c)
		}
	}
	return out
}

type failingCleaner struct{ calls int }

func (c *failingCleaner) CleanupObjectKeys(context.Context, []string) { c.calls++ }

// deletionEnv is an account with every kind of album deletion has to settle
type deletionEnv struct {
	*summaryEnv
	deletions *repository.AccountDeletionRepository
	linker    *userlink.Hasher
	user      uuid.UUID
	friend    uuid.UUID
	other     uuid.UUID

	shared   uuid.UUID // the user administers it, friend is a member
	joined   uuid.UUID // other administers it, the user is a member
	solo     uuid.UUID // only the user
	departed uuid.UUID // the user left it earlier, their photos remain

	userKeys  []string
	otherKeys []string
}

func newDeletionEnv(t *testing.T) *deletionEnv {
	t.Helper()
	ctx := context.Background()
	env := newSummaryEnv(t)
	linker, err := userlink.New(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	e := &deletionEnv{
		summaryEnv: env,
		deletions:  repository.NewAccountDeletionRepository(env.pool, linker),
		linker:     linker,
		user:       env.seedUser(t),
		friend:     env.seedUser(t),
		other:      env.seedUser(t),
	}

	album := func(owner uuid.UUID) (uuid.UUID, []byte) {
		a, tok, err := env.repo.CreateWithAdmin(ctx, []byte("album"), owner)
		if err != nil {
			t.Fatalf("create album: %v", err)
		}
		t.Cleanup(func() {
			_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, a.ID)
		})
		return a.ID, tok
	}
	join := func(albumID, user uuid.UUID) []byte {
		tok, err := env.repo.AddMember(ctx, albumID, user, "member")
		if err != nil {
			t.Fatalf("add member: %v", err)
		}
		return tok
	}

	var userShared, userJoined, userSolo, userDeparted, otherJoined []byte
	e.shared, userShared = album(e.user)
	join(e.shared, e.friend)
	e.joined, otherJoined = album(e.other)
	userJoined = join(e.joined, e.user)
	e.solo, userSolo = album(e.user)
	var otherDeparted []byte
	e.departed, otherDeparted = album(e.other)
	userDeparted = join(e.departed, e.user)

	for _, a := range []uuid.UUID{e.shared, e.joined, e.solo, e.departed} {
		env.ensureEpoch(t, a)
	}
	e.userKeys = append(e.userKeys, e.photo(t, e.shared, userShared)...)
	e.userKeys = append(e.userKeys, e.photo(t, e.joined, userJoined)...)
	e.userKeys = append(e.userKeys, e.photo(t, e.solo, userSolo)...)
	e.userKeys = append(e.userKeys, e.photo(t, e.departed, userDeparted)...)
	e.otherKeys = append(e.otherKeys, e.photo(t, e.joined, otherJoined)...)
	e.otherKeys = append(e.otherKeys, e.photo(t, e.departed, otherDeparted)...)

	if _, _, err := env.repo.RevokeMemberTx(ctx, e.departed, userDeparted, userDeparted); err != nil {
		t.Fatalf("leave departed album: %v", err)
	}
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1, $2, now() + interval '1 day')`,
		e.user, repository.HashToken("session-"+e.user.String()),
	); err != nil {
		t.Fatalf("seed session: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(context.Background(),
			`DELETE FROM media_object_cleanup WHERE storage_key = ANY($1)`,
			append(append([]string{}, e.userKeys...), e.otherKeys...))
	})
	return e
}

func (e *deletionEnv) photo(t *testing.T, albumID uuid.UUID, uploader []byte) []string {
	t.Helper()
	id := uuid.New()
	key, thumb := "blob/"+id.String(), "thumb/"+id.String()
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO media (id, album_id, uploader_token, storage_key, thumb_key,
		   wrap_nonce, wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, confirmed)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, 0, 10, $8, 'photo', TRUE)`,
		id, albumID, uploader, key, thumb, make([]byte, 12), make([]byte, 48), make([]byte, 32),
	); err != nil {
		t.Fatalf("insert photo: %v", err)
	}
	return []string{key, thumb}
}

func (e *deletionEnv) count(t *testing.T, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", sql, err)
	}
	return n
}

func (e *deletionEnv) queued(t *testing.T, keys []string) int {
	return e.count(t, `SELECT count(*) FROM media_object_cleanup WHERE storage_key = ANY($1)`, keys)
}

func (e *deletionEnv) accept(t *testing.T) {
	t.Helper()
	if err := e.deletions.Accept(context.Background(), e.user, []uuid.UUID{e.shared}, e.receipt(t)); err != nil {
		t.Fatalf("accept: %v", err)
	}
}

// Stands in for the sha256 of a device random value
func (e *deletionEnv) receipt(t *testing.T) []byte {
	t.Helper()
	b := make([]byte, 32)
	copy(b, uuid.New().String())
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM account_deletion_receipts WHERE receipt_hash = $1`, b)
	})
	return b
}

func (e *deletionEnv) runJob(t *testing.T, notifier service.Notifier) {
	t.Helper()
	// Other tests may have left a job leased into the future
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE account_deletions SET next_attempt_at = now() WHERE user_id = $1`, e.user); err != nil {
		t.Fatalf("make job due: %v", err)
	}
	svc := service.NewAccountDeletionService(e.deletions, nil, notifier)
	svc.ProcessDue(context.Background())
}

// assertGone checks the end state every run of the job must converge on
func (e *deletionEnv) assertGone(t *testing.T) {
	t.Helper()
	if n := e.count(t, `SELECT count(*) FROM users WHERE id = $1`, e.user); n != 0 {
		t.Fatal("the user row survived")
	}
	if n := e.count(t, `SELECT count(*) FROM account_deletions WHERE user_id = $1`, e.user); n != 0 {
		t.Fatal("the job row survived")
	}
	if n := e.count(t, `SELECT count(*) FROM albums WHERE id = ANY($1)`, []uuid.UUID{e.shared, e.solo}); n != 0 {
		t.Fatal("an album the user administered survived")
	}
	if n := e.count(t, `SELECT count(*) FROM albums WHERE id = ANY($1)`, []uuid.UUID{e.joined, e.departed}); n != 2 {
		t.Fatal("an album someone else administers was deleted")
	}
	if n := e.count(t, `SELECT count(*) FROM media WHERE storage_key = ANY($1)`, e.userKeys); n != 0 {
		t.Fatalf("%d of the user's photos survived", n)
	}
	if n := e.count(t, `SELECT count(*) FROM media WHERE storage_key = ANY($1)`, e.otherKeys); n != 2 {
		t.Fatalf("other members' photos: %d rows, want 2", n)
	}
	if n := e.queued(t, e.userKeys); n != len(e.userKeys) {
		t.Fatalf("queued objects = %d, want all %d of the user's", n, len(e.userKeys))
	}
	if n := e.queued(t, e.otherKeys); n != 0 {
		t.Fatal("another member's objects were queued for deletion")
	}
	if n := e.count(t, `SELECT count(*) FROM album_member_identities WHERE user_handle = $1`,
		e.linker.Hash(e.user)); n != 0 {
		t.Fatalf("%d membership rows still link back to the user", n)
	}
	var owed bool
	if err := e.pool.QueryRow(context.Background(),
		`SELECT rotation_required FROM albums WHERE id = $1`, e.joined).Scan(&owed); err != nil {
		t.Fatal(err)
	}
	if !owed {
		t.Fatal("the album the user left must owe a rotation")
	}
}

func TestAccountDeletion_PreflightDescribesEveryAlbum(t *testing.T) {
	e := newDeletionEnv(t)
	ms, err := e.deletions.Memberships(context.Background(), e.user)
	if err != nil {
		t.Fatalf("memberships: %v", err)
	}
	got := map[uuid.UUID]repository.DeletionOutcome{}
	for _, m := range ms {
		got[m.AlbumID] = m.Outcome()
	}
	want := map[uuid.UUID]repository.DeletionOutcome{
		e.shared:   repository.OutcomeDeleteShared,
		e.joined:   repository.OutcomeLeave,
		e.solo:     repository.OutcomeDeleteAlbum,
		e.departed: repository.OutcomeErase,
	}
	for id, outcome := range want {
		if got[id] != outcome {
			t.Errorf("album %s: outcome %q, want %q", id, got[id], outcome)
		}
	}
}

func TestAccountDeletion_RefusesAPlanMissingASharedAlbum(t *testing.T) {
	e := newDeletionEnv(t)
	receipt := e.receipt(t)
	err := e.deletions.Accept(context.Background(), e.user, nil, receipt)
	if !errors.Is(err, repository.ErrDeletionPlanStale) {
		t.Fatalf("got %v, want ErrDeletionPlanStale", err)
	}
	if ok, err := e.deletions.ReceiptAccepted(context.Background(), receipt); err != nil || ok {
		t.Fatalf("a refused plan must leave no receipt: ok=%v err=%v", ok, err)
	}
	if n := e.count(t, `SELECT count(*) FROM users WHERE id = $1 AND deleting_at IS NULL`, e.user); n != 1 {
		t.Fatal("a refused plan must not start deleting the account")
	}
}

func TestAccountDeletion_AcceptBlocksTheAccountAtOnce(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	e.accept(t)
	// Idempotent for a client retrying a lost response
	e.accept(t)

	sessions := repository.NewSessionRepository(e.pool)
	if _, err := sessions.GetByToken(ctx, "session-"+e.user.String()); err == nil {
		t.Fatal("the session survived acceptance")
	}
	// A session racing acceptance is refused as well
	if _, err := e.pool.Exec(ctx,
		`INSERT INTO sessions (user_id, token_hash, expires_at) VALUES ($1, $2, now() + interval '1 day')`,
		e.user, repository.HashToken("late-"+e.user.String())); err != nil {
		t.Fatal(err)
	}
	if _, err := sessions.GetByToken(ctx, "late-"+e.user.String()); err == nil {
		t.Fatal("a session of a deleting account authenticated")
	}
	if _, _, err := e.repo.CreateWithAdmin(ctx, []byte("new"), e.user); !errors.Is(err, repository.ErrAccountDeleting) {
		t.Fatalf("create album while deleting: got %v, want ErrAccountDeleting", err)
	}
	if n := e.count(t, `SELECT count(*) FROM account_deletions WHERE user_id = $1`, e.user); n != 1 {
		t.Fatal("acceptance must queue exactly one job")
	}
}

func TestAccountDeletion_JobSettlesEveryAlbum(t *testing.T) {
	e := newDeletionEnv(t)
	e.accept(t)
	notifier := &recordingNotifier{}
	e.runJob(t, notifier)
	e.assertGone(t)

	if got := notifier.of("e2ee.album_deleted", e.shared); len(got) != 1 || len(got[0].users) != 1 || got[0].users[0] != e.friend {
		t.Errorf("shared album deletion must reach the friend only, got %+v", got)
	}
	if got := notifier.of("e2ee.member_revoked", e.joined); len(got) != 1 || got[0].users[0] != e.other {
		t.Errorf("the admin must learn the user left, got %+v", got)
	}
	if got := notifier.of("e2ee.media_deleted", e.joined); len(got) != 1 {
		t.Errorf("the admin must drop the user's photos, got %+v", got)
	}
	if got := notifier.of("e2ee.media_deleted", e.departed); len(got) != 1 {
		t.Errorf("an album the user left must drop their photos too, got %+v", got)
	}
}

// Each step commits on its own, so a crash after any number of them must
// still converge on the same end state
func TestAccountDeletion_ResumesAfterACrashAtEveryStep(t *testing.T) {
	for crashAfter := 0; crashAfter <= 4; crashAfter++ {
		e := newDeletionEnv(t)
		ctx := context.Background()
		e.accept(t)

		// The crashed worker had claimed the job, which leases it
		if _, ok, err := e.deletions.ClaimDue(ctx); err != nil || !ok {
			t.Fatalf("claim: ok=%v err=%v", ok, err)
		}
		ms, err := e.deletions.Memberships(ctx, e.user)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range ms[:crashAfter] {
			if _, err := e.deletions.RemoveMembership(ctx, e.user, m.AlbumID); err != nil {
				t.Fatalf("step: %v", err)
			}
		}
		if n := e.count(t, `SELECT count(*) FROM account_deletions
			WHERE user_id = $1 AND next_attempt_at > now()`, e.user); n != 1 {
			t.Fatal("a claimed job must stay leased")
		}

		e.runJob(t, nil)
		e.assertGone(t)
	}
}

func TestAccountDeletion_RepeatingAStepIsHarmless(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	e.accept(t)
	for range 2 {
		if _, err := e.deletions.RemoveMembership(ctx, e.user, e.joined); err != nil {
			t.Fatalf("step: %v", err)
		}
	}
	e.runJob(t, nil)
	e.assertGone(t)
}

// A storage outage cannot fail the job, the rows are gone and the sweep owns
// the objects from here
func TestAccountDeletion_StorageFailuresStayQueued(t *testing.T) {
	e := newDeletionEnv(t)
	e.accept(t)
	cleaner := &failingCleaner{}
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE account_deletions SET next_attempt_at = now() WHERE user_id = $1`, e.user); err != nil {
		t.Fatal(err)
	}
	service.NewAccountDeletionService(e.deletions, cleaner, nil).ProcessDue(context.Background())

	e.assertGone(t)
	if cleaner.calls == 0 {
		t.Fatal("the job never tried to delete the objects promptly")
	}
}

func TestAccountDeletion_FinishWaitsForALateMembership(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	e.accept(t)
	done, err := e.deletions.FinishAccount(ctx, e.user)
	if err != nil {
		t.Fatal(err)
	}
	if done {
		t.Fatal("the account was deleted while memberships remain")
	}
	if n := e.count(t, `SELECT count(*) FROM users WHERE id = $1`, e.user); n != 1 {
		t.Fatal("the user row must survive until every album is settled")
	}
}

func TestDeleteAlbumTx_QueuesEveryObjectWithTheRows(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	admin, _, err := e.repo.LookupMember(ctx, e.user, e.shared)
	if err != nil {
		t.Fatal(err)
	}
	friendToken, _, err := e.repo.LookupMember(ctx, e.friend, e.shared)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.DeleteAlbumTx(ctx, e.shared, friendToken); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("member deleting the album: got %v, want ErrNotAlbumAdmin", err)
	}

	removed, err := e.repo.DeleteAlbumTx(ctx, e.shared, admin)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(removed.MemberUserIDs) != 1 || removed.MemberUserIDs[0] != e.friend {
		t.Errorf("members to notify = %v, want the friend", removed.MemberUserIDs)
	}
	if n := e.count(t, `SELECT count(*) FROM albums WHERE id = $1`, e.shared); n != 0 {
		t.Fatal("album row survived")
	}
	if n := e.queued(t, removed.Keys); n != 2 || len(removed.Keys) != 2 {
		t.Fatalf("queued %d of %v, want the photo and its thumbnail", n, removed.Keys)
	}
}

func TestDeleteOwnedMedia_QueuesObjectsAndRefusesOthers(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	userToken, _, err := e.repo.LookupMember(ctx, e.user, e.joined)
	if err != nil {
		t.Fatal(err)
	}
	var otherPhoto, userPhoto uuid.UUID
	if err := e.pool.QueryRow(ctx, `SELECT id FROM media WHERE storage_key = $1`, e.otherKeys[0]).Scan(&otherPhoto); err != nil {
		t.Fatal(err)
	}
	if err := e.pool.QueryRow(ctx, `SELECT id FROM media WHERE storage_key = $1`, e.userKeys[2]).Scan(&userPhoto); err != nil {
		t.Fatal(err)
	}

	if _, err := e.media.DeleteOwnedMedia(ctx, e.joined, otherPhoto, userToken); !errors.Is(err, repository.ErrMediaNotOwned) {
		t.Fatalf("deleting someone else's photo: got %v, want ErrMediaNotOwned", err)
	}
	removed, err := e.media.DeleteOwnedMedia(ctx, e.joined, userPhoto, userToken)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(removed.MediaIDs) != 1 || removed.MediaIDs[0] != userPhoto {
		t.Errorf("removed = %v, want the user's photo", removed.MediaIDs)
	}
	if n := e.queued(t, e.userKeys[2:4]); n != 2 {
		t.Fatalf("queued %d, want the photo and its thumbnail", n)
	}
	if n := e.count(t, `SELECT count(*) FROM media WHERE id = $1`, otherPhoto); n != 1 {
		t.Fatal("another member's photo was removed")
	}
}

// Legacy data: a co-admin could sign epochs carrying other members' wraps,
// and that signed history must not pin their identity row forever
func TestAccountDeletion_HistoricalSignatureDoesNotBlockTheJob(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	userToken, _, err := e.repo.LookupMember(ctx, e.user, e.joined)
	if err != nil {
		t.Fatal(err)
	}
	otherToken, _, err := e.repo.LookupMember(ctx, e.other, e.joined)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx,
		`UPDATE album_members SET role = 'co-admin' WHERE member_token = $1`, userToken); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO album_epochs (album_id, epoch) VALUES ($1, 1)`, e.joined); err != nil {
		t.Fatal(err)
	}
	for _, recipient := range [][]byte{userToken, otherToken} {
		if _, err := e.pool.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, wrap_nonce, wrap_tag_ct, sender_token, sender_sig)
			 VALUES ($1, 1, $2, $3, $4, $5, $6, $7)`,
			e.joined, recipient, make([]byte, 32), make([]byte, 12), make([]byte, 48), userToken, make([]byte, 64),
		); err != nil {
			t.Fatal(err)
		}
	}

	e.accept(t)
	e.runJob(t, nil)
	e.assertGone(t)

	var kept []byte
	if err := e.pool.QueryRow(ctx,
		`SELECT sender_token FROM album_epoch_wraps WHERE album_id = $1 AND epoch = 1 AND recipient_token = $2`,
		e.joined, otherToken).Scan(&kept); err != nil {
		t.Fatalf("the other member's signed wrap must survive: %v", err)
	}
	if !bytes.Equal(kept, userToken) {
		t.Fatal("the historical signer token must be kept as an unlinkable value")
	}
}

// The response to an accepted deletion can be lost after every session is gone,
// so the receipt is the only way the device learns it must still wipe
func TestAccountDeletion_ReceiptProvesAcceptanceWithoutASession(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	first, retry := e.receipt(t), e.receipt(t)
	if err := e.deletions.Accept(ctx, e.user, []uuid.UUID{e.shared}, first); err != nil {
		t.Fatalf("accept: %v", err)
	}
	// A retry that raced the first request is recorded as well
	if err := e.deletions.Accept(ctx, e.user, nil, retry); err != nil {
		t.Fatalf("retry: %v", err)
	}
	for _, r := range [][]byte{first, retry} {
		if ok, err := e.deletions.ReceiptAccepted(ctx, r); err != nil || !ok {
			t.Fatalf("receipt not found: ok=%v err=%v", ok, err)
		}
	}

	e.runJob(t, nil)
	e.assertGone(t)
	if ok, err := e.deletions.ReceiptAccepted(ctx, first); err != nil || !ok {
		t.Fatal("the receipt must outlive the deleted account")
	}
	if n := e.count(t, `SELECT count(*) FROM account_deletion_receipts WHERE receipt_hash = $1 AND accepted_at > now()`, first); n != 0 {
		t.Fatal("receipt time must be hour quantized, never ahead of now")
	}
}

// Keeping the account on a device that never learned the outcome must stop an
// old request carrying the same receipt from being accepted later
func TestAccountDeletion_AbandonedReceiptCanNeverBeAccepted(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	receipt := e.receipt(t)

	for range 2 {
		accepted, err := e.deletions.AbandonReceipt(ctx, receipt)
		if err != nil || accepted {
			t.Fatalf("abandon: accepted=%v err=%v", accepted, err)
		}
	}
	err := e.deletions.Accept(ctx, e.user, []uuid.UUID{e.shared}, receipt)
	if !errors.Is(err, repository.ErrReceiptAbandoned) {
		t.Fatalf("late request: got %v, want ErrReceiptAbandoned", err)
	}
	if n := e.count(t, `SELECT count(*) FROM users WHERE id = $1 AND deleting_at IS NULL`, e.user); n != 1 {
		t.Fatal("an abandoned receipt started a deletion")
	}
	if ok, _ := e.deletions.ReceiptAccepted(ctx, receipt); ok {
		t.Fatal("an abandoned receipt must not read as accepted")
	}
}

func TestAccountDeletion_AbandonAfterAcceptanceReportsIt(t *testing.T) {
	e := newDeletionEnv(t)
	ctx := context.Background()
	receipt := e.receipt(t)
	if err := e.deletions.Accept(ctx, e.user, []uuid.UUID{e.shared}, receipt); err != nil {
		t.Fatalf("accept: %v", err)
	}
	accepted, err := e.deletions.AbandonReceipt(ctx, receipt)
	if err != nil || !accepted {
		t.Fatalf("abandon after acceptance: accepted=%v err=%v", accepted, err)
	}
	if ok, _ := e.deletions.ReceiptAccepted(ctx, receipt); !ok {
		t.Fatal("abandon must not hide an acceptance")
	}
}

// Whichever commits first, the device and the server agree on the outcome
func TestAccountDeletion_RaceBetweenAcceptAndAbandonHasOneWinner(t *testing.T) {
	for i := range 25 {
		e := newDeletionEnv(t)
		ctx := context.Background()
		receipt := e.receipt(t)

		var acceptErr, abandonErr error
		var sawAccepted bool
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			acceptErr = e.deletions.Accept(ctx, e.user, []uuid.UUID{e.shared}, receipt)
		}()
		go func() {
			defer wg.Done()
			<-start
			sawAccepted, abandonErr = e.deletions.AbandonReceipt(ctx, receipt)
		}()
		close(start)
		wg.Wait()

		if abandonErr != nil {
			t.Fatalf("round %d: abandon: %v", i, abandonErr)
		}
		deleting := e.count(t, `SELECT count(*) FROM users WHERE id = $1 AND deleting_at IS NOT NULL`, e.user) == 1
		switch {
		case acceptErr == nil && sawAccepted && deleting:
		case errors.Is(acceptErr, repository.ErrReceiptAbandoned) && !sawAccepted && !deleting:
		default:
			t.Fatalf("round %d: accept=%v abandonSawAccepted=%v deleting=%v", i, acceptErr, sawAccepted, deleting)
		}
	}
}
