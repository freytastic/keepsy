package epoch

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Notifier mirrors *notifications.Service.EmitToUsers : an interface so the
// handler tests can stub the fanout
type Notifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// memberLister is the subset of *repository.AlbumRepository the handler needs
// to resolve recipient_tokens → user_ids for the WS fanout
type memberLister interface {
	UserIDsByMemberTokens(ctx context.Context, tokens [][]byte) ([]uuid.UUID, error)
}

type Handler struct {
	svc      *Service
	repo     memberLister
	notifier Notifier
}

func NewHandler(svc *Service, repo memberLister, notifier Notifier) *Handler {
	return &Handler{svc: svc, repo: repo, notifier: notifier}
}

type wrapItem struct {
	RecipientToken string `json:"recipient_token"`
	EkPub          string `json:"ek_pub"`
	OpkIdxUsed     *int32 `json:"opk_idx_used"`
	Wrap           string `json:"wrap"`
	SenderSig      string `json:"sender_sig"`
}

type setEpochReq struct {
	Epoch         int        `json:"epoch"`
	MemberSetHash string     `json:"member_set_hash"`
	Wraps         []wrapItem `json:"wraps"`
	EnvelopeSig   string     `json:"envelope_sig"`
}

// SetEpoch handles POST /api/v1/albums/{id}/epoch
func (h *Handler) SetEpoch(w http.ResponseWriter, r *http.Request) {
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

	var req setEpochReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	hash, err := decodeB64(req.MemberSetHash, "member_set_hash")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	envSig, err := decodeB64(req.EnvelopeSig, "envelope_sig")
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	wraps := make([]WrapInput, len(req.Wraps))
	tokens := make([][]byte, len(req.Wraps))
	for i, item := range req.Wraps {
		rt, err := decodeB64(item.RecipientToken, "wraps[].recipient_token")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		ek, err := decodeB64(item.EkPub, "wraps[].ek_pub")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		wb, err := decodeB64(item.Wrap, "wraps[].wrap")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		ss, err := decodeB64(item.SenderSig, "wraps[].sender_sig")
		if err != nil {
			apierr.Write(w, r, err)
			return
		}
		wraps[i] = WrapInput{
			RecipientToken: rt,
			EkPub:          ek,
			OpkIdxUsed:     item.OpkIdxUsed,
			Wrap:           wb,
			SenderSig:      ss,
		}
		tokens[i] = rt
	}

	if err := h.svc.SetEpoch(r.Context(), albumID, callerToken, callerRole, SetEpochInput{
		Epoch:         req.Epoch,
		MemberSetHash: hash,
		Wraps:         wraps,
		EnvelopeSig:   envSig,
	}); err != nil {
		apierr.Write(w, r, err)
		return
	}

	if h.notifier != nil && h.repo != nil {
		go h.fanout(albumID, req.Epoch, tokens)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{"epoch": req.Epoch})
}

// fanout emits e2ee.epoch_changed to every user behind the recipient_tokens
// Runs in a goroutine off the request ctx : the request is already committed
// before this kicks off
func (h *Handler) fanout(albumID uuid.UUID, epoch int, tokens [][]byte) {
	ctx := context.Background()
	users, err := h.repo.UserIDsByMemberTokens(ctx, tokens)
	if err != nil {
		slog.Default().Warn("epoch: fanout user lookup failed", "album_id", albumID, "err", err)
		return
	}
	if len(users) == 0 {
		return
	}
	if err := h.notifier.EmitToUsers(ctx, users, ws.EventEpochChanged, map[string]any{
		"album_id": albumID.String(),
		"epoch":    epoch,
	}); err != nil {
		slog.Default().Warn("epoch: fanout emit failed", "album_id", albumID, "err", err)
	}
}

// GetCurrent handles GET /api/v1/albums/{id}/epoch
func (h *Handler) GetCurrent(w http.ResponseWriter, r *http.Request) {
	albumID, ok := h.albumID(w, r)
	if !ok {
		return
	}
	res, err := h.svc.GetCurrent(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to read epoch").WithCause(err))
		return
	}
	if !res.Exists {
		apierr.Write(w, r, apierr.NotFound("album has no epoch yet"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"current_epoch": res.CurrentEpoch,
		"started_at":    res.StartedAt,
	})
}

// GetWrap handles GET /api/v1/albums/{id}/epoch/{n}/wrap
// Recipient_token is taken from the auth/member context, never from the path,
// so a client cannot fetch another member's wrap by guessing
func (h *Handler) GetWrap(w http.ResponseWriter, r *http.Request) {
	albumID, ok := h.albumID(w, r)
	if !ok {
		return
	}
	callerToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	rawN, ok := mux.Vars(r)["n"]
	if !ok {
		apierr.Write(w, r, apierr.Validation("missing epoch in path"))
		return
	}
	epoch, err := strconv.Atoi(rawN)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("epoch must be an integer").WithCause(err))
		return
	}
	wr, err := h.svc.GetWrap(r.Context(), albumID, epoch, callerToken)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	wrapBlob := append([]byte{verAesGcm}, wr.WrapNonce...)
	wrapBlob = append(wrapBlob, wr.WrapTagCT...)
	out := map[string]any{
		"epoch":        wr.Epoch,
		"ek_pub":       base64.StdEncoding.EncodeToString(wr.EkPub),
		"wrap":         base64.StdEncoding.EncodeToString(wrapBlob),
		"sender_token": base64.StdEncoding.EncodeToString(wr.SenderToken),
		"sender_sig":   base64.StdEncoding.EncodeToString(wr.SenderSig),
		"delivered_at": wr.DeliveredAt,
	}
	if wr.OpkIdxUsed != nil {
		out["opk_idx_used"] = *wr.OpkIdxUsed
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
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
