package config

import (
	"os"
)

type Config struct {
	DatabaseURL  string
	RedisURL     string
	Port         string
	ResendAPIKey string
}

func Load() *Config {
	return &Config{
		DatabaseURL:  getEnv("DATABASE_URL", "postgres://postgres:password@localhost:5432/keepsy?sslmode=disable"),
		RedisURL:     getEnv("REDIS_URL", "localhost:6379"),
		Port:         getEnv("PORT", "8080"),
		ResendAPIKey: getEnv("RESEND_API_KEY", ""),
	}
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
