package handler

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type AlbumHandler struct {
	albumService *service.AlbumService
}

func NewAlbumHandler(s *service.AlbumService) *AlbumHandler {
	return &AlbumHandler{albumService: s}
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
				"ik_pub":     optBase64(m.Profile.IKPub),
				"name":       m.Profile.Name,
				"avatar_key": m.Profile.AvatarKey,
			},
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// RemoveAlbumMember stub , full implementation in p7.1
func (h *AlbumHandler) RemoveAlbumMember(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("member removal not yet implemented"))
}

func (h *AlbumHandler) AddMember(w http.ResponseWriter, r *http.Request) {
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
		UserID uuid.UUID `json:"user_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	token, err := h.albumService.AddMember(r.Context(), albumID, userID, req.UserID)
	if err != nil {
		if errors.Is(err, service.ErrUnauthorized) {
			apierr.Write(w, r, apierr.Forbidden("only admin or co-admin can add members"))
			return
		}
		if errors.Is(err, service.ErrAlbumFull) {
			apierr.Write(w, r, apierr.AlbumFull(err.Error()))
			return
		}
		apierr.Write(w, r, apierr.Internal("failed to add member").WithCause(err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"member_token": base64.StdEncoding.EncodeToString(token),
	})
}
