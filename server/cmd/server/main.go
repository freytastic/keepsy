package main

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/config"
	"github.com/freytastic/keepsy/internal/e2ee/epoch"
	"github.com/freytastic/keepsy/internal/e2ee/prekey"
	"github.com/freytastic/keepsy/internal/handler"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg := config.Load()

	dbPool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Unable to connect to database: %v\n", err)
	}
	defer dbPool.Close()

	m, err := migrate.New("file://migrations", cfg.DatabaseURL)
	if err != nil {
		log.Printf("Migration failed to initialize: %v", err)
	} else if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		log.Printf("Migration failed: %v", err)
	} else {
		log.Println("Migrations applied successfully!")
	}

	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisURL})
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("Unable to connect to redis: %v\n", err)
	}
	defer rdb.Close()

	otpRepo := repository.NewOTPRepository(rdb)
	userRepo := repository.NewUserRepository(dbPool)
	prekeyRepo := repository.NewPrekeyRepository(dbPool)
	sessionRepo := repository.NewSessionRepository(dbPool)
	albumRepo := repository.NewAlbumRepository(dbPool)

	emailService := service.NewResendEmailService(cfg.ResendAPIKey)
	authService := service.NewAuthService(otpRepo, userRepo, sessionRepo, emailService)
	userService := service.NewUserService(userRepo)
	albumService := service.NewAlbumService(albumRepo)

	hub := ws.NewHub()
	ticketStore := ws.NewTicketStore(rdb)

	prekeyEx := prekey.NewRepo(dbPool, prekeyRepo)
	prekeyService := prekey.NewService(prekeyEx)
	prekeyHandler := prekey.NewHandler(prekeyService, hub)

	epochRepo := epoch.NewRepo(dbPool)
	epochService := epoch.NewService(epochRepo)
	epochHandler := epoch.NewHandler(epochService, epochRepo, hub)

	rateLimiter := middleware.NewRateLimiter(rdb)

	authHandler := handler.NewAuthHandler(authService)
	userHandler := handler.NewUserHandler(userService)
	albumHandler := handler.NewAlbumHandler(albumService)
	mediaHandler := handler.NewMediaHandler()
	inviteHandler := handler.NewInviteHandler()
	wsHandler := handler.NewWSHandler(hub, ticketStore)

	authMiddleware := middleware.NewAuthMiddleware(sessionRepo)
	requireMember := middleware.RequireMember(albumRepo, "id")

	r := mux.NewRouter()

	apiV1 := r.PathPrefix("/api/v1").Subrouter()
	apiV1.HandleFunc("/auth/otp/request", authHandler.RequestOTP).Methods(http.MethodPost)
	apiV1.HandleFunc("/auth/otp/verify", authHandler.VerifyOTP).Methods(http.MethodPost)
	apiV1.HandleFunc("/auth/otp/refresh", authHandler.Refresh).Methods(http.MethodPost)
	apiV1.HandleFunc("/invite/{code}", inviteHandler.GetPreview).Methods(http.MethodGet)

	// WS endpoint authenticates via ticket, not bearer , must be outside authed subrouter
	apiV1.HandleFunc("/ws", wsHandler.ServeWS).Methods(http.MethodGet)

	authed := apiV1.PathPrefix("").Subrouter()
	authed.Use(authMiddleware.Authenticate)

	authed.HandleFunc("/ws-ticket", wsHandler.IssueTicket).Methods(http.MethodPost)
	authed.HandleFunc("/users/me", userHandler.GetMe).Methods(http.MethodGet)
	authed.HandleFunc("/users/me", userHandler.UpdateMe).Methods(http.MethodPatch)
	authed.HandleFunc("/users/me/keys", prekeyHandler.UpsertIdentity).Methods(http.MethodPut)
	authed.HandleFunc("/users/me/spk", prekeyHandler.RotateSPK).Methods(http.MethodPost)
	authed.HandleFunc("/users/me/opks", prekeyHandler.ReplenishOPKs).Methods(http.MethodPost)
	authed.HandleFunc("/users/me/opks/count", prekeyHandler.GetOPKCount).Methods(http.MethodGet)
	// peer bundle fetch is rate limited per requesting user : key is the user_id
	// extracted from auth ctx, so we register the wrapper after auth middleware
	authed.Handle(
		"/users/{id}/prekey-bundle",
		rateLimiter.Middleware(prekey.KeyByUserID, 5, 60*time.Second)(http.HandlerFunc(prekeyHandler.GetPrekeyBundle)),
	).Methods(http.MethodGet)

	authed.HandleFunc("/albums", albumHandler.CreateAlbum).Methods(http.MethodPost)
	authed.HandleFunc("/albums", albumHandler.ListAlbums).Methods(http.MethodGet)
	authed.HandleFunc("/invite/{code}/join", inviteHandler.JoinAlbum).Methods(http.MethodPost)

	scoped := authed.PathPrefix("/albums/{id}").Subrouter()
	scoped.Use(requireMember)
	scoped.HandleFunc("", albumHandler.GetAlbum).Methods(http.MethodGet)
	scoped.HandleFunc("", albumHandler.UpdateAlbum).Methods(http.MethodPatch)
	scoped.HandleFunc("", albumHandler.DeleteAlbum).Methods(http.MethodDelete)
	scoped.HandleFunc("/members", albumHandler.ListAlbumMembers).Methods(http.MethodGet)
	scoped.HandleFunc("/members", albumHandler.AddMember).Methods(http.MethodPost)
	scoped.HandleFunc("/members/{token}", albumHandler.RemoveAlbumMember).Methods(http.MethodDelete)
	scoped.HandleFunc("/invite", inviteHandler.CreateInvite).Methods(http.MethodPost)
	scoped.HandleFunc("/invite-blob", inviteHandler.CreateInviteBlob).Methods(http.MethodPost)
	scoped.HandleFunc("/invite-blob", inviteHandler.GetInviteBlob).Methods(http.MethodGet)
	scoped.HandleFunc("/media/upload-url", mediaHandler.RequestUploadURL).Methods(http.MethodPost)
	scoped.HandleFunc("/media/confirm", mediaHandler.ConfirmUpload).Methods(http.MethodPost)
	scoped.HandleFunc("/media", mediaHandler.ListMedia).Methods(http.MethodGet)
	scoped.HandleFunc("/media/{mid}", mediaHandler.DeleteMedia).Methods(http.MethodDelete)
	scoped.HandleFunc("/epoch", epochHandler.SetEpoch).Methods(http.MethodPost)
	scoped.HandleFunc("/epoch", epochHandler.GetCurrent).Methods(http.MethodGet)
	scoped.HandleFunc("/epoch/{n}/wrap", epochHandler.GetWrap).Methods(http.MethodGet)

	r.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "OK")
	}).Methods(http.MethodGet)

	if cfg.DevMode {
		r.HandleFunc("/test/emit-event", wsHandler.TestEmitEvent).Methods(http.MethodPost)
	}

	r.NotFoundHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apierr.Write(w, r, apierr.NotFound("route not found"))
	})
	r.MethodNotAllowedHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apierr.Write(w, r, &apierr.APIError{
			Code: "E_METHOD_NOT_ALLOWED", HTTPStatus: http.StatusMethodNotAllowed, Message: "method not allowed",
		})
	})

	rootHandler := middleware.Recover(middleware.RequestID(middleware.CORS(r)))

	srv := &http.Server{
		Addr:           ":" + cfg.Port,
		Handler:        rootHandler,
		ReadTimeout:    5 * time.Second,
		WriteTimeout:   10 * time.Second,
		IdleTimeout:    120 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}

	serverErrors := make(chan error, 1)
	go func() {
		fmt.Printf("Server starting on port %s\n", cfg.Port)
		serverErrors <- srv.ListenAndServe()
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-serverErrors:
		log.Fatalf("Error starting server: %v", err)
	case sig := <-shutdown:
		fmt.Printf("Start shutdown... Signal: %v\n", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("Shutdown failed: %v. Forcing close.", err)
			srv.Close()
		}
		fmt.Println("Server stopped.")
	}
}
