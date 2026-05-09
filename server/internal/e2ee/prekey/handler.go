package prekey

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Notifier mirrors *notifications.Service.EmitToUsers so the handler can be
// constructed without a hard dep on that package (and tests can stub it)
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// Handler routes the five §2.2 endpoints into the service layer
type Handler struct {
	svc      *Service
	notifier Notifier
}

func NewHandler(svc *Service, notifier Notifier) *Handler {
	return &Handler{svc: svc, notifier: notifier}
}

type upsertIdentityReq struct {
	IKPub  string `json:"ik_pub"`
	LKPub  string `json:"lk_pub"`
	SPKPub string `json:"spk_pub"`
	SPKSig string `json:"spk_sig"`
	SPKTs  int64  `json:"spk_ts"`
}

// UpsertIdentity handles PUT /users/me/keys
func (h *Handler) UpsertIdentity(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req upsertIdentityReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	ik, err := decodeB64(req.IKPub, "ik_pub")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	lk, err := decodeB64(req.LKPub, "lk_pub")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	spk, err := decodeB64(req.SPKPub, "spk_pub")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	sig, err := decodeB64(req.SPKSig, "spk_sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if err := h.svc.UpsertIdentity(r.Context(), userID, UpsertIdentityInput{
		IKPub: ik, LKPub: lk, SPKPub: spk, SPKSig: sig, SPKTs: req.SPKTs,
	}); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type rotateSPKReq struct {
	SPKPub      string `json:"spk_pub"`
	SPKSig      string `json:"spk_sig"`
	SPKTs       int64  `json:"spk_ts"`
	RotationSig string `json:"rotation_sig"`
}

// RotateSPK handles POST /users/me/spk
func (h *Handler) RotateSPK(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req rotateSPKReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	spk, err := decodeB64(req.SPKPub, "spk_pub")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	sig, err := decodeB64(req.SPKSig, "spk_sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	rsig, err := decodeB64(req.RotationSig, "rotation_sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if err := h.svc.RotateSPK(r.Context(), userID, RotateSPKInput{
		SPKPub:      spk,
		SPKSig:      sig,
		SPKTs:       req.SPKTs,
		RotationSig: rsig,
	}); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type opkItem struct {
	Idx    int    `json:"idx"`
	KeyPub string `json:"key_pub"`
}

type replenishReq struct {
	OPKs         []opkItem `json:"opks"`
	ReplenishSig string    `json:"replenish_sig"`
}

// ReplenishOPKs handles POST /users/me/opks
func (h *Handler) ReplenishOPKs(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req replenishReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	uploads := make([]OPKUpload, len(req.OPKs))
	for i, o := range req.OPKs {
		b, err := decodeB64(o.KeyPub, "opks[].key_pub")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		uploads[i] = OPKUpload{Idx: o.Idx, KeyPub: b}
	}
	rsig, err := decodeB64(req.ReplenishSig, "replenish_sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if err := h.svc.ReplenishOPKs(r.Context(), userID, ReplenishOPKsInput{
		OPKs: uploads, ReplenishSig: rsig,
	}); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

// GetOPKCount handles GET /users/me/opks/count
func (h *Handler) GetOPKCount(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	n, err := h.svc.GetOPKCount(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to count OPKs").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]int{"count": n})
}

// GetPrekeyBundle handles GET /users/{id}/prekey-bundle. The handler fires the
// e2ee.opk_low fanout post commit when the target's unconsumed count drops
// below the threshold : the goroutine uses a fresh background ctx bcs the
// request ctx may be cancelled before the WS hub picks it up
func (h *Handler) GetPrekeyBundle(w http.ResponseWriter, r *http.Request) {
	if _, ok := middleware.MustGetUserID(w, r); !ok {
		return
	}
	targetID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid user id").WithCause(err))
		return
	}
	bundle, err := h.svc.GetPrekeyBundle(r.Context(), targetID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	out := map[string]any{
		"user_id": bundle.UserID,
		"ik_pub":  base64.StdEncoding.EncodeToString(bundle.IKPub),
		"lk_pub":  base64.StdEncoding.EncodeToString(bundle.LKPub),
		"spk_pub": base64.StdEncoding.EncodeToString(bundle.SPKPub),
		"spk_sig": base64.StdEncoding.EncodeToString(bundle.SPKSig),
		"spk_ts":  bundle.SPKTs,
	}
	if bundle.OPK != nil {
		out["opk"] = map[string]any{
			"idx":     bundle.OPK.Idx,
			"key_pub": base64.StdEncoding.EncodeToString(bundle.OPK.KeyPub),
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)

	if h.notifier != nil && bundle.OPK != nil && bundle.OPKLeft >= 0 && bundle.OPKLeft < opkLowThreshold {
		go func(remaining int) {
			ctx := context.Background()
			if err := h.notifier.EmitToUsers(ctx, []uuid.UUID{targetID}, ws.EventOPKLow, map[string]any{
				"remaining": remaining,
			}); err != nil {
				slog.Default().Warn("prekey: opk_low emit failed", "user_id", targetID, "err", err)
			}
		}(bundle.OPKLeft)
	}
}

// KeyByRequesterAndTarget keys the per pair rate limit. Pre M10 the key was
// per requester only : that allowed 5/min probing across distinct targets,
// trivially enumerable as 7,200/day. Per pair makes legitimate "Im inviting
// person X to album Y" repeats cheap while making target enumeration costly
func KeyByRequesterAndTarget(r *http.Request) string {
	uid, ok := middleware.GetUserID(r.Context())
	if !ok {
		return ""
	}
	target := mux.Vars(r)["id"]
	if target == "" {
		return ""
	}
	return "prekey-bundle:" + uid.String() + ":" + target
}

// KeyByRequesterTargetHourly returns (set_key, member) for the distinct
// target probe tracker. The key rolls each hour so the window is naturally
// bounded : the member is the target user_id being probed
func KeyByRequesterTargetHourly(r *http.Request) (string, string) {
	uid, ok := middleware.GetUserID(r.Context())
	if !ok {
		return "", ""
	}
	target := mux.Vars(r)["id"]
	if target == "" {
		return "", ""
	}
	hour := time.Now().UTC().Unix() / 3600
	return fmt.Sprintf("prekey-probe:%s:%d", uid.String(), hour), target
}

func decodeB64(s, field string) ([]byte, error) {
	if s == "" {
		return nil, apierr.Validation(field + " is required")
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, apierr.Validation(field + " must be base64").WithCause(err)
	}
	return b, nil
}
