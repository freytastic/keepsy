package middleware

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/redis/go-redis/v9"
)

// RateLimiter is a Redis backed sliding window rate limiter
type RateLimiter struct {
	rdb *redis.Client
}

func NewRateLimiter(rdb *redis.Client) *RateLimiter {
	return &RateLimiter{rdb: rdb}
}

type LimitConfig struct {
	Key    string
	Max    int
	Window time.Duration
}

// Allow records an event and reports whether it stayed under the limit
func (r *RateLimiter) Allow(ctx context.Context, cfg LimitConfig) (bool, int, error) {
	if cfg.Max <= 0 || cfg.Window <= 0 {
		return false, 0, errors.New("ratelimit: Max and Window must be > 0")
	}
	now := time.Now().UnixNano()
	cutoff := now - cfg.Window.Nanoseconds()

	pipe := r.rdb.TxPipeline()
	pipe.ZRemRangeByScore(ctx, cfg.Key, "0", strconv.FormatInt(cutoff, 10))
	cardCmd := pipe.ZCard(ctx, cfg.Key)
	pipe.ZAdd(ctx, cfg.Key, redis.Z{Score: float64(now), Member: now})
	pipe.PExpire(ctx, cfg.Key, cfg.Window+time.Second)

	if _, err := pipe.Exec(ctx); err != nil {
		return false, 0, fmt.Errorf("ratelimit: redis pipeline: %w", err)
	}

	current := int(cardCmd.Val())
	if current >= cfg.Max {
		_ = r.rdb.ZRem(ctx, cfg.Key, now).Err()
		return false, current, nil
	}
	return true, current, nil
}

// ProbeDistinctMiddleware tracks distinct values per key over a window and
// logs a warning when the distinct count exceeds threshold. Useful for
// detecting "one user fetching many different targets" probing patterns
// where a sliding window count alone wouldnt notice (eg 5/min per pair
// is fine, but 50 distinct pairs/hr from one requester is sus)
func (r *RateLimiter) ProbeDistinctMiddleware(
	keyFn func(*http.Request) (key, member string),
	threshold int,
	window time.Duration,
) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			key, member := keyFn(req)
			if key != "" && member != "" {
				pipe := r.rdb.TxPipeline()
				addCmd := pipe.SAdd(req.Context(), key, member)
				pipe.Expire(req.Context(), key, window)
				cardCmd := pipe.SCard(req.Context(), key)
				if _, err := pipe.Exec(req.Context()); err == nil {
					if addCmd.Val() > 0 && int(cardCmd.Val()) > threshold {
						slog.Default().Warn("ratelimit: probe threshold exceeded",
							"key", key, "distinct", cardCmd.Val(), "threshold", threshold)
					}
				}
			}
			next.ServeHTTP(w, req)
		})
	}
}

// Middleware returns an http middleware that applies the limiter
func (r *RateLimiter) Middleware(keyFn func(*http.Request) string, max int, window time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			key := keyFn(req)
			if key == "" {
				next.ServeHTTP(w, req)
				return
			}
			ok, count, err := r.Allow(req.Context(), LimitConfig{
				Key: key, Max: max, Window: window,
			})
			if err != nil {
				apierr.Internal("rate limiter unavailable").WithCause(err)
				next.ServeHTTP(w, req)
				return
			}
			if !ok {
				w.Header().Set("Retry-After", strconv.Itoa(int(window.Seconds())))
				apierr.Write(w, req, apierr.RateLimited(
					fmt.Sprintf("rate limit exceeded (%d in %s)", count, window),
				).WithDetail(map[string]any{
					"window_seconds": int(window.Seconds()),
					"max":            max,
				}))
				return
			}
			next.ServeHTTP(w, req)
		})
	}
}
