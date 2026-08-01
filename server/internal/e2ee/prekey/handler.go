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

// Notifier matches the EmitToUsers method on *ws.Hub so the handler can be
// constructed without a hard dep on the hub package (and tests can stub it)
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// HandleResolver maps a normalized keepsy_id to its user_id. *repository.UserRepository
// satisfies it : the by-handle bundle lookup never exposes the resolved UUID
type HandleResolver interface {
	FindUserIDByKeepsyID(ctx context.Context, keepsyID string) (uuid.UUID, error)
}

// MemberResolver maps an album's member_token back to its user_id (M bridge
// unseal, scoped to the album). Backs the by nickname bundle fetch the epoch
// rotator uses to wrap MK_new for members it only knows by token : the resolved
// UUID never reaches the wire. The epoch repo satisfies it
type MemberResolver interface {
	UserIDByAlbumMemberToken(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error)
}

// Handler routes the §2.2 endpoints + the §6.1 by-handle lookup into the service layer
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
	h.writeBundle(w, bundle.UserID, bundle, targetID)
}

// GetPrekeyBundleByHandle handles GET /users/by-handle/{handle}/prekey-bundle
// It resolves the random keepsy_id to a user_id server side and returns the
// same bundle shape, but with the user_id field set to the handle , the real
// UUID never reaches the wire (§6.1 D10). Unknown/invalid handles 404 alike
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

// GetPrekeyBundleByMemberToken handles
// GET /albums/{id}/members/{member_token}/prekey-bundle

// Mounted under the album membership gate, so the caller is already a member
// this additionally requires admin/co admin. The member_token is resolved to a
// user_id server side (scoped to this album, so a token from another album 404s)
// and the same bundle shape is returned with the identity field set to the
// member_token : the real UUID and keepsy_id never reach the wire. Like every
// bundle fetch it consumes an OPK
func (h *Handler) GetPrekeyBundleByMemberToken(w http.ResponseWriter, r *http.Request) {
	role, ok := middleware.MustGetMemberRole(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	if role != "admin" && role != "co-admin" {
		apierr.Write(w, r, apierr.Forbidden("only admin or co admin can fetch a member's prekey bundle"))
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

// decodeMemberTokenPath decodes a member_token carried in a URL path. Tokens
// are 32 raw bytes emitted to clients as std base64, a client putting one in a
// path re encodes as base64url (std base64's '/' and '+' break routing). Accept
// any of the four alphabets so a forgotten padding strip still round-trips
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

// KeyByRequesterAndHandle keys the by-handle lookup limit per (requester, handle)
// Normalizing first means dash/case variants of one handle share a bucket and
// cant multiply an attacker's probe budget
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

// KeyByRequesterAndMemberToken keys the by nickname bundle limit per
// (requester, album, member_token), mirroring the per (requester, target) pair
// limit on the by id route so an admin rotating an album repeatedly is cheap
// while token enumeration stays costly
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
