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
	"github.com/freytastic/keepsy/internal/e2ee/invite"
	"github.com/freytastic/keepsy/internal/e2ee/prekey"
	"github.com/freytastic/keepsy/internal/handler"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/freytastic/keepsy/internal/storage"
	"github.com/freytastic/keepsy/internal/userlink"
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

	linker, err := userlink.New(cfg.UserLinkKey)
	if err != nil {
		log.Fatalf("userlink init: %v", err)
	}

	otpRepo := repository.NewOTPRepository(rdb)
	userRepo := repository.NewUserRepository(dbPool)
	prekeyRepo := repository.NewPrekeyRepository(dbPool)
	sessionRepo := repository.NewSessionRepository(dbPool)
	albumRepo := repository.NewAlbumRepository(dbPool, linker)
	mediaRepo := repository.NewMediaRepository(dbPool)

	s3Client, err := storage.NewS3Client(cfg.S3Endpoint, cfg.S3PublicEndpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket, cfg.S3Region, cfg.UsePathStyle)
	if err != nil {
		log.Fatalf("s3 init: %v", err)
	}
	if err := s3Client.CreateBucketIfNotExists(context.Background()); err != nil {
		log.Printf("s3 bucket bootstrap: %v", err) // non fatal : bucket may exist + creds may have only object level perms
	}

	emailService := service.NewResendEmailService(cfg.ResendAPIKey)
	authService := service.NewAuthService(otpRepo, userRepo, sessionRepo, emailService, cfg.EmailHMACKey)
	userService := service.NewUserService(userRepo)
	albumService := service.NewAlbumService(albumRepo)

	hub := ws.NewHub()
	ticketStore := ws.NewTicketStore(rdb)

	epochRepo := epoch.NewRepo(dbPool, linker)
	epochService := epoch.NewService(epochRepo)
	epochHandler := epoch.NewHandler(epochService, epochRepo, hub)

	prekeyEx := prekey.NewRepo(dbPool, prekeyRepo)
	prekeyService := prekey.NewService(prekeyEx)
	// epochRepo doubles as the album member_token -> user_id resolver for the
	// by nickname bundle fetch (M bridge unseal, album scoped)
	prekeyHandler := prekey.NewHandler(prekeyService, hub, userRepo, epochRepo)

	inviteRepo := invite.NewRepo(dbPool, linker, userRepo)
	inviteService := invite.NewService(inviteRepo)
	memberInviteHandler := invite.NewHandler(inviteService, inviteRepo, hub)

	mediaService := service.NewMediaService(mediaRepo, epochRepo, &s3Adapter{s3Client}, hub, inviteRepo)
	// album deletion purges the album's S3 objects (media rows cascade in the DB
	// but the blobs don't) before dropping the row
	albumService.SetObjectPurger(mediaService)

	rateLimiter := middleware.NewRateLimiter(rdb)

	authHandler := handler.NewAuthHandler(authService)
	userHandler := handler.NewUserHandler(userService)
	albumHandler := handler.NewAlbumHandler(albumService, hub, epochRepo)
	mediaHandler := handler.NewMediaHandler(mediaService)
	inviteHandler := handler.NewInviteHandler()
	wsHandler := handler.NewWSHandler(hub, ticketStore)

	authMiddleware := middleware.NewAuthMiddleware(sessionRepo)
	requireMember := middleware.RequireMember(albumRepo, "id")

	r := mux.NewRouter()
	// Router middleware can read the matched route template
	r.Use(middleware.AccessLog)

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
	authed.HandleFunc("/users/me/keys", prekeyHandler.UpsertIdentity).Methods(http.MethodPut)
	// Side-effect-free self key state for publication reconciliation
	authed.HandleFunc("/users/me/keys", prekeyHandler.GetOwnKeys).Methods(http.MethodGet)
	authed.HandleFunc("/users/me/spk", prekeyHandler.RotateSPK).Methods(http.MethodPost)
	authed.HandleFunc("/users/me/opks", prekeyHandler.ReplenishOPKs).Methods(http.MethodPost)
	authed.HandleFunc("/users/me/opks/count", prekeyHandler.GetOPKCount).Methods(http.MethodGet)
	// peer bundle fetch : per (requester, target) rate limit (5/min/pair)
	// chained with a per requester distinct probe tracker (warn at >20 distinct
	// targets/hr). The pair limit makes legitimate retries cheap : the probe
	// tracker catches enumeration that hides under the pair limit
	authed.Handle(
		"/users/{id}/prekey-bundle",
		rateLimiter.Middleware(prekey.KeyByRequesterAndTarget, 5, 60*time.Second)(
			rateLimiter.ProbeDistinctMiddleware(prekey.KeyByRequesterTargetHourly, 20, time.Hour)(
				http.HandlerFunc(prekeyHandler.GetPrekeyBundle),
			),
		),
	).Methods(http.MethodGet)
	// resolve a random keepsy_id to a prekey bundle. Same
	// per-(requester, handle) 5/min limit : the real user_id never leaves here
	authed.Handle(
		"/users/by-handle/{handle}/prekey-bundle",
		rateLimiter.Middleware(prekey.KeyByRequesterAndHandle, 5, 60*time.Second)(
			http.HandlerFunc(prekeyHandler.GetPrekeyBundleByHandle),
		),
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
	// Member onboarding goes through the E2EE invite path only
	// (POST /invites/existing-user). The legacy direct add-member route was
	// removed: it inserted DB membership without X3DH MK delivery, leaving a
	// "member without keys" state and bypassing the crypto envelope.
	scoped.HandleFunc("/members/me/profile-ct", albumHandler.UpdateMyProfileCT).Methods(http.MethodPut)
	scoped.HandleFunc("/members/{token}", albumHandler.RemoveAlbumMember).Methods(http.MethodDelete)
	// by nickname prekey bundle: an admin rotating an album fetches remaining
	// members' bundles by member_token (identity hidden). Same per pair 5/min
	// limit as the by id route, keyed on (requester, album, token)
	scoped.Handle(
		"/members/{token}/prekey-bundle",
		rateLimiter.Middleware(prekey.KeyByRequesterAndMemberToken, 5, 60*time.Second)(
			http.HandlerFunc(prekeyHandler.GetPrekeyBundleByMemberToken),
		),
	).Methods(http.MethodGet)
	scoped.HandleFunc("/invites/existing-user", memberInviteHandler.DeliverExistingUser).Methods(http.MethodPost)
	scoped.HandleFunc("/joins", memberInviteHandler.JoinComplete).Methods(http.MethodPost)
	scoped.HandleFunc("/invite", inviteHandler.CreateInvite).Methods(http.MethodPost)
	scoped.HandleFunc("/invite-blob", inviteHandler.CreateInviteBlob).Methods(http.MethodPost)
	scoped.HandleFunc("/invite-blob", inviteHandler.GetInviteBlob).Methods(http.MethodGet)
	scoped.HandleFunc("/media/upload-url", mediaHandler.RequestUploadURL).Methods(http.MethodPost)
	scoped.HandleFunc("/media/confirm", mediaHandler.ConfirmUpload).Methods(http.MethodPost)
	scoped.HandleFunc("/media", mediaHandler.ListMedia).Methods(http.MethodGet)
	scoped.HandleFunc("/media/{mid}/download-url", mediaHandler.RequestDownloadURL).Methods(http.MethodPost)
	scoped.HandleFunc("/media/{mid}/pending", mediaHandler.AbortPendingUpload).Methods(http.MethodDelete)
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

	// RequestID must wrap Recover so panic logs retain the generated ID
	rootHandler := middleware.RequestID(middleware.Recover(middleware.CORS(r)))

	srv := &http.Server{
		Addr:           ":" + cfg.Port,
		Handler:        rootHandler,
		ReadTimeout:    5 * time.Second,
		WriteTimeout:   10 * time.Second,
		IdleTimeout:    120 * time.Second,
		MaxHeaderBytes: 1 << 20,
	}
	cleanupCtx, stopPendingCleanup := context.WithCancel(context.Background())
	pendingCleanupDone := make(chan struct{})
	go func() {
		defer close(pendingCleanupDone)
		mediaService.RunPendingUploadCleanup(cleanupCtx)
	}()

	serverErrors := make(chan error, 1)
	go func() {
		fmt.Printf("Server starting on port %s\n", cfg.Port)
		serverErrors <- srv.ListenAndServe()
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-serverErrors:
		stopPendingCleanup()
		log.Fatalf("Error starting server: %v", err)
	case sig := <-shutdown:
		fmt.Printf("Start shutdown... Signal: %v\n", sig)
		stopPendingCleanup()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("Shutdown failed: %v. Forcing close.", err)
			srv.Close()
		}
		// Cleanup gets a fresh budget if HTTP shutdown consumed its deadline
		drainCtx, cancelDrain := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelDrain()
		select {
		case <-pendingCleanupDone:
		case <-drainCtx.Done():
			log.Printf("Pending media cleanup did not stop before shutdown deadline")
		}
		fmt.Println("Server stopped.")
	}
}

// s3Adapter bridges *storage.S3Client to service.ObjectStore. The service has
// its own PresignedUpload type so handler tests can mock without importing
// internal/storage
type s3Adapter struct{ c *storage.S3Client }

func (a *s3Adapter) GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*service.PresignedUpload, error) {
	pre, err := a.c.GetPresignedUploadURLWithChecksum(ctx, key, contentType, contentLength, sha256B64, expires)
	if err != nil {
		return nil, err
	}
	return &service.PresignedUpload{URL: pre.URL, RequiredHeader: pre.RequiredHeader}, nil
}

func (a *s3Adapter) HeadObject(ctx context.Context, key string) (int64, string, error) {
	return a.c.HeadObject(ctx, key)
}

func (a *s3Adapter) GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error) {
	return a.c.GetPresignedDownloadURL(ctx, key, expires)
}

func (a *s3Adapter) DeleteObject(ctx context.Context, key string) error {
	return a.c.DeleteObject(ctx, key)
}
