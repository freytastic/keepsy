package invite

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Notifier matches *ws.Hub.EmitToUsers so the fanout can be stubbed in tests
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// inviteService is the slice of *Service the handler drives : an interface so
// handler tests can stub error and success paths without a DB
type inviteService interface {
	DeliverExistingUser(ctx context.Context, albumID uuid.UUID, callerToken []byte, callerRole string, in DeliverExistingUserInput) ([]byte, uuid.UUID, error)
	JoinComplete(ctx context.Context, albumID uuid.UUID, callerToken []byte, in JoinCompleteInput) error
}

// directory resolves the album's active roster for the member_added fanout
type directory interface {
	ActiveMemberUserIDs(ctx context.Context, albumID uuid.UUID) ([]uuid.UUID, error)
}

type Handler struct {
	svc      inviteService
	dir      directory
	notifier Notifier
}

func NewHandler(svc inviteService, dir directory, notifier Notifier) *Handler {
	return &Handler{svc: svc, dir: dir, notifier: notifier}
}

type envelopeItem struct {
	Epoch     int    `json:"epoch"`
	WrapNonce string `json:"wrap_nonce"`
	WrapTagCT string `json:"wrap_tag_ct"`
	SenderSig string `json:"sender_sig"`
}

type deliverReq struct {
	TargetKeepsyID string         `json:"target_keepsy_id"`
	EKPub          string         `json:"ek_pub"`
	OPKIdxUsed     *int           `json:"opk_idx_used"`
	Envelopes      []envelopeItem `json:"envelopes"`
}

// DeliverExistingUser handles POST /api/v1/albums/{id}/invites/existing-user
func (h *Handler) DeliverExistingUser(w http.ResponseWriter, r *http.Request) {
	albumID, ok := h.albumID(w, r)
	if !ok {
		return
	}
	callerToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	callerRole, _ := middleware.MustGetMemberRole(r)

	var req deliverReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	ekPub, err := decodeB64(req.EKPub, "ek_pub")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	envelopes := make([]Envelope, len(req.Envelopes))
	maxEpoch := -1
	for i, item := range req.Envelopes {
		nonce, err := decodeB64(item.WrapNonce, "envelopes[].wrap_nonce")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		tagCT, err := decodeB64(item.WrapTagCT, "envelopes[].wrap_tag_ct")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		sig, err := decodeB64(item.SenderSig, "envelopes[].sender_sig")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		envelopes[i] = Envelope{Epoch: item.Epoch, WrapNonce: nonce, WrapTagCT: tagCT, SenderSig: sig}
		if item.Epoch > maxEpoch {
			maxEpoch = item.Epoch
		}
	}

	token, targetUserID, err := h.svc.DeliverExistingUser(r.Context(), albumID, callerToken, callerRole, DeliverExistingUserInput{
		TargetKeepsyID: req.TargetKeepsyID,
		EKPub:          ekPub,
		OPKIdxUsed:     req.OPKIdxUsed,
		Envelopes:      envelopes,
	})
	if err != nil {
		apierr.Write(w, r, err)
		return
	}

	if h.notifier != nil {
		go h.fanout(albumID, maxEpoch, targetUserID)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"member_token": base64.StdEncoding.EncodeToString(token),
	})
}

// fanout pings the new member to backfill (epoch_changed{joined:true}) and the
// existing roster to refresh (member_added). Besteffort, off the request ctx
// since the invite is already committed. The new member also catches this via
// the cold start path, so a missed live event is not fatal
func (h *Handler) fanout(albumID uuid.UUID, current int, newMember uuid.UUID) {
	ctx := context.Background()
	if err := h.notifier.EmitToUsers(ctx, []uuid.UUID{newMember}, ws.EventEpochChanged, map[string]any{
		"album_id": albumID.String(),
		"epoch":    current,
		"joined":   true,
	}); err != nil {
		slog.Default().Warn("invite: joined emit failed", "album_id", albumID, "err", err)
	}
	if h.dir == nil {
		return
	}
	all, err := h.dir.ActiveMemberUserIDs(ctx, albumID)
	if err != nil {
		slog.Default().Warn("invite: member fanout lookup failed", "album_id", albumID, "err", err)
		return
	}
	existing := make([]uuid.UUID, 0, len(all))
	for _, u := range all {
		if u != newMember {
			existing = append(existing, u)
		}
	}
	if len(existing) == 0 {
		return
	}
	if err := h.notifier.EmitToUsers(ctx, existing, ws.EventMemberAdded, map[string]any{
		"album_id": albumID.String(),
	}); err != nil {
		slog.Default().Warn("invite: member_added emit failed", "album_id", albumID, "err", err)
	}
}

type joinReq struct {
	Epoch      int    `json:"epoch"`
	EKPubAdmin string `json:"ek_pub_admin"`
	Sig        string `json:"sig"`
}

// JoinComplete handles POST /api/v1/albums/{id}/joins : the new member proves
// (Ed25519 over their IK) that they installed the album up to a given epoch
func (h *Handler) JoinComplete(w http.ResponseWriter, r *http.Request) {
	albumID, ok := h.albumID(w, r)
	if !ok {
		return
	}
	callerToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	var req joinReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	ekPubAdmin, err := decodeB64(req.EKPubAdmin, "ek_pub_admin")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	sig, err := decodeB64(req.Sig, "sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if err := h.svc.JoinComplete(r.Context(), albumID, callerToken, JoinCompleteInput{
		Epoch:      req.Epoch,
		EKPubAdmin: ekPubAdmin,
		Sig:        sig,
	}); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) albumID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	raw, ok := mux.Vars(r)["id"]
	if !ok {
		apierr.Write(w, r, apierr.Validation("missing album id in path"))
		return uuid.Nil, false
	}
	id, err := uuid.Parse(raw)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return uuid.Nil, false
	}
	return id, true
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
