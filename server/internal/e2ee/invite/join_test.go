package invite

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/google/uuid"
)

func TestJoinComplete_VerifiesSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	albumID := uuid.New()
	const epoch = 3
	ekAdmin := make([]byte, 32)
	ekAdmin[0] = 0x09

	marked := -999
	store := &mockStore{
		ikFn:   func(_ context.Context, _ []byte) ([]byte, error) { return pub, nil },
		markFn: func(_ context.Context, _ []byte, e int) error { marked = e; return nil },
	}
	svc := NewService(store)
	callerToken := make([]byte, 32)

	good := ed25519.Sign(priv, JoinCompleteMsg(albumID, epoch, ekAdmin))
	if err := svc.JoinComplete(context.Background(), albumID, callerToken,
		JoinCompleteInput{Epoch: epoch, EKPubAdmin: ekAdmin, Sig: good}); err != nil {
		t.Fatalf("happy path: %v", err)
	}
	if marked != epoch {
		t.Fatalf("MarkReceived epoch = %d, want %d", marked, epoch)
	}

	_, wrongPriv, _ := ed25519.GenerateKey(rand.Reader)
	otherEk := make([]byte, 32)
	otherEk[0] = 0x07
	forgeries := map[string][]byte{
		"wrong signing key":  ed25519.Sign(wrongPriv, JoinCompleteMsg(albumID, epoch, ekAdmin)),
		"wrong epoch in sig": ed25519.Sign(priv, JoinCompleteMsg(albumID, epoch+1, ekAdmin)),
		"wrong ek_pub_admin": ed25519.Sign(priv, JoinCompleteMsg(albumID, epoch, otherEk)),
		"wrong album_id":     ed25519.Sign(priv, JoinCompleteMsg(uuid.New(), epoch, ekAdmin)),
	}
	for name, sig := range forgeries {
		t.Run(name, func(t *testing.T) {
			err := svc.JoinComplete(context.Background(), albumID, callerToken,
				JoinCompleteInput{Epoch: epoch, EKPubAdmin: ekAdmin, Sig: sig})
			if !apierr.IsCode(err, "E_SIG_INVALID") {
				t.Fatalf("err = %v, want E_SIG_INVALID", err)
			}
		})
	}
}
