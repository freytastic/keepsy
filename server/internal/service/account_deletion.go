package service

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log/slog"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
)

const (
	AccountDeletionInterval = time.Minute
	// Bounds one job run if memberships keep reappearing
	maxDeletionPasses = 5
	// Outlasts any realistic time a device stays offline mid deletion
	DeletionReceiptRetention = 180 * 24 * time.Hour
	DeletionReceiptLen       = 32
)

type AccountDeletionStore interface {
	Memberships(ctx context.Context, userID uuid.UUID) ([]repository.DeletionMembership, error)
	Accept(ctx context.Context, userID uuid.UUID, confirmedShared []uuid.UUID, receiptHash []byte) error
	ReceiptAccepted(ctx context.Context, receiptHash []byte) (bool, error)
	AbandonReceipt(ctx context.Context, receiptHash []byte) (bool, error)
	PruneReceipts(ctx context.Context, before time.Time) error
	ClaimDue(ctx context.Context) (uuid.UUID, bool, error)
	RemoveMembership(ctx context.Context, userID, albumID uuid.UUID) (repository.MembershipRemoval, error)
	FinishAccount(ctx context.Context, userID uuid.UUID) (bool, error)
}

type AccountDeletionService struct {
	store    AccountDeletionStore
	cleaner  ObjectCleaner
	notifier Notifier
	wake     chan struct{}
}

// Durable cleanup and later listings cover missing optional collaborators
func NewAccountDeletionService(store AccountDeletionStore, cleaner ObjectCleaner, notifier Notifier) *AccountDeletionService {
	return &AccountDeletionService{
		store:    store,
		cleaner:  cleaner,
		notifier: notifier,
		wake:     make(chan struct{}, 1),
	}
}

type DeletionAlbum struct {
	AlbumID           uuid.UUID
	Role              string
	ActiveMemberCount int
	OwnMediaCount     int
	Outcome           repository.DeletionOutcome
}

func (s *AccountDeletionService) Preflight(ctx context.Context, userID uuid.UUID) ([]DeletionAlbum, error) {
	ms, err := s.store.Memberships(ctx, userID)
	if err != nil {
		return nil, apierr.Internal("failed to read memberships").WithCause(err)
	}
	out := make([]DeletionAlbum, 0, len(ms))
	for _, m := range ms {
		if !m.Active {
			continue
		}
		out = append(out, DeletionAlbum{
			AlbumID:           m.AlbumID,
			Role:              m.Role,
			ActiveMemberCount: m.ActiveMembers,
			OwnMediaCount:     m.OwnMedia,
			Outcome:           m.Outcome(),
		})
	}
	return out, nil
}

// The receipt lets a logged-out device prove acceptance before wiping
func (s *AccountDeletionService) Request(ctx context.Context, userID uuid.UUID, confirmedShared []uuid.UUID, receipt []byte) error {
	if len(receipt) != DeletionReceiptLen {
		return apierr.Validation("receipt must be 32 bytes")
	}
	err := s.store.Accept(ctx, userID, confirmedShared, receiptHash(receipt))
	switch {
	case errors.Is(err, repository.ErrDeletionPlanStale):
		return apierr.DeletionPlanStale("shared albums changed ; review the deletion again")
	case errors.Is(err, repository.ErrReceiptAbandoned):
		return apierr.DeletionAbandoned("this deletion was abandoned ; start a new one")
	case errors.Is(err, repository.ErrUserNotFound):
		return apierr.Auth("account not found")
	case err != nil:
		return apierr.Internal("failed to accept deletion").WithCause(err)
	}
	s.Kick()
	return nil
}

// Acceptance removes every session, so this lookup is unauthenticated
func (s *AccountDeletionService) ReceiptAccepted(ctx context.Context, receipt []byte) (bool, error) {
	if len(receipt) != DeletionReceiptLen {
		return false, apierr.Validation("receipt must be 32 bytes")
	}
	ok, err := s.store.ReceiptAccepted(ctx, receiptHash(receipt))
	if err != nil {
		return false, apierr.Internal("failed to read receipt").WithCause(err)
	}
	return ok, nil
}

// Reports whether acceptance already won and cannot be undone
func (s *AccountDeletionService) AbandonReceipt(ctx context.Context, receipt []byte) (bool, error) {
	if len(receipt) != DeletionReceiptLen {
		return false, apierr.Validation("receipt must be 32 bytes")
	}
	accepted, err := s.store.AbandonReceipt(ctx, receiptHash(receipt))
	if err != nil {
		return false, apierr.Internal("failed to abandon receipt").WithCause(err)
	}
	return accepted, nil
}

func receiptHash(receipt []byte) []byte {
	h := sha256.Sum256(receipt)
	return h[:]
}

func (s *AccountDeletionService) Kick() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *AccountDeletionService) Run(ctx context.Context) {
	ticker := time.NewTicker(AccountDeletionInterval)
	defer ticker.Stop()
	for {
		s.ProcessDue(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-s.wake:
		}
	}
}

func (s *AccountDeletionService) ProcessDue(ctx context.Context) int {
	if err := s.store.PruneReceipts(ctx, time.Now().Add(-DeletionReceiptRetention)); err != nil {
		slog.WarnContext(ctx, "account deletion receipt prune failed", "err", err)
	}
	done := 0
	for ctx.Err() == nil {
		userID, ok, err := s.store.ClaimDue(ctx)
		if err != nil {
			slog.ErrorContext(ctx, "account deletion claim failed", "err", err)
			return done
		}
		if !ok {
			return done
		}
		finished, err := s.process(ctx, userID)
		if err != nil {
			// The lease already pushed the job back, so it retries on its own
			slog.ErrorContext(ctx, "account deletion step failed", "err", err)
			continue
		}
		if finished {
			done++
		}
	}
	return done
}

func (s *AccountDeletionService) process(ctx context.Context, userID uuid.UUID) (bool, error) {
	for range maxDeletionPasses {
		ms, err := s.store.Memberships(ctx, userID)
		if err != nil {
			return false, err
		}
		for _, m := range ms {
			removed, err := s.store.RemoveMembership(ctx, userID, m.AlbumID)
			if err != nil {
				return false, err
			}
			s.afterRemoval(ctx, removed)
		}
		finished, err := s.store.FinishAccount(ctx, userID)
		if err != nil || finished {
			return finished, err
		}
	}
	return false, nil
}

// afterRemoval runs once the step committed. Lost notifications only delay
// clients until their next authoritative sync
func (s *AccountDeletionService) afterRemoval(ctx context.Context, r repository.MembershipRemoval) {
	if s.cleaner != nil {
		s.cleaner.CleanupObjectKeys(ctx, r.Keys)
	}
	if s.notifier == nil || len(r.NotifyUserIDs) == 0 {
		return
	}
	album := r.AlbumID.String()
	emit := func(typ string, payload map[string]any) {
		if err := s.notifier.EmitToUsers(ctx, r.NotifyUserIDs, typ, payload); err != nil {
			slog.WarnContext(ctx, "account deletion emit failed", "type", typ, "err", err)
		}
	}
	switch r.Outcome {
	case repository.OutcomeDeleteAlbum, repository.OutcomeDeleteShared:
		emit(ws.EventAlbumDeleted, map[string]any{"album_id": album})
		return
	case repository.OutcomeLeave:
		emit(ws.EventMemberRevoked, map[string]any{
			"album_id":     album,
			"member_token": base64.StdEncoding.EncodeToString(r.MemberToken),
		})
	}
	if len(r.MediaIDs) > 0 {
		ids := make([]string, len(r.MediaIDs))
		for i, id := range r.MediaIDs {
			ids[i] = id.String()
		}
		emit(ws.EventMediaDeleted, map[string]any{"album_id": album, "media_ids": ids})
	}
}
