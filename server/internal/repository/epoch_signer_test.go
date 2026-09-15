package repository_test

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/freytastic/keepsy/internal/e2ee/epoch"
)

// A second admin row only exists in legacy data, but it is the one way a
// signer can be removed while the album keeps an admin to authorize it
func (e *rotationEnv) secondSigner(t *testing.T, role string) []byte {
	t.Helper()
	tok, err := e.repo.AddMember(context.Background(), e.album, e.seedUser(t), role)
	if err != nil {
		t.Fatalf("add %s: %v", role, err)
	}
	return tok
}

func (e *rotationEnv) signedBy(n int, signer []byte, recipients ...[]byte) epoch.InsertEpochInput {
	in := e.epochInput(n, recipients...)
	in.SenderToken = signer
	return in
}

func TestInsertEpoch_RefusesARemovedSigner(t *testing.T) {
	e := newRotationEnv(t)
	signer := e.secondSigner(t, "admin")
	if _, _, err := e.repo.RevokeMemberTx(context.Background(), e.album, e.admin, signer); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	// The remaining set is exact, so only the signer check can refuse this
	err := e.epochs.InsertEpoch(context.Background(), e.signedBy(1, signer, e.admin, e.member))
	if !errors.Is(err, epoch.ErrCallerRevoked) {
		t.Fatalf("got %v, want ErrCallerRevoked", err)
	}
	if !e.required(t) {
		t.Fatal("a refused epoch must leave the rotation owed")
	}
}

func TestInsertEpoch_RefusesACoAdminSigner(t *testing.T) {
	e := newRotationEnv(t)
	signer := e.secondSigner(t, "co-admin")

	err := e.epochs.InsertEpoch(context.Background(), e.signedBy(1, signer, e.admin, e.member, signer))
	if !errors.Is(err, epoch.ErrCallerNotAdmin) {
		t.Fatalf("got %v, want ErrCallerNotAdmin", err)
	}
}

// A removed signer's rotation must never commit, whichever transaction wins
func TestInsertEpoch_RaceWithRemovalNeverKeysTheRemovedSigner(t *testing.T) {
	for i := range 25 {
		e := newRotationEnv(t)
		ctx := context.Background()
		signer := e.secondSigner(t, "admin")

		var rotateErr, revokeErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			rotateErr = e.epochs.InsertEpoch(ctx, e.signedBy(1, signer, e.admin, e.member))
		}()
		go func() {
			defer wg.Done()
			<-start
			_, _, revokeErr = e.repo.RevokeMemberTx(ctx, e.album, e.admin, signer)
		}()
		close(start)
		wg.Wait()

		if revokeErr != nil {
			t.Fatalf("round %d: revoke: %v", i, revokeErr)
		}
		if rotateErr == nil {
			t.Fatalf("round %d: the removed signer minted the next key", i)
		}
		if !errors.Is(rotateErr, epoch.ErrCallerRevoked) && !errors.Is(rotateErr, epoch.ErrMemberSetDrift) {
			t.Fatalf("round %d: got %v, want a revoked signer or member set drift", i, rotateErr)
		}
	}
}
