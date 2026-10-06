package repository

import (
	"context"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

func testOTPRepo(t *testing.T) (*OTPRepository, string) {
	t.Helper()
	addr := os.Getenv("MIUCHIO_TEST_REDIS_URL")
	if addr == "" {
		t.Skip("MIUCHIO_TEST_REDIS_URL not set")
	}
	rdb := redis.NewClient(&redis.Options{Addr: addr})
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		t.Skipf("redis ping: %v", err)
	}
	key := "test-" + uuid.NewString()
	t.Cleanup(func() {
		rdb.Del(context.Background(), "otp:"+key, "otp-attempts:"+key, "ratelimit:"+key)
		rdb.Close()
	})
	return NewOTPRepository(rdb), key
}

func TestOTP_MatchConsumesCode(t *testing.T) {
	r, key := testOTPRepo(t)
	ctx := context.Background()
	if err := r.SetOTP(ctx, key, "good", time.Minute); err != nil {
		t.Fatal(err)
	}
	if ok, err := r.CheckOTP(ctx, key, "good", 5); err != nil || !ok {
		t.Fatalf("first check = %v, %v; want match", ok, err)
	}
	if ok, _ := r.CheckOTP(ctx, key, "good", 5); ok {
		t.Fatal("a used code matched again")
	}
}

func TestOTP_BurnedAfterMaxAttempts(t *testing.T) {
	r, key := testOTPRepo(t)
	ctx := context.Background()
	if err := r.SetOTP(ctx, key, "good", time.Minute); err != nil {
		t.Fatal(err)
	}
	for i := range 3 {
		if ok, err := r.CheckOTP(ctx, key, "bad", 3); err != nil || ok {
			t.Fatalf("miss %d = %v, %v", i, ok, err)
		}
	}
	if ok, _ := r.CheckOTP(ctx, key, "good", 3); ok {
		t.Fatal("the right code still worked after the attempt limit")
	}
	// A fresh code starts a fresh count
	if err := r.SetOTP(ctx, key, "good", time.Minute); err != nil {
		t.Fatal(err)
	}
	if ok, _ := r.CheckOTP(ctx, key, "bad", 3); ok {
		t.Fatal("wrong code matched")
	}
	if ok, _ := r.CheckOTP(ctx, key, "good", 3); !ok {
		t.Fatal("a new code did not reset the attempt count")
	}
}

// Parallel guesses must not all pass before any attempt is counted
func TestOTP_ParallelGuessesAreCounted(t *testing.T) {
	r, key := testOTPRepo(t)
	ctx := context.Background()
	if err := r.SetOTP(ctx, key, "good", time.Minute); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.CheckOTP(ctx, key, "bad", 5)
		}()
	}
	wg.Wait()
	if ok, _ := r.CheckOTP(ctx, key, "good", 5); ok {
		t.Fatal("code survived 50 parallel wrong guesses")
	}
}

func TestOTP_RateLimitIsExactUnderConcurrency(t *testing.T) {
	r, key := testOTPRepo(t)
	ctx := context.Background()
	var allowed atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, err := r.CheckRateLimit(ctx, key, 3, time.Minute); err == nil && ok {
				allowed.Add(1)
			}
		}()
	}
	wg.Wait()
	if n := allowed.Load(); n != 3 {
		t.Fatalf("allowed %d requests, want 3", n)
	}
	ttl := r.Redis.PTTL(ctx, "ratelimit:"+key).Val()
	if ttl <= 0 || ttl > time.Minute {
		t.Fatalf("counter TTL = %v, want within the window", ttl)
	}
}
