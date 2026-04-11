package repository

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

type OTPRepository struct {
	Redis *redis.Client
}

func NewOTPRepository(rdb *redis.Client) *OTPRepository {
	return &OTPRepository{Redis: rdb}
}

func (r *OTPRepository) SetOTP(ctx context.Context, email, otp string, ttl time.Duration) error {
	return r.Redis.Set(ctx, "otp:"+email, otp, ttl).Err()
}

func (r *OTPRepository) GetOTP(ctx context.Context, email string) (string, error) {
	return r.Redis.Get(ctx, "otp:"+email).Result()
}

func (r *OTPRepository) CheckRateLimit(ctx context.Context, email string) (bool, error) {
	key := "ratelimit:" + email
	count, err := r.Redis.Get(ctx, key).Int()
	if err == redis.Nil {
		// first request, set count to 1 and TTL to 5 mins
		err = r.Redis.Set(ctx, key, 1, 5*time.Minute).Err()
		return true, err
	}
	if err != nil {
		return false, err
	}

	if count >= 3 {
		return false, nil // limit reached
	}

	// increment count
	err = r.Redis.Incr(ctx, key).Err()
	return true, err
}
