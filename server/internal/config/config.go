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

	// Master key for the userlink package : derives one HMAC subkey for
	// album_member_identities.user_handle and one AEAD subkey for user_id_enc
	// Same lifetime semantics as EmailHMACKey : rotating it bricks every
	// existing membership row
	UserLinkKey []byte

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
		UserLinkKey:  loadKeyOrDevPlaceholder("KEEPSY_USER_LINK_KEY", "keepsy-dev-userlink-placeholder-do-not-deploy", devMode),
		S3Endpoint:   getEnv("S3_ENDPOINT", "http://localhost:9000"),
		S3AccessKey:  getEnv("S3_ACCESS_KEY", "minioadmin"),
		S3SecretKey:  getEnv("S3_SECRET_KEY", "minioadmin"),
		S3Bucket:     getEnv("S3_BUCKET", "keepsy"),
		S3Region:     getEnv("S3_REGION", "auto"),
		UsePathStyle: getEnv("USE_PATH_STYLE", "true") == "true",
	}
}

func loadEmailHMACKey(devMode bool) []byte {
	return loadKeyOrDevPlaceholder("KEEPSY_EMAIL_HMAC_KEY", "keepsy-dev-email-hmac-placeholder-do-not-deploy", devMode)
}

// loadKeyOrDevPlaceholder reads a base64 32B+ secret from env. In dev mode a
// missing env var falls through to a deterministic SHA256 of devSeed so local
// stacks just work : never deploy to a real environment with APP_ENV=dev
func loadKeyOrDevPlaceholder(envKey, devSeed string, devMode bool) []byte {
	raw := getEnv(envKey, "")
	if raw != "" {
		key, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			log.Fatalf("%s: not valid base64: %v", envKey, err)
		}
		if len(key) < 32 {
			log.Fatalf("%s: must decode to >= 32 bytes, got %d", envKey, len(key))
		}
		return key
	}
	if !devMode {
		log.Fatalf("%s is required in non dev mode", envKey)
	}
	d := sha256.Sum256([]byte(devSeed))
	return d[:]
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
