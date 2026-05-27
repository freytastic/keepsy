package invite

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type stubService struct {
	token   []byte
	uid     uuid.UUID
	err     error
	joinErr error
}

func (s *stubService) DeliverExistingUser(_ context.Context, _ uuid.UUID, _ []byte, _ string, _ DeliverExistingUserInput) ([]byte, uuid.UUID, error) {
	return s.token, s.uid, s.err
}

func (s *stubService) JoinComplete(_ context.Context, _ uuid.UUID, _ []byte, _ JoinCompleteInput) error {
	return s.joinErr
}

type stubDir struct{ ids []uuid.UUID }

func (d stubDir) ActiveMemberUserIDs(_ context.Context, _ uuid.UUID) ([]uuid.UUID, error) {
	return d.ids, nil
}

type emit struct {
	users []uuid.UUID
	typ   string
	data  map[string]any
}

type captureNotifier struct{ ch chan emit }

func (c *captureNotifier) EmitToUsers(_ context.Context, ids []uuid.UUID, typ string, payload any) error {
	m, _ := payload.(map[string]any)
	c.ch <- emit{users: ids, typ: typ, data: m}
	return nil
}

func inviteRouter(h *Handler) http.Handler {
	r := mux.NewRouter()
	r.HandleFunc("/api/v1/albums/{id}/invites/existing-user", h.DeliverExistingUser).Methods(http.MethodPost)
	return r
}

func memberReq(albumID uuid.UUID, body []byte, role string) *http.Request {
	req := httptest.NewRequest(http.MethodPost,
		"/api/v1/albums/"+albumID.String()+"/invites/existing-user", bytes.NewReader(body))
	ctx := middleware.WithMemberContext(req.Context(), make([]byte, 32), role)
	return req.WithContext(ctx)
}

func deliverBody(keepsyID string, nEpochs int) []byte {
	envs := make([]map[string]any, nEpochs)
	for i := range envs {
		envs[i] = map[string]any{
			"epoch":       i,
			"wrap_nonce":  base64.StdEncoding.EncodeToString(make([]byte, 12)),
			"wrap_tag_ct": base64.StdEncoding.EncodeToString(make([]byte, 48)),
			"sender_sig":  base64.StdEncoding.EncodeToString(make([]byte, 64)),
		}
	}
	b, _ := json.Marshal(map[string]any{
		"target_keepsy_id": keepsyID,
		"ek_pub":           base64.StdEncoding.EncodeToString(make([]byte, 32)),
		"opk_idx_used":     3,
		"envelopes":        envs,
	})
	return b
}

func TestHandler_DeliverExistingUser_HappyPathAndFanout(t *testing.T) {
	token := make([]byte, 32)
	for i := range token {
		token[i] = byte(i)
	}
	newMember := uuid.New()
	existing := uuid.New()
	svc := &stubService{token: token, uid: newMember}
	notif := &captureNotifier{ch: make(chan emit, 4)}
	h := NewHandler(svc, stubDir{ids: []uuid.UUID{newMember, existing}}, notif)

	albumID := uuid.New()
	rec := httptest.NewRecorder()
	inviteRouter(h).ServeHTTP(rec, memberReq(albumID, deliverBody("k7f2-9qxm", 3), "admin"))

	if rec.Code != http.StatusCreated {
		t.Fatalf("status=%d want 201; body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		MemberToken string `json:"member_token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.MemberToken != base64.StdEncoding.EncodeToString(token) {
		t.Fatalf("member_token = %q, want b64 of returned token", body.MemberToken)
	}

	var sawJoined, sawMemberAdded bool
	for i := 0; i < 2; i++ {
		select {
		case ev := <-notif.ch:
			switch ev.typ {
			case ws.EventEpochChanged:
				if len(ev.users) != 1 || ev.users[0] != newMember {
					t.Errorf("epoch_changed users = %v, want [%v]", ev.users, newMember)
				}
				if ev.data["joined"] != true {
					t.Errorf("epoch_changed missing joined:true (%v)", ev.data)
				}
				// 3 envelopes (epochs 0,1,2) → current epoch 2
				if jn, ok := ev.data["epoch"].(int); !ok || jn != 2 {
					t.Errorf("epoch_changed epoch = %v, want 2", ev.data["epoch"])
				}
				sawJoined = true
			case ws.EventMemberAdded:
				if len(ev.users) != 1 || ev.users[0] != existing {
					t.Errorf("member_added users = %v, want [%v] (new member excluded)", ev.users, existing)
				}
				sawMemberAdded = true
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for fanout events")
		}
	}
	if !sawJoined || !sawMemberAdded {
		t.Fatalf("fanout incomplete: joined=%v member_added=%v", sawJoined, sawMemberAdded)
	}
}

func TestHandler_DeliverExistingUser_Errors(t *testing.T) {
	cases := []struct {
		name       string
		body       []byte
		svcErr     error
		role       string
		wantStatus int
	}{
		{"service forbidden -> 403", deliverBody("k7f2-9qxm", 3), apierr.Forbidden("nope"), "member", http.StatusForbidden},
		{"service conflict -> 409", deliverBody("k7f2-9qxm", 3), apierr.Conflict("dup"), "admin", http.StatusConflict},
		{"service epoch replay -> 409", deliverBody("k7f2-9qxm", 3), apierr.EpochReplay("replay"), "admin", http.StatusConflict},
		{"bad body -> 400", []byte("{not json"), nil, "admin", http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc := &stubService{token: make([]byte, 32), uid: uuid.New(), err: tc.svcErr}
			h := NewHandler(svc, stubDir{}, &captureNotifier{ch: make(chan emit, 4)})
			rec := httptest.NewRecorder()
			inviteRouter(h).ServeHTTP(rec, memberReq(uuid.New(), tc.body, tc.role))
			if rec.Code != tc.wantStatus {
				t.Fatalf("status=%d want %d; body=%s", rec.Code, tc.wantStatus, rec.Body.String())
			}
		})
	}
}

func TestHandler_JoinComplete(t *testing.T) {
	joinRouter := func(h *Handler) http.Handler {
		r := mux.NewRouter()
		r.HandleFunc("/api/v1/albums/{id}/joins", h.JoinComplete).Methods(http.MethodPost)
		return r
	}
	joinReqOf := func(albumID uuid.UUID, body []byte) *http.Request {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/albums/"+albumID.String()+"/joins", bytes.NewReader(body))
		return req.WithContext(middleware.WithMemberContext(req.Context(), make([]byte, 32), "member"))
	}
	joinBody := func(epoch int) []byte {
		b, _ := json.Marshal(map[string]any{
			"epoch":        epoch,
			"ek_pub_admin": base64.StdEncoding.EncodeToString(make([]byte, 32)),
			"sig":          base64.StdEncoding.EncodeToString(make([]byte, 64)),
		})
		return b
	}

	t.Run("happy -> 204", func(t *testing.T) {
		h := NewHandler(&stubService{}, stubDir{}, nil)
		rec := httptest.NewRecorder()
		joinRouter(h).ServeHTTP(rec, joinReqOf(uuid.New(), joinBody(2)))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status=%d want 204; body=%s", rec.Code, rec.Body.String())
		}
	})
	t.Run("sig invalid -> 400", func(t *testing.T) {
		h := NewHandler(&stubService{joinErr: apierr.SigInvalid("bad")}, stubDir{}, nil)
		rec := httptest.NewRecorder()
		joinRouter(h).ServeHTTP(rec, joinReqOf(uuid.New(), joinBody(2)))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status=%d want 400", rec.Code)
		}
	})
}

func TestHandler_DeliverExistingUser_MissingMemberContext(t *testing.T) {
	h := NewHandler(&stubService{token: make([]byte, 32)}, stubDir{}, nil)
	r := mux.NewRouter()
	r.HandleFunc("/api/v1/albums/{id}/invites/existing-user", h.DeliverExistingUser).Methods(http.MethodPost)
	rec := httptest.NewRecorder()
	// no WithMemberContext → must 401, never reach the service
	req := httptest.NewRequest(http.MethodPost,
		"/api/v1/albums/"+uuid.NewString()+"/invites/existing-user", bytes.NewReader(deliverBody("k7f2-9qxm", 3)))
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401", rec.Code)
	}
}
