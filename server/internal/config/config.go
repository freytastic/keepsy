package config

import (
	"crypto/sha256"
	"encoding/base64"
	"log"
	"os"
)

type Config struct {
	DatabaseURL  string
	RedisURL     string
	Port         string
	ResendAPIKey string
	DevMode      bool // enables /test/* endpoints: never true in production

	// HMAC key for users.email_hmac. Stable across the deployment lifetime :
	// rotating it orphans every existing account, so treat as a primary
	// cryptographic secret. Required in non dev mode (panic at Load) : dev
	// derives a deterministic placeholder so local stacks just work
	EmailHMACKey []byte

	// S3 / R2 configs
	S3Endpoint   string
	S3AccessKey  string
	S3SecretKey  string
	S3Bucket     string
	S3Region     string
	UsePathStyle bool
}

func Load() *Config {
	devMode := getEnv("APP_ENV", "") == "dev"
	return &Config{
		DatabaseURL:  getEnv("DATABASE_URL", "postgres://postgres:password@localhost:5432/keepsy?sslmode=disable"),
		RedisURL:     getEnv("REDIS_URL", "localhost:6379"),
		Port:         getEnv("PORT", "8080"),
		ResendAPIKey: getEnv("RESEND_API_KEY", ""),
		DevMode:      devMode,
		EmailHMACKey: loadEmailHMACKey(devMode),
		S3Endpoint:   getEnv("S3_ENDPOINT", "http://localhost:9000"),
		S3AccessKey:  getEnv("S3_ACCESS_KEY", "minioadmin"),
		S3SecretKey:  getEnv("S3_SECRET_KEY", "minioadmin"),
		S3Bucket:     getEnv("S3_BUCKET", "keepsy"),
		S3Region:     getEnv("S3_REGION", "auto"),
		UsePathStyle: getEnv("USE_PATH_STYLE", "true") == "true",
	}
}

func loadEmailHMACKey(devMode bool) []byte {
	raw := getEnv("KEEPSY_EMAIL_HMAC_KEY", "")
	if raw != "" {
		key, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			log.Fatalf("KEEPSY_EMAIL_HMAC_KEY: not valid base64: %v", err)
		}
		if len(key) < 32 {
			log.Fatalf("KEEPSY_EMAIL_HMAC_KEY: must decode to >= 32 bytes, got %d", len(key))
		}
		return key
	}
	if !devMode {
		log.Fatal("KEEPSY_EMAIL_HMAC_KEY is required in non dev mode")
	}
	// Deterministic dev placeholder so 'docker compose up' works without
	// extra setup. Anything signed with this key is trivially forgeable :
	// never deploy with APP_ENV=dev to a real environment
	d := sha256.Sum256([]byte("keepsy-dev-email-hmac-placeholder-do-not-deploy"))
	return d[:]
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
