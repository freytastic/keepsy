package prekey

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/handle"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// Keeps the resolved UUID out of by-handle responses
type HandleResolver interface {
	FindUserIDByKeepsyID(ctx context.Context, keepsyID string) (uuid.UUID, error)
}

// Resolves rotation targets without exposing their UUIDs
type MemberResolver interface {
	UserIDByAlbumMemberToken(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error)
}

type Handler struct {
	svc            *Service
	notifier       Notifier
	resolver       HandleResolver
	memberResolver MemberResolver
}

func NewHandler(svc *Service, notifier Notifier, resolver HandleResolver, memberResolver MemberResolver) *Handler {
	return &Handler{svc: svc, notifier: notifier, resolver: resolver, memberResolver: memberResolver}
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

// GetOwnKeys returns the caller's key state without consuming an OPK
// An unpublished identity is represented by empty key fields
func (h *Handler) GetOwnKeys(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	id, err := h.svc.OwnKeys(r.Context(), userID)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			apierr.Write(w, r, apierr.NotFound("user not found"))
			return
		}
		apierr.Write(w, r, err)
		return
	}
	out := map[string]any{
		"ik_pub":  base64.StdEncoding.EncodeToString(id.IKPub),
		"lk_pub":  base64.StdEncoding.EncodeToString(id.LKPub),
		"spk_pub": base64.StdEncoding.EncodeToString(id.SPKPub),
	}
	if id.SPKTs != nil {
		out["spk_ts"] = *id.SPKTs
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
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

// Low-OPK notification uses a background context after the request commits
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
	h.writeBundle(w, bundle.UserID, bundle, targetID)
}

// Resolves handles server-side without returning the account UUID
func (h *Handler) GetPrekeyBundleByHandle(w http.ResponseWriter, r *http.Request) {
	if _, ok := middleware.MustGetUserID(w, r); !ok {
		return
	}
	norm, err := handle.Normalize(mux.Vars(r)["handle"])
	if err != nil {
		apierr.Write(w, r, apierr.NotFound("user not found"))
		return
	}
	targetID, err := h.resolver.FindUserIDByKeepsyID(r.Context(), norm)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			apierr.Write(w, r, apierr.NotFound("user not found"))
			return
		}
		apierr.Write(w, r, apierr.Internal("handle lookup failed").WithCause(err))
		return
	}
	bundle, err := h.svc.GetPrekeyBundle(r.Context(), targetID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	h.writeBundle(w, norm, bundle, targetID)
}

// Admin-only rotation lookup returns an album token instead of an account UUID
func (h *Handler) GetPrekeyBundleByMemberToken(w http.ResponseWriter, r *http.Request) {
	role, ok := middleware.MustGetMemberRole(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	if role != "admin" {
		apierr.Write(w, r, apierr.Forbidden("only the admin can fetch a member's prekey bundle"))
		return
	}
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	token, err := decodeMemberTokenPath(mux.Vars(r)["token"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid member_token in path").WithCause(err))
		return
	}
	targetID, err := h.memberResolver.UserIDByAlbumMemberToken(r.Context(), albumID, token)
	if err != nil {
		if errors.Is(err, repository.ErrMemberNotFound) {
			apierr.Write(w, r, apierr.NotFound("no such member in this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("member lookup failed").WithCause(err))
		return
	}
	bundle, err := h.svc.GetPrekeyBundle(r.Context(), targetID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	// identity field = member_token (opaque), never the resolved UUID
	h.writeBundle(w, base64.StdEncoding.EncodeToString(token), bundle, targetID)
}

// Accept all padded and unpadded base64 forms used by old clients
func decodeMemberTokenPath(s string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{
		base64.RawURLEncoding, base64.URLEncoding,
		base64.RawStdEncoding, base64.StdEncoding,
	} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, fmt.Errorf("member_token is not valid base64")
}

// writeBundle encodes the bundle JSON and fires the post commit opk_low fanout
// userIDField is the value of the response "user_id": the real UUID for the
// by id route, the keepsy_id handle for the by handle route
func (h *Handler) writeBundle(w http.ResponseWriter, userIDField any, bundle *PrekeyBundle, targetID uuid.UUID) {
	out := map[string]any{
		"user_id": userIDField,
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

// Pair-scoped limits preserve retries without giving each target a shared bucket
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

// Normalization keeps handle variants in one rate-limit bucket
func KeyByRequesterAndHandle(r *http.Request) string {
	uid, ok := middleware.GetUserID(r.Context())
	if !ok {
		return ""
	}
	raw := mux.Vars(r)["handle"]
	if raw == "" {
		return ""
	}
	norm, err := handle.Normalize(raw)
	if err != nil {
		norm = raw
	}
	return "prekey-bundle-handle:" + uid.String() + ":" + norm
}

// Album-token limits preserve rotation retries without widening probe budgets
func KeyByRequesterAndMemberToken(r *http.Request) string {
	uid, ok := middleware.GetUserID(r.Context())
	if !ok {
		return ""
	}
	albumID := mux.Vars(r)["id"]
	token := mux.Vars(r)["token"]
	if albumID == "" || token == "" {
		return ""
	}
	return "prekey-bundle-token:" + uid.String() + ":" + albumID + ":" + token
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
