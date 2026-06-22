package invite

import (
	"context"
	"testing"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

type mockStore struct {
	findFn    func(ctx context.Context, keepsyID string) (uuid.UUID, error)
	currentFn func(ctx context.Context, albumID uuid.UUID) (int, error)
	deliverFn func(ctx context.Context, in DeliverMemberInput) ([]byte, error)
	ikFn      func(ctx context.Context, memberToken []byte) ([]byte, error)
	markFn    func(ctx context.Context, memberToken []byte, epoch int) error
}

func (m *mockStore) FindUserIDByKeepsyID(ctx context.Context, k string) (uuid.UUID, error) {
	return m.findFn(ctx, k)
}
func (m *mockStore) CurrentEpoch(ctx context.Context, a uuid.UUID) (int, error) {
	return m.currentFn(ctx, a)
}
func (m *mockStore) DeliverMember(ctx context.Context, in DeliverMemberInput) ([]byte, error) {
	return m.deliverFn(ctx, in)
}
func (m *mockStore) IKByMemberToken(ctx context.Context, t []byte) ([]byte, error) {
	return m.ikFn(ctx, t)
}
func (m *mockStore) MarkReceived(ctx context.Context, t []byte, epoch int) error {
	return m.markFn(ctx, t, epoch)
}

func envs(epochs ...int) []Envelope {
	out := make([]Envelope, len(epochs))
	for i, e := range epochs {
		out[i] = Envelope{
			Epoch:     e,
			WrapNonce: make([]byte, wrapNonceLen),
			WrapTagCT: make([]byte, wrapTagCTLen),
			SenderSig: make([]byte, sigLen),
		}
	}
	return out
}

func baseInput() DeliverExistingUserInput {
	idx := 3
	return DeliverExistingUserInput{
		TargetKeepsyID: "k7f2-9qxm",
		EKPub:          make([]byte, pubLen),
		OPKIdxUsed:     &idx,
		Envelopes:      envs(0, 1, 2),
	}
}

func newAlbumStore(current int, deliver func(ctx context.Context, in DeliverMemberInput) ([]byte, error)) *mockStore {
	return &mockStore{
		findFn:    func(_ context.Context, _ string) (uuid.UUID, error) { return uuid.New(), nil },
		currentFn: func(_ context.Context, _ uuid.UUID) (int, error) { return current, nil },
		deliverFn: deliver,
	}
}

func TestDeliverExistingUser_HappyPath(t *testing.T) {
	want := []byte("the-new-member-token-32-bytes!!!")
	var captured DeliverMemberInput
	store := newAlbumStore(2, func(_ context.Context, in DeliverMemberInput) ([]byte, error) {
		captured = in
		return want, nil
	})
	svc := NewService(store)

	callerToken := make([]byte, 32)
	token, gotUserID, err := svc.DeliverExistingUser(context.Background(), uuid.New(), callerToken, "admin", baseInput())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if string(token) != string(want) {
		t.Fatalf("token = %x, want %x", token, want)
	}
	if gotUserID == uuid.Nil || gotUserID != captured.UserID {
		t.Fatalf("returned userID %v, want delivered %v (non-nil)", gotUserID, captured.UserID)
	}
	if len(captured.Envelopes) != 3 {
		t.Fatalf("delivered %d envelopes, want 3", len(captured.Envelopes))
	}
	for i, e := range captured.Envelopes {
		if e.Epoch != i {
			t.Fatalf("envelope[%d].Epoch = %d, want %d (must be sorted contiguous)", i, e.Epoch, i)
		}
	}
	if captured.OPKIdxUsed == nil || *captured.OPKIdxUsed != 3 {
		t.Fatalf("OPKIdxUsed = %v, want 3", captured.OPKIdxUsed)
	}
	if string(captured.SenderToken) != string(callerToken) {
		t.Fatal("SenderToken not propagated")
	}
}

func TestDeliverExistingUser_SortsEnvelopes(t *testing.T) {
	var captured DeliverMemberInput
	store := newAlbumStore(2, func(_ context.Context, in DeliverMemberInput) ([]byte, error) {
		captured = in
		return []byte("tok"), nil
	})
	svc := NewService(store)
	in := baseInput()
	in.Envelopes = envs(2, 0, 1) // out of order
	if _, _, err := svc.DeliverExistingUser(context.Background(), uuid.New(), nil, "admin", in); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	for i, e := range captured.Envelopes {
		if e.Epoch != i {
			t.Fatalf("envelope[%d].Epoch = %d, want %d", i, e.Epoch, i)
		}
	}
}

func TestDeliverExistingUser_Validation(t *testing.T) {
	mustNotDeliver := func(_ context.Context, _ DeliverMemberInput) ([]byte, error) {
		t.Fatal("DeliverMember must not be called when validation fails")
		return nil, nil
	}
	cases := []struct {
		name     string
		role     string
		current  int
		mutate   func(*DeliverExistingUserInput)
		findErr  error
		wantCode string
	}{
		{"non-admin", "member", 2, nil, nil, "E_FORBIDDEN"},
		{"unknown handle", "admin", 2, nil, repository.ErrUserNotFound, "E_NOT_FOUND"},
		{"malformed handle", "admin", 2, func(in *DeliverExistingUserInput) { in.TargetKeepsyID = "!!!" }, nil, "E_NOT_FOUND"},
		{"max epoch below current (replay)", "admin", 2, func(in *DeliverExistingUserInput) { in.Envelopes = envs(0, 1) }, nil, "E_EPOCH_REPLAY"},
		{"gap in epochs", "admin", 2, func(in *DeliverExistingUserInput) { in.Envelopes = envs(0, 2) }, nil, "E_VALIDATION"},
		{"bad ek_pub length", "admin", 2, func(in *DeliverExistingUserInput) { in.EKPub = make([]byte, 31) }, nil, "E_VALIDATION"},
		{"bad wrap_tag_ct length", "admin", 2, func(in *DeliverExistingUserInput) {
			in.Envelopes[1].WrapTagCT = make([]byte, 47)
		}, nil, "E_VALIDATION"},
		{"empty envelopes", "admin", 2, func(in *DeliverExistingUserInput) { in.Envelopes = nil }, nil, "E_VALIDATION"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := newAlbumStore(tc.current, mustNotDeliver)
			if tc.findErr != nil {
				store.findFn = func(_ context.Context, _ string) (uuid.UUID, error) { return uuid.Nil, tc.findErr }
			}
			svc := NewService(store)
			in := baseInput()
			if tc.mutate != nil {
				tc.mutate(&in)
			}
			_, _, err := svc.DeliverExistingUser(context.Background(), uuid.New(), nil, tc.role, in)
			if !apierr.IsCode(err, tc.wantCode) {
				t.Fatalf("err = %v, want code %s", err, tc.wantCode)
			}
		})
	}
}

func TestDeliverExistingUser_AlreadyMember(t *testing.T) {
	store := newAlbumStore(2, func(_ context.Context, _ DeliverMemberInput) ([]byte, error) {
		return nil, ErrAlreadyMember
	})
	svc := NewService(store)
	_, _, err := svc.DeliverExistingUser(context.Background(), uuid.New(), nil, "admin", baseInput())
	if !apierr.IsCode(err, "E_CONFLICT") {
		t.Fatalf("err = %v, want E_CONFLICT", err)
	}
}

func TestDeliverExistingUser_AlbumFull(t *testing.T) {
	store := newAlbumStore(2, func(_ context.Context, _ DeliverMemberInput) ([]byte, error) {
		return nil, ErrAlbumFull
	})
	svc := NewService(store)
	_, _, err := svc.DeliverExistingUser(context.Background(), uuid.New(), nil, "admin", baseInput())
	if !apierr.IsCode(err, "E_ALBUM_FULL") {
		t.Fatalf("err = %v, want E_ALBUM_FULL", err)
	}
}
