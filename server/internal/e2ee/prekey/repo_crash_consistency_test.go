package prekey

import (
	"bytes"
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// These SQL concurrency guarantees require real Postgres
func mustCrashRepo(t *testing.T) (*Repo, *pgxpool.Pool) {
	t.Helper()
	dbURL := os.Getenv("KEEPSY_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set KEEPSY_TEST_DATABASE_URL to run publication crash-consistency tests")
	}
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return NewRepo(pool, repository.NewPrekeyRepository(pool)), pool
}

func seedUserForCrash(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	id := mustSeedUser(t, pool)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id=$1`, id)
	})
	return id
}

func ident(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }
func sig(b byte) []byte   { return bytes.Repeat([]byte{b}, 64) }

func readIdentity(t *testing.T, repo *Repo, id uuid.UUID) *Identity {
	t.Helper()
	got, err := repo.IdentityByID(context.Background(), id)
	if err != nil {
		t.Fatalf("IdentityByID: %v", err)
	}
	return got
}

func TestPublishOrRefreshIdentity_FirstPublishWrites(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	ts := time.Now().Unix()

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA1), ident(0xB1), ident(0xC1), sig(0xD1), ts); err != nil {
		t.Fatalf("first publish: %v", err)
	}
	got := readIdentity(t, repo, user)
	if !bytes.Equal(got.IKPub, ident(0xA1)) || !bytes.Equal(got.SPKPub, ident(0xC1)) {
		t.Fatal("identity columns not written")
	}
	if got.SPKTs == nil || *got.SPKTs != ts {
		t.Fatalf("spk_ts = %v, want %d", got.SPKTs, ts)
	}
}

// An identical retry may refresh its SPK attestation
func TestPublishOrRefreshIdentity_ResendRefreshesAttestation(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	ts := time.Now().Unix()

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA2), ident(0xB2), ident(0xC2), sig(0xD2), ts); err != nil {
		t.Fatalf("first publish: %v", err)
	}
	newTs := ts + 3600
	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA2), ident(0xB2), ident(0xC2), sig(0xE2), newTs); err != nil {
		t.Fatalf("resend: %v", err)
	}
	got := readIdentity(t, repo, user)
	if got.SPKTs == nil || *got.SPKTs != newTs {
		t.Fatalf("spk_ts = %v, want refreshed %d", got.SPKTs, newTs)
	}
	if !bytes.Equal(got.SPKSig, sig(0xE2)) {
		t.Fatal("spk_sig not refreshed alongside spk_ts")
	}
}

// An older identical retry succeeds without regressing the attestation
func TestPublishOrRefreshIdentity_OlderTsResendSucceedsWithoutRegression(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	ts := time.Now().Unix()

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA3), ident(0xB3), ident(0xC3), sig(0xD3), ts); err != nil {
		t.Fatalf("first publish: %v", err)
	}
	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA3), ident(0xB3), ident(0xC3), sig(0xE3), ts-3600); err != nil {
		t.Fatalf("older-ts resend must not conflict: %v", err)
	}
	got := readIdentity(t, repo, user)
	if got.SPKTs == nil || *got.SPKTs != ts {
		t.Fatalf("spk_ts = %v, want unchanged %d", got.SPKTs, ts)
	}
	if !bytes.Equal(got.SPKSig, sig(0xD3)) {
		t.Fatal("spk_sig regressed alongside an older spk_ts")
	}
}

// Equal timestamps are valid exact retries
func TestPublishOrRefreshIdentity_EqualTsResendSucceeds(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	ts := time.Now().Unix()

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA4), ident(0xB4), ident(0xC4), sig(0xD4), ts); err != nil {
		t.Fatalf("first publish: %v", err)
	}
	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA4), ident(0xB4), ident(0xC4), sig(0xD4), ts); err != nil {
		t.Fatalf("equal-ts resend: %v", err)
	}
}

func TestPublishOrRefreshIdentity_DifferentKeysConflict(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	ts := time.Now().Unix()

	for name, other := range map[string][3][]byte{
		"different ik":  {ident(0xFF), ident(0xB5), ident(0xC5)},
		"different lk":  {ident(0xA5), ident(0xFF), ident(0xC5)},
		"different spk": {ident(0xA5), ident(0xB5), ident(0xFF)},
	} {
		t.Run(name, func(t *testing.T) {
			user := seedUserForCrash(t, pool)
			if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA5), ident(0xB5), ident(0xC5), sig(0xD5), ts); err != nil {
				t.Fatalf("first publish: %v", err)
			}
			err := repo.PublishOrRefreshIdentity(ctx, user, other[0], other[1], other[2], sig(0xD5), ts+1)
			if !errors.Is(err, ErrIdentityConflict) {
				t.Fatalf("err = %v, want ErrIdentityConflict", err)
			}
		})
	}
}

// Concurrent first publications must not mix or overwrite identities
func TestPublishOrRefreshIdentity_ConcurrentFirstPublishOnlyOneWins(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	ts := time.Now().Unix()

	var wg sync.WaitGroup
	errs := make([]error, 2)
	keys := [2]byte{0xA6, 0xA7}
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = repo.PublishOrRefreshIdentity(ctx, user,
				ident(keys[i]), ident(keys[i]), ident(keys[i]), sig(keys[i]), ts)
		}()
	}
	wg.Wait()

	var won, conflicted int
	for _, err := range errs {
		switch {
		case err == nil:
			won++
		case errors.Is(err, ErrIdentityConflict):
			conflicted++
		default:
			t.Fatalf("unexpected err: %v", err)
		}
	}
	if won != 1 || conflicted != 1 {
		t.Fatalf("won=%d conflicted=%d, want exactly 1 each", won, conflicted)
	}
	// All identity columns must come from the same winner
	got := readIdentity(t, repo, user)
	if !bytes.Equal(got.IKPub, got.LKPub) || !bytes.Equal(got.IKPub, got.SPKPub) {
		t.Fatal("identity columns mixed between concurrent publishers")
	}
}

// Concurrent rotations must retain a valid audit chain
func TestRotateSPK_ConcurrentRotationsChainAudit(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	base := time.Now().Unix()

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA8), ident(0xB8), ident(0xC8), sig(0xD8), base); err != nil {
		t.Fatalf("seed identity: %v", err)
	}

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = repo.RotateSPK(ctx, user, ident(byte(0xE0+i)), sig(byte(0xE0+i)), base+int64(i)+1)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil && !errors.Is(err, ErrTsNotMonotonic) {
			t.Fatalf("unexpected err: %v", err)
		}
	}

	// Each audit row must point to its actual predecessor
	rows, err := pool.Query(ctx,
		`SELECT old_spk_ts, new_spk_ts FROM spk_rotations WHERE user_id=$1 ORDER BY new_spk_ts`, user)
	if err != nil {
		t.Fatalf("query audit: %v", err)
	}
	defer rows.Close()
	prev := base
	var maxNew int64
	for rows.Next() {
		var oldTs *int64
		var newTs int64
		if err := rows.Scan(&oldTs, &newTs); err != nil {
			t.Fatalf("scan: %v", err)
		}
		if oldTs == nil || *oldTs != prev {
			t.Fatalf("audit old_spk_ts = %v, want %d (the ts that was current)", oldTs, prev)
		}
		prev = newTs
		maxNew = newTs
	}
	got := readIdentity(t, repo, user)
	if got.SPKTs == nil || *got.SPKTs != maxNew {
		t.Fatalf("stored spk_ts = %v, want %d", got.SPKTs, maxNew)
	}
	t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM spk_rotations WHERE user_id=$1`, user) })
}

func TestRotateSPK_RejectsNonMonotonicUnderLock(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)
	base := time.Now().Unix()
	t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM spk_rotations WHERE user_id=$1`, user) })

	if err := repo.PublishOrRefreshIdentity(ctx, user, ident(0xA9), ident(0xB9), ident(0xC9), sig(0xD9), base); err != nil {
		t.Fatalf("seed identity: %v", err)
	}
	if err := repo.RotateSPK(ctx, user, ident(0xEA), sig(0xEA), base-1); !errors.Is(err, ErrTsNotMonotonic) {
		t.Fatalf("err = %v, want ErrTsNotMonotonic", err)
	}
	if err := repo.RotateSPK(ctx, user, ident(0xEB), sig(0xEB), base); !errors.Is(err, ErrTsNotMonotonic) {
		t.Fatalf("equal ts err = %v, want ErrTsNotMonotonic", err)
	}
}

func opkRow(user uuid.UUID, idx int, key byte) model.OneTimePrekey {
	return model.OneTimePrekey{ID: uuid.New(), UserID: user, OPKIdx: idx, KeyPub: ident(key)}
}

func countOPKs(t *testing.T, pool *pgxpool.Pool, user uuid.UUID) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=$1`, user).Scan(&n); err != nil {
		t.Fatalf("count opks: %v", err)
	}
	return n
}

// Byte identical OPK retries are idempotent
func TestCreateBatchAtomic_IdenticalResendSucceeds(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)

	batch := []model.OneTimePrekey{opkRow(user, 0, 0x10), opkRow(user, 1, 0x11)}
	if err := repo.CreateBatchAtomic(ctx, batch); err != nil {
		t.Fatalf("first batch: %v", err)
	}
	resend := []model.OneTimePrekey{opkRow(user, 0, 0x10), opkRow(user, 1, 0x11)}
	if err := repo.CreateBatchAtomic(ctx, resend); err != nil {
		t.Fatalf("identical resend: %v", err)
	}
	if n := countOPKs(t, pool, user); n != 2 {
		t.Fatalf("opk count = %d, want 2 (no duplicates)", n)
	}
}

// Identical retries must not resurrect consumed OPKs
func TestCreateBatchAtomic_ConsumedRowStillCountsAsPublished(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)

	if err := repo.CreateBatchAtomic(ctx, []model.OneTimePrekey{opkRow(user, 0, 0x20)}); err != nil {
		t.Fatalf("first batch: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`UPDATE one_time_prekeys SET consumed = TRUE WHERE user_id=$1 AND opk_idx=0`, user); err != nil {
		t.Fatalf("consume: %v", err)
	}
	if err := repo.CreateBatchAtomic(ctx, []model.OneTimePrekey{opkRow(user, 0, 0x20)}); err != nil {
		t.Fatalf("resend of consumed idx: %v", err)
	}
	var consumed bool
	if err := pool.QueryRow(ctx,
		`SELECT consumed FROM one_time_prekeys WHERE user_id=$1 AND opk_idx=0`, user).Scan(&consumed); err != nil {
		t.Fatalf("read consumed: %v", err)
	}
	if !consumed {
		t.Fatal("resend resurrected a consumed OPK")
	}
}

// A mismatched key rolls back the whole batch
func TestCreateBatchAtomic_MismatchedKeyRollsBackWholeBatch(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)

	if err := repo.CreateBatchAtomic(ctx, []model.OneTimePrekey{opkRow(user, 0, 0x30)}); err != nil {
		t.Fatalf("first batch: %v", err)
	}
	// Insert a new row before encountering the conflicting row
	err := repo.CreateBatchAtomic(ctx, []model.OneTimePrekey{opkRow(user, 1, 0x31), opkRow(user, 0, 0xFF)})
	if !errors.Is(err, ErrOPKIndexTaken) {
		t.Fatalf("err = %v, want ErrOPKIndexTaken", err)
	}
	if n := countOPKs(t, pool, user); n != 1 {
		t.Fatalf("opk count = %d, want 1 : batch did not roll back", n)
	}
}

// Mixed identical and new rows commit atomically
func TestCreateBatchAtomic_MixedResendAndNewCommits(t *testing.T) {
	repo, pool := mustCrashRepo(t)
	ctx := context.Background()
	user := seedUserForCrash(t, pool)

	if err := repo.CreateBatchAtomic(ctx, []model.OneTimePrekey{opkRow(user, 0, 0x40)}); err != nil {
		t.Fatalf("first batch: %v", err)
	}
	if err := repo.CreateBatchAtomic(ctx,
		[]model.OneTimePrekey{opkRow(user, 0, 0x40), opkRow(user, 1, 0x41)}); err != nil {
		t.Fatalf("mixed batch: %v", err)
	}
	if n := countOPKs(t, pool, user); n != 2 {
		t.Fatalf("opk count = %d, want 2", n)
	}
}
