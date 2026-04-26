package config

import (
	"os"
)

type Config struct {
	DatabaseURL  string
	RedisURL     string
	Port         string
	ResendAPIKey string

	// S3 / R2 configs
	S3Endpoint   string
	S3AccessKey  string
	S3SecretKey  string
	S3Bucket     string
	S3Region     string
	UsePathStyle bool
}

func Load() *Config {
	return &Config{
		DatabaseURL:  getEnv("DATABASE_URL", "postgres://postgres:password@localhost:5432/keepsy?sslmode=disable"),
		RedisURL:     getEnv("REDIS_URL", "localhost:6379"),
		Port:         getEnv("PORT", "8080"),
		ResendAPIKey: getEnv("RESEND_API_KEY", ""),
		S3Endpoint:   getEnv("S3_ENDPOINT", "http://localhost:9000"),
		S3AccessKey:  getEnv("S3_ACCESS_KEY", "minioadmin"),
		S3SecretKey:  getEnv("S3_SECRET_KEY", "minioadmin"),
		S3Bucket:     getEnv("S3_BUCKET", "keepsy"),
		S3Region:     getEnv("S3_REGION", "auto"),
		UsePathStyle: getEnv("USE_PATH_STYLE", "true") == "true",
	}
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
