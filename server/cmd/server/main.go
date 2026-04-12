package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"github.com/freytastic/keepsy/internal/config"
	"github.com/freytastic/keepsy/internal/handler"
	"github.com/freytastic/keepsy/internal/middleware"
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
	albumRepo := repository.NewAlbumRepository(dbPool)

	// initialize services
	emailService := service.NewResendEmailService(cfg.ResendAPIKey)
	authService := service.NewAuthService(otpRepo, userRepo, sessionRepo, emailService)
	userService := service.NewUserService(userRepo)
	albumService := service.NewAlbumService(albumRepo)

	//initialize handlers
	authHandler := handler.NewAuthHandler(authService)
	userHandler := handler.NewUserHandler(userService)
	albumHandler := handler.NewAlbumHandler(albumService)

	// initialize middleware
	authMiddleware := middleware.NewAuthMiddleware(sessionRepo)

	r := mux.NewRouter()

	apiV1 := r.PathPrefix("/api/v1").Subrouter()
	apiV1.HandleFunc("/auth/otp/request", authHandler.RequestOTP).Methods(http.MethodPost)
	apiV1.HandleFunc("/auth/otp/verify", authHandler.VerifyOTP).Methods(http.MethodPost)

	// authenticated routes
	authenticated := apiV1.PathPrefix("").Subrouter()
	authenticated.Use(authMiddleware.Authenticate)

	authenticated.HandleFunc("/users/me", userHandler.GetMe).Methods(http.MethodGet)
	authenticated.HandleFunc("/users/me", userHandler.UpdateMe).Methods(http.MethodPatch)

	// album routes
	authenticated.HandleFunc("/albums", albumHandler.CreateAlbum).Methods(http.MethodPost)
	authenticated.HandleFunc("/albums", albumHandler.ListAlbums).Methods(http.MethodGet)
	authenticated.HandleFunc("/albums/{id}", albumHandler.GetAlbum).Methods(http.MethodGet)
	authenticated.HandleFunc("/albums/{id}", albumHandler.UpdateAlbum).Methods(http.MethodPatch)
	authenticated.HandleFunc("/albums/{id}", albumHandler.DeleteAlbum).Methods(http.MethodDelete)
	authenticated.HandleFunc("/albums/{id}/members", albumHandler.AddMember).Methods(http.MethodPost)

	r.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "OK")
	}).Methods(http.MethodGet)

	fmt.Printf("Server starting on port %s\n", cfg.Port)
	log.Fatal(http.ListenAndServe(":"+cfg.Port, r))
}
