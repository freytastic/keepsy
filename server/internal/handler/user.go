package handler

import (
	"encoding/base64"
	"encoding/json"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type UserHandler struct {
	userService *service.UserService
}

func NewUserHandler(s *service.UserService) *UserHandler {
	return &UserHandler{userService: s}
}

func (h *UserHandler) GetMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	u, err := h.userService.GetUserByID(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.NotFound("user not found").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           u.ID,
		"email":        u.Email,
		"name":         u.Name,
		"avatar_key":   u.AvatarKey,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
		"ik_pub":       maybeB64(u.IKPub),
		"lk_pub":       maybeB64(u.LKPub),
		"spk_pub":      maybeB64(u.SPKPub),
		"spk_sig":      maybeB64(u.SPKSig),
		"spk_ts":       u.SPKTs,
		"created_at":   u.CreatedAt,
		"updated_at":   u.UpdatedAt,
	})
}

func maybeB64(b []byte) *string {
	if len(b) == 0 {
		return nil
	}
	s := base64.StdEncoding.EncodeToString(b)
	return &s
}

type UpdateUserRequest struct {
	Name        *string `json:"name"`
	AccentColor string  `json:"accent_color"`
	Theme       string  `json:"theme"`
	IKPub       *string `json:"ik_pub"`
	LKPub       *string `json:"lk_pub"`
	SPKPub      *string `json:"spk_pub"`
	SPKSig      *string `json:"spk_sig"`
	SPKTs       *int64  `json:"spk_ts"`
}

func (h *UserHandler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req UpdateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}

	in := service.UserUpdate{
		Name:        req.Name,
		AccentColor: req.AccentColor,
		Theme:       req.Theme,
		SPKTs:       req.SPKTs,
	}
	for _, kv := range []struct {
		src *string
		dst *[]byte
		nm  string
	}{
		{req.IKPub, &in.IKPub, "ik_pub"},
		{req.LKPub, &in.LKPub, "lk_pub"},
		{req.SPKPub, &in.SPKPub, "spk_pub"},
		{req.SPKSig, &in.SPKSig, "spk_sig"},
	} {
		if kv.src == nil {
			continue
		}
		b, err := decodeBase64(*kv.src)
		if err != nil {
			apierr.Write(w, r, apierr.Validation(kv.nm+" must be base64").WithCause(err))
			return
		}
		*kv.dst = b
	}

	u, err := h.userService.UpdateUser(r.Context(), userID, in)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update user").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           u.ID,
		"email":        u.Email,
		"name":         u.Name,
		"accent_color": u.AccentColor,
		"theme":        u.Theme,
	})
}

func (h *UserHandler) GetPrekeyBundle(w http.ResponseWriter, r *http.Request) {
	targetID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid user id").WithCause(err))
		return
	}
	bundle, err := h.userService.GetPrekeyBundle(r.Context(), targetID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to fetch prekey bundle").WithCause(err))
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
}

type opkItem struct {
	Idx    int    `json:"idx"`
	KeyPub string `json:"key_pub"`
}

func (h *UserHandler) ReplenishOPKs(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req struct {
		OPKs []opkItem `json:"opks"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	if len(req.OPKs) == 0 {
		apierr.Write(w, r, apierr.Validation("opks must be a non-empty array of {idx, key_pub}"))
		return
	}
	uploads := make([]service.OPKUpload, len(req.OPKs))
	for i, o := range req.OPKs {
		b, err := decodeBase64(o.KeyPub)
		if err != nil || len(b) != 32 {
			apierr.Write(w, r, apierr.Validation("opks[].key_pub must be 32-byte base64"))
			return
		}
		uploads[i] = service.OPKUpload{Idx: o.Idx, KeyPub: b}
	}
	if err := h.userService.ReplenishOPKs(r.Context(), userID, uploads); err != nil {
		apierr.Write(w, r, apierr.Internal("failed to replenish OPKs").WithCause(err))
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (h *UserHandler) GetOPKCount(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	count, err := h.userService.GetOPKCount(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to count OPKs").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]int{"count": count})
}
