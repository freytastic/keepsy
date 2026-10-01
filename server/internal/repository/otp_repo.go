package repository

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// Keys and values are HMACs computed by the auth service : Redis never holds
// an email address or a usable code
type OTPRepository struct {
	Redis *redis.Client
}

func NewOTPRepository(rdb *redis.Client) *OTPRepository {
	return &OTPRepository{Redis: rdb}
}

// SetOTP replaces any earlier code and its failed attempt count
func (r *OTPRepository) SetOTP(ctx context.Context, key, codeMAC string, ttl time.Duration) error {
	pipe := r.Redis.TxPipeline()
	pipe.Set(ctx, "otp:"+key, codeMAC, ttl)
	pipe.Del(ctx, "otp-attempts:"+key)
	_, err := pipe.Exec(ctx)
	return err
}

// One script so parallel guesses cannot all read the code before any attempt
// is counted. A match consumes the code, the last allowed miss burns it
var checkOTPScript = redis.NewScript(`
local stored = redis.call('GET', KEYS[1])
if not stored then return 0 end
if stored == ARGV[1] then
  redis.call('DEL', KEYS[1], KEYS[2])
  return 1
end
local n = redis.call('INCR', KEYS[2])
if n == 1 then redis.call('PEXPIRE', KEYS[2], redis.call('PTTL', KEYS[1])) end
if n >= tonumber(ARGV[2]) then redis.call('DEL', KEYS[1], KEYS[2]) end
return 0
`)

// CheckOTP reports whether codeMAC matches the stored code
func (r *OTPRepository) CheckOTP(ctx context.Context, key, codeMAC string, maxAttempts int) (bool, error) {
	n, err := checkOTPScript.Run(ctx, r.Redis,
		[]string{"otp:" + key, "otp-attempts:" + key}, codeMAC, maxAttempts).Int()
	return n == 1, err
}

// The count and its expiry are set together so a counter can never outlive
// its window
var rateLimitScript = redis.NewScript(`
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end
return n
`)

// CheckRateLimit allows max requests per window
func (r *OTPRepository) CheckRateLimit(ctx context.Context, key string, max int, window time.Duration) (bool, error) {
	n, err := rateLimitScript.Run(ctx, r.Redis,
		[]string{"ratelimit:" + key}, window.Milliseconds()).Int()
	if err != nil {
		return false, err
	}
	return n <= max, nil
}
