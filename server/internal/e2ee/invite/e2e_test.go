package invite

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
)

func mustExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// TestInviteE2E drives the real router → real Service → real Repo → DB for the
// full §6.1/§6.3 sequence: deliver an existing user, verify the rows + OPK
// consume, post a genuine join_complete receipt, and reject a reinvite. The
// deliver path only length checks the wraps, so correctly sized dummy bytes
// suffice : the join receipt is a real Ed25519 signature by the invitee's IK
func TestInviteE2E(t *testing.T) {
	repo, linker, pool := testRepo(t)
	ctx := context.Background()
	svc := NewService(repo)
	h := NewHandler(svc, repo, nil)

	r := mux.NewRouter()
	r.HandleFunc("/api/v1/albums/{id}/invites/existing-user", h.DeliverExistingUser).Methods(http.MethodPost)
	r.HandleFunc("/api/v1/albums/{id}/joins", h.JoinComplete).Methods(http.MethodPost)

	albumID := uuid.New()
	adminID := uuid.New()
	adminToken := randToken(t)
	bobID := uuid.New()
	// First 8 uuid hex chars upper cased: a valid (unique) Crockford handle
	bobKeepsyID := strings.ToUpper(bobID.String()[:8])
	bobIKPub, bobIKPriv, _ := ed25519.GenerateKey(rand.Reader)

	// admin user + identity
	mustExec(t, pool, `INSERT INTO users (id, email_hmac, keepsy_id, ik_pub) VALUES ($1,$2,$3,$4)`,
		adminID, adminID[:], adminID.String(), []byte("admin-ik"))
	// bob user + real IK + a fresh OPK
	mustExec(t, pool, `INSERT INTO users (id, email_hmac, keepsy_id, ik_pub) VALUES ($1,$2,$3,$4)`,
		bobID, bobID[:], bobKeepsyID, []byte(bobIKPub))
	mustExec(t, pool, `INSERT INTO one_time_prekeys (user_id, opk_idx, key_pub) VALUES ($1, 5, $2)`,
		bobID, make([]byte, 32))
	// album with two epochs (current = 1) → deliver must cover 0..1
	mustExec(t, pool, `INSERT INTO albums (id, name_ct) VALUES ($1, $2)`, albumID, []byte("n"))
	mustExec(t, pool, `INSERT INTO album_epochs (album_id, epoch) VALUES ($1, 0), ($1, 1)`, albumID)
	// admin membership (sender_token FK target)
	adminSealed, err := linker.Seal(adminID, adminToken)
	if err != nil {
		t.Fatal(err)
	}
	mustExec(t, pool,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1,$2,$3,$4)`,
		adminToken, linker.Hash(adminID), adminSealed, albumID)
	mustExec(t, pool, `INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'admin')`,
		albumID, adminToken)
	t.Cleanup(func() {
		mustExec(t, pool, `DELETE FROM album_members WHERE album_id=$1`, albumID)
		mustExec(t, pool, `DELETE FROM album_epoch_wraps WHERE album_id=$1`, albumID)
		mustExec(t, pool, `DELETE FROM album_member_identities WHERE album_id=$1`, albumID)
		mustExec(t, pool, `DELETE FROM album_epochs WHERE album_id=$1`, albumID)
		mustExec(t, pool, `DELETE FROM albums WHERE id=$1`, albumID)
		mustExec(t, pool, `DELETE FROM one_time_prekeys WHERE user_id=$1`, bobID)
		mustExec(t, pool, `DELETE FROM users WHERE id = ANY($1)`, []uuid.UUID{adminID, bobID})
	})

	ekPubAdmin := make([]byte, 32)
	ekPubAdmin[0] = 0x77
	idx := 5
	deliverBody, _ := json.Marshal(map[string]any{
		"target_keepsy_id": strings.ToLower(bobKeepsyID), // lower case to exercise Normalize
		"ek_pub":           b64(ekPubAdmin),
		"opk_idx_used":     idx,
		"envelopes": []map[string]any{
			{"epoch": 0, "wrap_nonce": b64(make([]byte, 12)), "wrap_tag_ct": b64(make([]byte, 48)), "sender_sig": b64(make([]byte, 64))},
			{"epoch": 1, "wrap_nonce": b64(make([]byte, 12)), "wrap_tag_ct": b64(make([]byte, 48)), "sender_sig": b64(make([]byte, 64))},
		},
	})

	rec := doReq(r, http.MethodPost, "/api/v1/albums/"+albumID.String()+"/invites/existing-user", deliverBody, adminToken, "admin")
	if rec.Code != http.StatusCreated {
		t.Fatalf("deliver status=%d want 201; body=%s", rec.Code, rec.Body.String())
	}
	var dr struct {
		MemberToken string `json:"member_token"`
	}
	json.Unmarshal(rec.Body.Bytes(), &dr)
	bobToken, _ := base64.StdEncoding.DecodeString(dr.MemberToken)
	if len(bobToken) != 32 {
		t.Fatalf("member_token len=%d", len(bobToken))
	}

	// member_token must be unrelated to the user_id on the wire (§8 DoD)
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM album_members WHERE album_id=$1 AND member_token=$2 AND role='member'`,
		albumID, bobToken).Scan(&n); err != nil || n != 1 {
		t.Fatalf("bob membership row=%d err=%v", n, err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM album_epoch_wraps WHERE album_id=$1 AND recipient_token=$2`,
		albumID, bobToken).Scan(&n); err != nil || n != 2 {
		t.Fatalf("wrap rows=%d want 2 err=%v", n, err)
	}
	var consumed bool
	pool.QueryRow(ctx, `SELECT consumed FROM one_time_prekeys WHERE user_id=$1 AND opk_idx=5`, bobID).Scan(&consumed)
	if !consumed {
		t.Fatal("bob OPK 5 not consumed")
	}

	// join_complete (real Ed25519 receipt by Bob's IK)
	sig := ed25519.Sign(bobIKPriv, JoinCompleteMsg(albumID, 1, ekPubAdmin))
	joinBody, _ := json.Marshal(map[string]any{
		"epoch": 1, "ek_pub_admin": b64(ekPubAdmin), "sig": b64(sig),
	})
	rec = doReq(r, http.MethodPost, "/api/v1/albums/"+albumID.String()+"/joins", joinBody, bobToken, "member")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("join status=%d want 204; body=%s", rec.Code, rec.Body.String())
	}
	var lre int
	pool.QueryRow(ctx, `SELECT last_received_epoch FROM album_member_identities WHERE member_token=$1`, bobToken).Scan(&lre)
	if lre != 1 {
		t.Fatalf("last_received_epoch=%d want 1", lre)
	}

	// reinvite is idempotent → 409
	rec = doReq(r, http.MethodPost, "/api/v1/albums/"+albumID.String()+"/invites/existing-user", deliverBody, adminToken, "admin")
	if rec.Code != http.StatusConflict {
		t.Fatalf("re-invite status=%d want 409", rec.Code)
	}
}

func doReq(r http.Handler, method, path string, body, memberToken []byte, role string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req = req.WithContext(middleware.WithMemberContext(req.Context(), memberToken, role))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	return rec
}
