package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"github.com/freytastic/keepsy/internal/config"
	"github.com/freytastic/keepsy/internal/handler"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

func main() {
	cfg := config.Load()

	// connect to postgres
	dbPool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Unable to connect to database: %v\n", err)
	}
	defer dbPool.Close()

	// run migrations which are being stored in the docker volume for now
	m, err := migrate.New(
		"file://migrations",
		cfg.DatabaseURL,
	)
	if err != nil {
		log.Printf("Migration failed to initialize: %v", err)
	} else {
		if err := m.Up(); err != nil && err != migrate.ErrNoChange {
			log.Printf("Migration failed: %v", err)
		} else {
			log.Println("Migrations applied successfully!")
		}
	}

	// connect to redis
	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisURL,
	})
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("Unable to connect to redis: %v\n", err)
	}
	defer rdb.Close()

	// initialize repos
	otpRepo := repository.NewOTPRepository(rdb)
	userRepo := repository.NewUserRepository(dbPool)
	sessionRepo := repository.NewSessionRepository(dbPool)

	// initialize services
	emailService := service.NewResendEmailService(cfg.ResendAPIKey)
	authService := service.NewAuthService(otpRepo, userRepo, sessionRepo, emailService)

	//initialize handlers
	authHandler := handler.NewAuthHandler(authService)

	r := mux.NewRouter()

	apiV1 := r.PathPrefix("/api/v1").Subrouter()
	apiV1.HandleFunc("/auth/otp/request", authHandler.RequestOTP).Methods(http.MethodPost)
	apiV1.HandleFunc("/auth/otp/verify", authHandler.VerifyOTP).Methods(http.MethodPost)

	r.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "OK")
	}).Methods(http.MethodGet)

	fmt.Printf("Server starting on port %s\n", cfg.Port)
	log.Fatal(http.ListenAndServe(":"+cfg.Port, r))
}
