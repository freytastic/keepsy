package handler

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/freytastic/keepsy/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// MemberNotifier fans out an e2ee event to a set of users. *ws.Hub satisfies it
type MemberNotifier interface {
	EmitToUsers(ctx context.Context, userIDs []uuid.UUID, typ string, payload any) error
}

// MemberResolver turns member_tokens back into user_ids for WS delivery. The
// epoch repo satisfies it (M bridge unseal)
type MemberResolver interface {
	UserIDsByMemberTokens(ctx context.Context, tokens [][]byte) ([]uuid.UUID, error)
}

type AlbumHandler struct {
	albumService *service.AlbumService
	notifier     MemberNotifier
	resolver     MemberResolver
}

// notifier and resolver may be nil (WS fanout is then skipped) : handler tests
// that only exercise authz pass nil
func NewAlbumHandler(s *service.AlbumService, notifier MemberNotifier, resolver MemberResolver) *AlbumHandler {
	return &AlbumHandler{albumService: s, notifier: notifier, resolver: resolver}
}

// decodeMemberTokenPath decodes a member_token carried in a URL path. Tokens
// are minted as 32 raw bytes and emitted to clients as std base64; when a
// client puts one in a path it must re encode as base64url (the '/' and '+' of
// std base64 break routing). We accept any of the four base64 alphabets so a
// client that forgets to strip padding still round trips
func decodeMemberTokenPath(s string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{
		base64.RawURLEncoding, base64.URLEncoding,
		base64.RawStdEncoding, base64.StdEncoding,
	} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, errors.New("member_token is not valid base64")
}

type albumDTO struct {
	ID          uuid.UUID `json:"id"`
	NameCT      string    `json:"name_ct"`
	CreatedAt   string    `json:"created_at"`
	UpdatedAt   string    `json:"updated_at"`
	UserRole    string    `json:"user_role,omitempty"`
	MemberToken string    `json:"member_token,omitempty"`
}

func decodeBase64(s string) ([]byte, error) {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.URLEncoding.DecodeString(s)
}

func (h *AlbumHandler) CreateAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req struct {
		NameCT string `json:"name_ct"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	nameCT, err := decodeBase64(req.NameCT)
	if err != nil || len(nameCT) == 0 {
		apierr.Write(w, r, apierr.Validation("name_ct must be base64-encoded ciphertext"))
		return
	}
	res, err := h.albumService.CreateAlbum(r.Context(), nameCT, userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to create album").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           res.Album.ID,
		"name_ct":      base64.StdEncoding.EncodeToString(res.Album.NameCT),
		"created_at":   res.Album.CreatedAt,
		"updated_at":   res.Album.UpdatedAt,
		"member_token": base64.StdEncoding.EncodeToString(res.MemberToken),
		"role":         res.Role,
	})
}

func (h *AlbumHandler) GetAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	a, err := h.albumService.GetAlbum(r.Context(), albumID, userID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.NotMember("not a member of this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to fetch album").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":           a.ID,
		"name_ct":      base64.StdEncoding.EncodeToString(a.NameCT),
		"created_at":   a.CreatedAt,
		"updated_at":   a.UpdatedAt,
		"role":         a.UserRole,
		"member_token": base64.StdEncoding.EncodeToString(a.MemberToken),
	})
}

func (h *AlbumHandler) ListAlbums(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albums, err := h.albumService.ListUserAlbums(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to list albums").WithCause(err))
		return
	}
	out := make([]map[string]any, len(albums))
	for i, a := range albums {
		out[i] = map[string]any{
			"id":           a.ID,
			"name_ct":      base64.StdEncoding.EncodeToString(a.NameCT),
			"created_at":   a.CreatedAt,
			"updated_at":   a.UpdatedAt,
			"role":         a.UserRole,
			"member_token": base64.StdEncoding.EncodeToString(a.MemberToken),
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (h *AlbumHandler) UpdateAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	var req struct {
		NameCT string `json:"name_ct"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	nameCT, err := decodeBase64(req.NameCT)
	if err != nil || len(nameCT) == 0 {
		apierr.Write(w, r, apierr.Validation("name_ct must be base64-encoded ciphertext"))
		return
	}
	if err := h.albumService.UpdateAlbum(r.Context(), albumID, userID, nameCT); err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can update this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to update album").WithCause(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *AlbumHandler) DeleteAlbum(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	if err := h.albumService.DeleteAlbum(r.Context(), albumID, userID); err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin can delete this album"))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to delete album").WithCause(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func optBase64(b []byte) *string {
	if len(b) == 0 {
		return nil
	}
	s := base64.StdEncoding.EncodeToString(b)
	return &s
}

func (h *AlbumHandler) ListAlbumMembers(w http.ResponseWriter, r *http.Request) {
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	members, err := h.albumService.ListMembers(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("failed to list members").WithCause(err))
		return
	}
	out := make([]map[string]any, len(members))
	for i, m := range members {
		out[i] = map[string]any{
			"member_token": base64.StdEncoding.EncodeToString(m.MemberToken),
			"role":         m.Role,
			"revoked":      m.Revoked,
			"joined_at":    m.JoinedAt,
			"profile": map[string]any{
				"ik_pub":  optBase64(m.Profile.IKPub),
				"lk_pub":  optBase64(m.Profile.LKPub),
				"name_ct": optBase64(m.Profile.NameCT),
			},
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// UpdateMyProfileCT handles PUT /albums/{id}/members/me/profile-ct
// Body: {"name_ct": base64}. Server stores the bytes opaquely : decryption
// happens client side under the album's MK_current. Caller must already be
// a member (RequireMember middleware enforces and resolves member_token)
func (h *AlbumHandler) UpdateMyProfileCT(w http.ResponseWriter, r *http.Request) {
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	memberToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return
	}
	var req struct {
		NameCT string `json:"name_ct"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	nameCT, err := decodeBase64(req.NameCT)
	if err != nil || len(nameCT) == 0 {
		apierr.Write(w, r, apierr.Validation("name_ct must be base64-encoded ciphertext"))
		return
	}
	if err := h.albumService.UpdateMemberNameCT(r.Context(), albumID, memberToken, nameCT); err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update name_ct").WithCause(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// it handles DELETE /albums/{id}/members/{member_token}. It is
// both the admin kick and the self leave endpoint : the service decides which
// by comparing the caller's token to the target. On success it emits
// e2ee.member_revoked to the album's remaining members AND to the removed
// member specifically (they have already dropped out of the active set, so a
// plain album broadcast would miss them and they'd only learn via a later 403)
// The removal is committed before the notify : a fanout failure never leaves a
// member un revoked
func (h *AlbumHandler) RemoveAlbumMember(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	targetToken, err := decodeMemberTokenPath(mux.Vars(r)["token"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid member_token in path").WithCause(err))
		return
	}

	res, err := h.albumService.RemoveMember(r.Context(), albumID, userID, targetToken)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrLastAdmin):
			apierr.Write(w, r, apierr.Forbidden("cannot remove the last remaining admin; delete the album instead"))
		case errors.Is(err, service.ErrMemberNotFound):
			apierr.Write(w, r, apierr.NotFound("no such member in this album"))
		case errors.Is(err, service.ErrCallerRevoked):
			apierr.Write(w, r, apierr.MemberRevoked("your access to this album has been revoked"))
		case errors.Is(err, service.ErrUnauthorized):
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can remove another member"))
		default:
			apierr.Write(w, r, apierr.Internal("failed to remove member").WithCause(err))
		}
		return
	}

	if !res.AlreadyRevoked {
		h.notifyRevoked(r.Context(), albumID, targetToken)
	}
	w.WriteHeader(http.StatusNoContent)
}

// it emits e2ee.member_revoked to the removed member plus every
// still active member of the album , any lookup/emit failure is
// swallowed (the revoke already committed, clients also self heal on their next
// 403). Runs synchronously : member removal is rare and clients wipe on receipt,
// so prompt delivery matters more than shaving the response
func (h *AlbumHandler) notifyRevoked(ctx context.Context, albumID uuid.UUID, removedToken []byte) {
	if h.notifier == nil || h.resolver == nil {
		return
	}
	tokens := [][]byte{removedToken}
	if members, err := h.albumService.ListMembers(ctx, albumID); err == nil {
		for _, m := range members {
			if !m.Revoked {
				tokens = append(tokens, m.MemberToken)
			}
		}
	}
	users, err := h.resolver.UserIDsByMemberTokens(ctx, tokens)
	if err != nil || len(users) == 0 {
		return
	}
	_ = h.notifier.EmitToUsers(ctx, users, ws.EventMemberRevoked, map[string]any{
		"album_id":     albumID.String(),
		"member_token": base64.StdEncoding.EncodeToString(removedToken),
	})
}
