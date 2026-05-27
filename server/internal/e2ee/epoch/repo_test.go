package epoch

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"testing"

	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func mkRand(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// TestPendingMembers exercises the 24h / epoch-behind threshold against a real
// DB. Skipped without KEEPSY_TEST_DATABASE_URL
func TestPendingMembers(t *testing.T) {
	dbURL := os.Getenv("KEEPSY_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set KEEPSY_TEST_DATABASE_URL to run real-DB pending-members test")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("pgxpool: %v", err)
	}
	t.Cleanup(pool.Close)
	linker, err := userlink.New([]byte("epoch-pending-test-master-key-32"))
	if err != nil {
		t.Fatal(err)
	}
	repo := NewRepo(pool, linker)

	albumID := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO albums (id, name_ct) VALUES ($1, $2)`, albumID, []byte("n")); err != nil {
		t.Fatalf("seed album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, `DELETE FROM album_members WHERE album_id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM album_member_identities WHERE album_id = $1`, albumID)
		_, _ = pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, albumID)
	})

	seed := func(lreSQL, lraSQL string, revoked bool) []byte {
		token := mkRand(t, 32)
		if _, err := pool.Exec(ctx, fmt.Sprintf(
			`INSERT INTO album_member_identities
			 (member_token, user_handle, user_id_enc, album_id, last_received_epoch, last_received_at)
			 VALUES ($1, $2, $3, $4, %s, %s)`, lreSQL, lraSQL),
			token, mkRand(t, 32), mkRand(t, 16), albumID); err != nil {
			t.Fatalf("seed amid: %v", err)
		}
		revokedSQL := "NULL"
		if revoked {
			revokedSQL = "now()"
		}
		if _, err := pool.Exec(ctx, fmt.Sprintf(
			`INSERT INTO album_members (album_id, member_token, role, revoked_at) VALUES ($1, $2, 'member', %s)`, revokedSQL),
			albumID, token); err != nil {
			t.Fatalf("seed member: %v", err)
		}
		return token
	}

	const newEpoch = 3                                             // caught up threshold is newEpoch-1 = 2
	caughtUp := seed("2", "now()", false)                          // acked epoch 2 → not pending
	behindStale := seed("1", "now() - interval '25 hours'", false) // 2 behind + >24h → pending
	never := seed("NULL", "NULL", false)                           // never acked → pending
	behindRecent := seed("1", "now() - interval '1 hours'", false) // behind but acked <24h → not pending
	revokedStale := seed("0", "now() - interval '25 hours'", true) // would qualify but revoked → excluded

	got, err := repo.PendingMembers(ctx, albumID, newEpoch)
	if err != nil {
		t.Fatalf("PendingMembers: %v", err)
	}
	gotSet := make(map[string]bool, len(got))
	for _, tok := range got {
		gotSet[hex.EncodeToString(tok)] = true
	}
	want := map[string][]byte{"behindStale": behindStale, "never": never}
	exclude := map[string][]byte{"caughtUp": caughtUp, "behindRecent": behindRecent, "revokedStale": revokedStale}

	if len(got) != len(want) {
		t.Fatalf("pending count = %d, want %d", len(got), len(want))
	}
	for name, tok := range want {
		if !gotSet[hex.EncodeToString(tok)] {
			t.Errorf("expected %s to be pending, missing", name)
		}
	}
	for name, tok := range exclude {
		if gotSet[hex.EncodeToString(tok)] {
			t.Errorf("%s must not be pending", name)
		}
	}
}
