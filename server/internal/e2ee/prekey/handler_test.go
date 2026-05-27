package prekey

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// captureNotifier is a Notifier stub that pushes every emit onto a channel
type captureNotifier struct {
	ch chan emittedEvent
}

type emittedEvent struct {
	users []uuid.UUID
	typ   string
	data  any
}

func (c *captureNotifier) EmitToUsers(_ context.Context, ids []uuid.UUID, typ string, payload any) error {
	c.ch <- emittedEvent{users: ids, typ: typ, data: payload}
	return nil
}

func newRouter(h *Handler) http.Handler {
	r := mux.NewRouter()
	r.HandleFunc("/users/me/keys", h.UpsertIdentity).Methods(http.MethodPut)
	r.HandleFunc("/users/me/spk", h.RotateSPK).Methods(http.MethodPost)
	r.HandleFunc("/users/me/opks", h.ReplenishOPKs).Methods(http.MethodPost)
	r.HandleFunc("/users/me/opks/count", h.GetOPKCount).Methods(http.MethodGet)
	r.HandleFunc("/users/{id}/prekey-bundle", h.GetPrekeyBundle).Methods(http.MethodGet)
	r.HandleFunc("/users/by-handle/{handle}/prekey-bundle", h.GetPrekeyBundleByHandle).Methods(http.MethodGet)
	return r
}

type stubResolver struct {
	fn func(ctx context.Context, keepsyID string) (uuid.UUID, error)
}

func (s stubResolver) FindUserIDByKeepsyID(ctx context.Context, k string) (uuid.UUID, error) {
	return s.fn(ctx, k)
}

func authReq(method, path string, body []byte, userID uuid.UUID) *http.Request {
	var rdr *bytes.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	var req *http.Request
	if rdr != nil {
		req = httptest.NewRequest(method, path, rdr)
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	ctx := context.WithValue(req.Context(), middleware.UserIDKey, userID)
	return req.WithContext(ctx)
}

func TestUpsertIdentity_OneShot(t *testing.T) {
	ikPub, priv, spk, _ := genIdentity(t, fixedTs)
	sig := ed25519.Sign(priv, spkSelfMsg(spk, fixedTs))

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			// already set => one shot rule must trip
			return &Identity{IKPub: []byte(ikPub), SPKPub: spk}, nil
		},
		upsertIdentityFn: func(_ context.Context, _ uuid.UUID, _, _, _, _ []byte, _ int64) error {
			t.Fatal("UpsertIdentity must not be called when identity already set")
			return nil
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	h := NewHandler(svc, nil, nil)

	body, _ := json.Marshal(map[string]any{
		"ik_pub":  base64.StdEncoding.EncodeToString(ikPub),
		"lk_pub":  base64.StdEncoding.EncodeToString(make([]byte, 32)),
		"spk_pub": base64.StdEncoding.EncodeToString(spk),
		"spk_sig": base64.StdEncoding.EncodeToString(sig),
		"spk_ts":  fixedTs,
	})
	req := authReq(http.MethodPut, "/users/me/keys", body, uuid.New())
	rec := httptest.NewRecorder()
	newRouter(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", rec.Code)
	}
	var env struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&env)
	if env.Code != "E_IDENTITY_ALREADY_SET" {
		t.Fatalf("code = %q, want E_IDENTITY_ALREADY_SET", env.Code)
	}
}

func TestPrekeyBundle_OpkLowEmitted(t *testing.T) {
	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	target := uuid.New()
	requester := uuid.New()

	opkPub := make([]byte, 32)
	for i := range opkPub {
		opkPub[i] = byte(i)
	}

	popped := atomic.Int32{}
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(_ context.Context, uid uuid.UUID) (*model.OneTimePrekey, error) {
			popped.Add(1)
			return &model.OneTimePrekey{ID: uuid.New(), UserID: uid, OPKIdx: 1, KeyPub: opkPub}, nil
		},
		countFn: func(_ context.Context, _ uuid.UUID) (int, error) {
			return 4, nil // post-pop count, below threshold of 5
		},
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)

	notif := &captureNotifier{ch: make(chan emittedEvent, 1)}
	h := NewHandler(svc, notif, nil)

	rec := httptest.NewRecorder()
	req := authReq(http.MethodGet, "/users/"+target.String()+"/prekey-bundle", nil, requester)
	newRouter(h).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	select {
	case ev := <-notif.ch:
		if ev.typ != ws.EventOPKLow {
			t.Errorf("type = %q, want %q", ev.typ, ws.EventOPKLow)
		}
		payload, _ := ev.data.(map[string]any)
		if payload == nil || payload["remaining"] != 4 {
			t.Errorf("payload.remaining = %v, want 4", payload)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for OPK-low emit")
	}
}

func TestPrekeyBundle_DoesNotEmitWhenAtOrAboveThreshold(t *testing.T) {
	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	opkPub := make([]byte, 32)
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(_ context.Context, _ uuid.UUID) (*model.OneTimePrekey, error) {
			return &model.OneTimePrekey{ID: uuid.New(), OPKIdx: 1, KeyPub: opkPub}, nil
		},
		countFn: func(_ context.Context, _ uuid.UUID) (int, error) { return 5, nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	notif := &captureNotifier{ch: make(chan emittedEvent, 1)}
	h := NewHandler(svc, notif, nil)

	rec := httptest.NewRecorder()
	req := authReq(http.MethodGet, "/users/"+uuid.NewString()+"/prekey-bundle", nil, uuid.New())
	newRouter(h).ServeHTTP(rec, req)

	select {
	case ev := <-notif.ch:
		t.Errorf("unexpected emit at threshold: %+v", ev)
	case <-time.After(150 * time.Millisecond):
	}
}

// TestPrekeyBundle_ConcurrentConsumesDistinctOPKs exercises the real Postgres
// SKIP LOCKED path. Skipped without KEEPSY_TEST_DATABASE_URL since the in mem
// fixture cannot prove the row level concurrency guarantee
func TestPrekeyBundle_ConcurrentConsumesDistinctOPKs(t *testing.T) {
	dbURL := os.Getenv("KEEPSY_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set KEEPSY_TEST_DATABASE_URL to run real-DB concurrency test")
	}
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	prekeyRepo := repository.NewPrekeyRepository(pool)
	repo := NewRepo(pool, prekeyRepo)
	target := mustSeedUser(t, pool)
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id=$1`, target) })

	// Seed identity + 6 OPKs
	ts := int64(time.Now().Unix())
	if err := repo.UpsertIdentity(context.Background(), target,
		bytes.Repeat([]byte{0xAA}, 32), bytes.Repeat([]byte{0xBB}, 32),
		bytes.Repeat([]byte{0xCC}, 32), bytes.Repeat([]byte{0xDD}, 64), ts); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	rows := make([]model.OneTimePrekey, 6)
	for i := range rows {
		rows[i] = model.OneTimePrekey{
			ID: uuid.New(), UserID: target, OPKIdx: i,
			KeyPub: bytes.Repeat([]byte{byte(0xE0 + i)}, 32),
		}
	}
	if err := repo.CreateBatchAtomic(context.Background(), rows); err != nil {
		t.Fatalf("seed opks: %v", err)
	}

	svc := NewService(repo)
	h := NewHandler(svc, nil, nil)
	router := newRouter(h)

	type result struct {
		idx int
		ok  bool
	}
	results := make(chan result, 6)
	var wg sync.WaitGroup
	for range 6 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := httptest.NewRecorder()
			req := authReq(http.MethodGet, "/users/"+target.String()+"/prekey-bundle", nil, uuid.New())
			router.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK {
				results <- result{ok: false}
				return
			}
			var body struct {
				OPK *struct {
					Idx int `json:"idx"`
				} `json:"opk"`
			}
			_ = json.NewDecoder(rec.Body).Decode(&body)
			if body.OPK == nil {
				results <- result{ok: false}
				return
			}
			results <- result{idx: body.OPK.Idx, ok: true}
		}()
	}
	wg.Wait()
	close(results)

	seen := map[int]int{}
	count := 0
	for r := range results {
		if !r.ok {
			continue
		}
		seen[r.idx]++
		count++
	}
	if count != 6 {
		t.Fatalf("got %d successes, want 6", count)
	}
	for idx, n := range seen {
		if n != 1 {
			t.Errorf("opk_idx %d returned %d times, want 1", idx, n)
		}
	}
}

func TestPrekeyBundleByHandle(t *testing.T) {
	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	target := uuid.New()
	const goodHandle = "K7F29QXM"

	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(_ context.Context, uid uuid.UUID) (*model.OneTimePrekey, error) {
			return &model.OneTimePrekey{ID: uuid.New(), UserID: uid, OPKIdx: 7, KeyPub: make([]byte, 32)}, nil
		},
		countFn: func(_ context.Context, _ uuid.UUID) (int, error) { return 10, nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	resolver := stubResolver{fn: func(_ context.Context, k string) (uuid.UUID, error) {
		if k == goodHandle {
			return target, nil
		}
		return uuid.Nil, repository.ErrUserNotFound
	}}
	h := NewHandler(svc, nil, resolver)

	t.Run("valid handle -> 200 with user_id=keepsy_id (not UUID)", func(t *testing.T) {
		rec := httptest.NewRecorder()
		// lowercase+dash form exercises Normalize on the way in
		req := authReq(http.MethodGet, "/users/by-handle/k7f2-9qxm/prekey-bundle", nil, uuid.New())
		newRouter(h).ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d want 200; body=%s", rec.Code, rec.Body.String())
		}
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body["user_id"] != goodHandle {
			t.Fatalf("user_id=%v want %q", body["user_id"], goodHandle)
		}
		if _, err := uuid.Parse(fmt.Sprint(body["user_id"])); err == nil {
			t.Fatalf("user_id is a UUID (%v): real id must never reach the wire", body["user_id"])
		}
		for _, k := range []string{"ik_pub", "lk_pub", "spk_pub", "spk_sig", "spk_ts", "opk"} {
			if _, ok := body[k]; !ok {
				t.Errorf("missing field %q", k)
			}
		}
	})

	t.Run("unknown handle -> 404", func(t *testing.T) {
		rec := httptest.NewRecorder()
		req := authReq(http.MethodGet, "/users/by-handle/ZZZZZZZZ/prekey-bundle", nil, uuid.New())
		newRouter(h).ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("status=%d want 404", rec.Code)
		}
	})

	t.Run("malformed handle -> 404 (indistinguishable)", func(t *testing.T) {
		rec := httptest.NewRecorder()
		req := authReq(http.MethodGet, "/users/by-handle/bad!!handle/prekey-bundle", nil, uuid.New())
		newRouter(h).ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("status=%d want 404; body=%s", rec.Code, rec.Body.String())
		}
	})
}

func TestPrekeyBundleByHandle_RateLimit(t *testing.T) {
	redisURL := os.Getenv("KEEPSY_TEST_REDIS_URL")
	if redisURL == "" {
		t.Skip("set KEEPSY_TEST_REDIS_URL to run rate-limit test")
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisURL})
	t.Cleanup(func() { _ = rdb.Close() })
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		t.Skipf("redis ping: %v", err)
	}
	limiter := middleware.NewRateLimiter(rdb)

	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	target := uuid.New()
	const goodHandle = "K7F29QXM"
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(_ context.Context, _ uuid.UUID) (*model.OneTimePrekey, error) { return nil, nil },
		countFn:     func(_ context.Context, _ uuid.UUID) (int, error) { return 0, nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	resolver := stubResolver{fn: func(_ context.Context, _ string) (uuid.UUID, error) { return target, nil }}
	h := NewHandler(svc, nil, resolver)

	r := mux.NewRouter()
	r.Handle(
		"/users/by-handle/{handle}/prekey-bundle",
		limiter.Middleware(KeyByRequesterAndHandle, 5, 60*time.Second)(http.HandlerFunc(h.GetPrekeyBundleByHandle)),
	).Methods(http.MethodGet)

	requester := uuid.New()
	_ = rdb.Del(context.Background(), "prekey-bundle-handle:"+requester.String()+":"+goodHandle).Err()

	for i := range 5 {
		rec := httptest.NewRecorder()
		req := authReq(http.MethodGet, "/users/by-handle/"+goodHandle+"/prekey-bundle", nil, requester)
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("call %d: status=%d want 200", i+1, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	req := authReq(http.MethodGet, "/users/by-handle/"+goodHandle+"/prekey-bundle", nil, requester)
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("6th call status=%d want 429", rec.Code)
	}
}

// TestPrekeyBundle_RateLimit drives the actual middleware.RateLimiter against a
// real Redis. Skipped without KEEPSY_TEST_REDIS_URL
func TestPrekeyBundle_RateLimit(t *testing.T) {
	redisURL := os.Getenv("KEEPSY_TEST_REDIS_URL")
	if redisURL == "" {
		t.Skip("set KEEPSY_TEST_REDIS_URL to run rate-limit test")
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisURL})
	t.Cleanup(func() { _ = rdb.Close() })
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		t.Skipf("redis ping: %v", err)
	}
	limiter := middleware.NewRateLimiter(rdb)

	ikPub, _, spk, sig := genIdentity(t, fixedTs)
	ts := int64(fixedTs)
	store := &mockStore{
		identityByIDFn: func(_ context.Context, _ uuid.UUID) (*Identity, error) {
			return &Identity{IKPub: []byte(ikPub), LKPub: make([]byte, 32), SPKPub: spk, SPKSig: sig, SPKTs: &ts}, nil
		},
		popRandomFn: func(_ context.Context, _ uuid.UUID) (*model.OneTimePrekey, error) { return nil, nil },
		countFn:     func(_ context.Context, _ uuid.UUID) (int, error) { return 0, nil },
	}
	svc := NewService(store)
	svc.SetClock(fixedClock)
	h := NewHandler(svc, nil, nil)

	r := mux.NewRouter()
	r.Handle(
		"/users/{id}/prekey-bundle",
		limiter.Middleware(KeyByRequesterAndTarget, 5, 60*time.Second)(http.HandlerFunc(h.GetPrekeyBundle)),
	).Methods(http.MethodGet)

	requester := uuid.New()
	target := uuid.New()
	// Wipe limiter slot from any prior test run
	_ = rdb.Del(context.Background(), "prekey-bundle:"+requester.String()+":"+target.String()).Err()

	for i := range 5 {
		rec := httptest.NewRecorder()
		req := authReq(http.MethodGet, "/users/"+target.String()+"/prekey-bundle", nil, requester)
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("call %d: status = %d, want 200", i+1, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	req := authReq(http.MethodGet, "/users/"+target.String()+"/prekey-bundle", nil, requester)
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("6th call status = %d, want 429", rec.Code)
	}
	var env struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&env)
	if env.Code != "E_RATE_LIMITED" {
		t.Errorf("code = %q, want E_RATE_LIMITED", env.Code)
	}
}

// mustSeedUser inserts a minimal users row and returns its id. Used by the
// realDB concurrency test
func mustSeedUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	id := uuid.New()
	email := fmt.Sprintf("test-%s@example.com", id.String())
	if _, err := pool.Exec(context.Background(),
		`INSERT INTO users (id, email_hmac, keepsy_id) VALUES ($1, $2, $3)`,
		id, []byte(email), id.String()); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return id
}
