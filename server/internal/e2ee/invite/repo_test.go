package invite

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"os"
	"testing"

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

func TestDeliverMember_WritesRowsAndConsumesOPK(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()

	albumID := uuid.New()
	targetID := uuid.New()
	senderID := uuid.New()
	senderToken := randToken(t)

	if _, err := pool.Exec(ctx, `INSERT INTO albums (id, name_ct) VALUES ($1, $2)`, albumID, []byte("nm")); err != nil {
		t.Fatalf("seed album: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO users (id, email_hmac, keepsy_id) VALUES ($1, $2, $3)`,
		targetID, targetID[:], targetID.String()); err != nil {
		t.Fatalf("seed target: %v", err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO one_time_prekeys (user_id, opk_idx, key_pub) VALUES ($1, 5, $2)`,
		targetID, make([]byte, 32)); err != nil {
		t.Fatalf("seed opk: %v", err)
	}
	senderSealed, err := linker.Seal(senderID, senderToken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
		senderToken, linker.Hash(senderID), senderSealed, albumID); err != nil {
		t.Fatalf("seed sender amid: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM album_member_identities WHERE album_id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, targetID)
	})

	idx := 5
	token, err := repo.DeliverMember(ctx, DeliverMemberInput{
		AlbumID:     albumID,
		UserID:      targetID,
		SenderToken: senderToken,
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
	_, err = repo.DeliverMember(ctx, DeliverMemberInput{
		AlbumID:     albumID,
		UserID:      targetID,
		SenderToken: senderToken,
		EKPub:       make([]byte, 32),
		OPKIdxUsed:  nil,
		Envelopes:   envs(0, 1, 2),
	})
	if !errors.Is(err, ErrAlreadyMember) {
		t.Fatalf("re-invite err = %v, want ErrAlreadyMember", err)
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
