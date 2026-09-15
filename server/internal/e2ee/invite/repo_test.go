package invite

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/freytastic/keepsy/internal/e2ee/epoch"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func randToken(t *testing.T) []byte {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// testRepo wires a realDB invite Repo. Skipped without KEEPSY_TEST_DATABASE_URL
func testRepo(t *testing.T) (*Repo, *userlink.Hasher, *pgxpool.Pool) {
	t.Helper()
	dbURL := os.Getenv("KEEPSY_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set KEEPSY_TEST_DATABASE_URL to run real-DB invite repo tests")
	}
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("pgxpool: %v", err)
	}
	t.Cleanup(pool.Close)
	linker, err := userlink.New([]byte("invite-repo-test-master-key-32by"))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	return NewRepo(pool, linker, repository.NewUserRepository(pool)), linker, pool
}

// inviteAlbum is an album the sender administers at a current epoch, with the
// sender's own wraps so no rotation is owed
type inviteAlbum struct {
	id          uuid.UUID
	senderID    uuid.UUID
	senderToken []byte
}

func seedUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	id := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO users (id, email_hmac, keepsy_id) VALUES ($1, $2, $3)`,
		id, id[:], id.String()); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, id)
	})
	return id
}

func seedInviteAlbum(t *testing.T, pool *pgxpool.Pool, linker *userlink.Hasher, current int) inviteAlbum {
	t.Helper()
	ctx := context.Background()
	a := inviteAlbum{id: uuid.New(), senderID: seedUser(t, pool), senderToken: randToken(t)}
	if _, err := pool.Exec(ctx, `INSERT INTO albums (id, name_ct) VALUES ($1, $2)`, a.id, []byte("nm")); err != nil {
		t.Fatalf("seed album: %v", err)
	}
	// Registered after the user so the album goes first
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, a.id)
	})
	sealed, err := linker.Seal(a.senderID, a.senderToken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
		a.senderToken, linker.Hash(a.senderID), sealed, a.id); err != nil {
		t.Fatalf("seed sender amid: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'admin')`,
		a.id, a.senderToken); err != nil {
		t.Fatalf("seed sender membership: %v", err)
	}
	for e := 0; e <= current; e++ {
		a.addEpoch(t, pool, e, a.senderToken)
	}
	return a
}

func (a inviteAlbum) addEpoch(t *testing.T, pool *pgxpool.Pool, epoch int, recipients ...[]byte) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `INSERT INTO album_epochs (album_id, epoch) VALUES ($1, $2)`, a.id, epoch); err != nil {
		t.Fatalf("seed epoch %d: %v", epoch, err)
	}
	for _, r := range recipients {
		if _, err := pool.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, wrap_nonce, wrap_tag_ct, sender_token, sender_sig)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
			a.id, epoch, r, make([]byte, 32), make([]byte, 12), make([]byte, 48), a.senderToken, make([]byte, 64)); err != nil {
			t.Fatalf("seed wrap: %v", err)
		}
	}
}

func (a inviteAlbum) deliver(repo *Repo, target uuid.UUID, epochs ...int) ([]byte, error) {
	return repo.DeliverMember(context.Background(), DeliverMemberInput{
		AlbumID:     a.id,
		UserID:      target,
		SenderToken: a.senderToken,
		EKPub:       make([]byte, 32),
		Envelopes:   envs(epochs...),
	})
}

func TestDeliverMember_WritesRowsAndConsumesOPK(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()

	album := seedInviteAlbum(t, pool, linker, 2)
	albumID := album.id
	targetID := seedUser(t, pool)
	if _, err := pool.Exec(ctx, `INSERT INTO one_time_prekeys (user_id, opk_idx, key_pub) VALUES ($1, 5, $2)`,
		targetID, make([]byte, 32)); err != nil {
		t.Fatalf("seed opk: %v", err)
	}

	idx := 5
	token, err := repo.DeliverMember(ctx, DeliverMemberInput{
		AlbumID:     albumID,
		UserID:      targetID,
		SenderToken: album.senderToken,
		EKPub:       make([]byte, 32),
		OPKIdxUsed:  &idx,
		Envelopes:   envs(0, 1, 2),
	})
	if err != nil {
		t.Fatalf("DeliverMember: %v", err)
	}
	if len(token) != 32 {
		t.Fatalf("token len = %d, want 32", len(token))
	}

	var role string
	if err := pool.QueryRow(ctx, `SELECT role FROM album_members WHERE album_id=$1 AND member_token=$2`,
		albumID, token).Scan(&role); err != nil {
		t.Fatalf("new member row: %v", err)
	}
	if role != "member" {
		t.Fatalf("role = %q, want member", role)
	}

	var wrapCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM album_epoch_wraps WHERE album_id=$1 AND recipient_token=$2`,
		albumID, token).Scan(&wrapCount); err != nil {
		t.Fatal(err)
	}
	if wrapCount != 3 {
		t.Fatalf("wrap rows = %d, want 3 (epochs 0..2)", wrapCount)
	}

	var consumed bool
	if err := pool.QueryRow(ctx, `SELECT consumed FROM one_time_prekeys WHERE user_id=$1 AND opk_idx=5`,
		targetID).Scan(&consumed); err != nil {
		t.Fatal(err)
	}
	if !consumed {
		t.Fatal("OPK idx 5 not marked consumed")
	}

	// Reinvite the same user → unique (user_handle, album_id) violation → ErrAlreadyMember
	if _, err := album.deliver(repo, targetID, 0, 1, 2); !errors.Is(err, ErrAlreadyMember) {
		t.Fatalf("re-invite err = %v, want ErrAlreadyMember", err)
	}
}

// Reactivation must reuse the tombstoned token and replace its wraps
func TestDeliverMember_ReactivatesRevokedMember(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()

	album := seedInviteAlbum(t, pool, linker, 1)
	albumID := album.id
	targetID := seedUser(t, pool)

	first, err := album.deliver(repo, targetID, 0, 1)
	if err != nil {
		t.Fatalf("first deliver: %v", err)
	}
	// Promote so we can prove reactivation resets role back to member
	if _, err := pool.Exec(ctx, `UPDATE album_members SET role = 'co-admin' WHERE member_token = $1`, first); err != nil {
		t.Fatalf("promote: %v", err)
	}
	// Kick: tombstone the membership, then the admin rotates past it
	if _, err := pool.Exec(ctx, `UPDATE album_members SET revoked_at = NOW() WHERE member_token = $1`, first); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	album.addEpoch(t, pool, 2, album.senderToken)

	// Re invite the revoked member: must succeed and reuse the same token
	second, err := album.deliver(repo, targetID, 0, 1, 2)
	if err != nil {
		t.Fatalf("re-invite of revoked member should reactivate, got: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("reactivation should reuse the same member_token (M-bridge 1:1 slot)")
	}

	var role string
	var revoked bool
	if err := pool.QueryRow(ctx,
		`SELECT role, revoked_at IS NOT NULL FROM album_members WHERE member_token = $1`, first,
	).Scan(&role, &revoked); err != nil {
		t.Fatalf("read reactivated row: %v", err)
	}
	if revoked {
		t.Fatal("revoked_at should be cleared after reactivation")
	}
	if role != "member" {
		t.Fatalf("role = %q, want member (rejoin as plain member)", role)
	}

	var idCount, wrapCount int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM album_member_identities
		 WHERE album_id = $1 AND user_handle = $2`,
		albumID, linker.Hash(targetID),
	).Scan(&idCount); err != nil {
		t.Fatal(err)
	}
	if idCount != 1 {
		t.Fatalf("identity rows = %d, want 1 (reused slot)", idCount)
	}
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM album_epoch_wraps WHERE album_id = $1 AND recipient_token = $2`, albumID, first,
	).Scan(&wrapCount); err != nil {
		t.Fatal(err)
	}
	if wrapCount != 3 {
		t.Fatalf("wrap rows = %d, want 3 (epochs 0..2 upserted)", wrapCount)
	}
}

// The member cap must roll back both identity and roster writes
func TestDeliverMember_RejectsWhenAlbumFull(t *testing.T) {
	repo, linker, pool := testRepo(t)
	album := seedInviteAlbum(t, pool, linker, 0)

	for i := range MaxAlbumMembers - 1 {
		if _, err := album.deliver(repo, seedUser(t, pool), 0); err != nil {
			t.Fatalf("delivery %d/%d should succeed, got: %v", i+1, MaxAlbumMembers-1, err)
		}
	}
	if _, err := album.deliver(repo, seedUser(t, pool), 0); !errors.Is(err, ErrAlbumFull) {
		t.Fatalf("delivery past cap err = %v, want ErrAlbumFull", err)
	}
}

func TestDeliverMember_RefusesWhatChangedBeforeTheLock(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()

	cases := []struct {
		name  string
		setup func(a inviteAlbum, target uuid.UUID)
		want  error
	}{
		{"a rotation committed after the envelopes were built", func(a inviteAlbum, _ uuid.UUID) {
			a.addEpoch(t, pool, 1, a.senderToken)
		}, ErrEpochMoved},
		{"a rotation is owed", func(a inviteAlbum, _ uuid.UUID) {
			mustExec(t, pool, `UPDATE albums SET rotation_required = TRUE WHERE id = $1`, a.id)
		}, ErrPendingRotation},
		{"the sender was removed", func(a inviteAlbum, _ uuid.UUID) {
			mustExec(t, pool, `UPDATE album_members SET revoked_at = NOW() WHERE member_token = $1`, a.senderToken)
		}, ErrSenderRevoked},
		{"the sender only holds the dormant co-admin role", func(a inviteAlbum, _ uuid.UUID) {
			mustExec(t, pool, `UPDATE album_members SET role = 'co-admin' WHERE member_token = $1`, a.senderToken)
		}, ErrSenderNotAdmin},
		{"the sender is deleting their account", func(a inviteAlbum, _ uuid.UUID) {
			mustExec(t, pool, `UPDATE users SET deleting_at = now() WHERE id = $1`, a.senderID)
		}, ErrSenderRevoked},
		{"the target is deleting their account", func(_ inviteAlbum, target uuid.UUID) {
			mustExec(t, pool, `UPDATE users SET deleting_at = now() WHERE id = $1`, target)
		}, ErrTargetDeleting},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			album := seedInviteAlbum(t, pool, linker, 0)
			target := seedUser(t, pool)
			tc.setup(album, target)

			if _, err := album.deliver(repo, target, 0); !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			var n int
			if err := pool.QueryRow(ctx,
				`SELECT count(*) FROM album_member_identities WHERE album_id = $1 AND user_handle = $2`,
				album.id, linker.Hash(target)).Scan(&n); err != nil {
				t.Fatal(err)
			}
			if n != 0 {
				t.Fatal("a refused invite must not leave a membership behind")
			}
		})
	}
}

// Without the recheck, a rotation landing between the service's epoch read and
// the invite commit made the invitee a member who never receives the new key
func TestDeliverMember_RaceWithRotationNeverStrandsTheInvitee(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()
	epochs := epoch.NewRepo(pool, linker)

	for i := range 25 {
		album := seedInviteAlbum(t, pool, linker, 0)
		target := seedUser(t, pool)

		var inviteErr, rotateErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, inviteErr = album.deliver(repo, target, 0)
		}()
		go func() {
			defer wg.Done()
			<-start
			rotateErr = epochs.InsertEpoch(ctx, epoch.InsertEpochInput{
				AlbumID:     album.id,
				Epoch:       1,
				EpochSig:    make([]byte, 64),
				SenderToken: album.senderToken,
				Wraps: []epoch.WrapInsert{{
					RecipientToken: album.senderToken,
					EkPub:          make([]byte, 32),
					WrapNonce:      make([]byte, 12),
					WrapTagCT:      make([]byte, 48),
					SenderSig:      make([]byte, 64),
				}},
				ExpectedMemberSetHash: epoch.MemberSetHash([][]byte{album.senderToken}),
			})
		}()
		close(start)
		wg.Wait()

		switch {
		case inviteErr == nil && rotateErr == nil:
			t.Fatalf("round %d: both committed, the invitee holds no key for epoch 1", i)
		case inviteErr == nil && !errors.Is(rotateErr, epoch.ErrMemberSetDrift):
			t.Fatalf("round %d: rotation after the invite: got %v, want member set drift", i, rotateErr)
		case rotateErr == nil && !errors.Is(inviteErr, ErrEpochMoved):
			t.Fatalf("round %d: invite after the rotation: got %v, want ErrEpochMoved", i, inviteErr)
		case inviteErr != nil && rotateErr != nil:
			t.Fatalf("round %d: neither committed: invite %v, rotate %v", i, inviteErr, rotateErr)
		}
	}
}

func TestIKByMemberToken_And_MarkReceivedHighWaterMark(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()

	albumID := uuid.New()
	userID := uuid.New()
	token := randToken(t)
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := pool.Exec(ctx, `INSERT INTO albums (id, name_ct) VALUES ($1, $2)`, albumID, []byte("n")); err != nil {
		t.Fatalf("seed album: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO users (id, email_hmac, keepsy_id, ik_pub) VALUES ($1, $2, $3, $4)`,
		userID, userID[:], userID.String(), []byte(pub)); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	sealed, err := linker.Seal(userID, token)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
		token, linker.Hash(userID), sealed, albumID); err != nil {
		t.Fatalf("seed amid: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM album_member_identities WHERE album_id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID)
	})

	gotIK, err := repo.IKByMemberToken(ctx, token)
	if err != nil {
		t.Fatalf("IKByMemberToken: %v", err)
	}
	if !bytes.Equal(gotIK, pub) {
		t.Fatal("resolved IK does not match seeded ik_pub")
	}

	readEpoch := func() int {
		var e int
		if err := pool.QueryRow(ctx,
			`SELECT last_received_epoch FROM album_member_identities WHERE member_token = $1`, token).Scan(&e); err != nil {
			t.Fatalf("read last_received_epoch: %v", err)
		}
		return e
	}

	if err := repo.MarkReceived(ctx, token, 2); err != nil {
		t.Fatal(err)
	}
	if got := readEpoch(); got != 2 {
		t.Fatalf("after mark(2): %d, want 2", got)
	}
	if err := repo.MarkReceived(ctx, token, 1); err != nil { // stale, must not regress
		t.Fatal(err)
	}
	if got := readEpoch(); got != 2 {
		t.Fatalf("after stale mark(1): %d, want 2 (high-water held)", got)
	}
	if err := repo.MarkReceived(ctx, token, 5); err != nil {
		t.Fatal(err)
	}
	if got := readEpoch(); got != 5 {
		t.Fatalf("after mark(5): %d, want 5", got)
	}

	// Unknown token → ErrIKNotFound
	if _, err := repo.IKByMemberToken(ctx, randToken(t)); !errors.Is(err, ErrIKNotFound) {
		t.Fatalf("unknown token err = %v, want ErrIKNotFound", err)
	}
}
