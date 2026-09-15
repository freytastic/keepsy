package handler

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/middleware"
	"github.com/freytastic/keepsy/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type accountDeleter interface {
	Preflight(ctx context.Context, userID uuid.UUID) ([]service.DeletionAlbum, error)
	Request(ctx context.Context, userID uuid.UUID, confirmedShared []uuid.UUID, receipt []byte) error
	ReceiptAccepted(ctx context.Context, receipt []byte) (bool, error)
	AbandonReceipt(ctx context.Context, receipt []byte) (bool, error)
}

type AccountHandler struct {
	deletions accountDeleter
}

func NewAccountHandler(d accountDeleter) *AccountHandler {
	return &AccountHandler{deletions: d}
}

// DeletionPreflight handles GET /users/me/deletion
func (h *AccountHandler) DeletionPreflight(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	albums, err := h.deletions.Preflight(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	out := make([]map[string]any, len(albums))
	for i, a := range albums {
		out[i] = map[string]any{
			"album_id":            a.AlbumID,
			"role":                a.Role,
			"active_member_count": a.ActiveMemberCount,
			"own_media_count":     a.OwnMediaCount,
			"outcome":             a.Outcome,
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"albums": out})
}

// RequestDeletion handles POST /users/me/deletion. The body names every shared
// album the user saw and agreed to delete for everyone
func (h *AccountHandler) RequestDeletion(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req struct {
		DeleteSharedAlbumIDs []uuid.UUID `json:"delete_shared_album_ids"`
		Receipt              string      `json:"receipt"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	receipt, err := base64.RawURLEncoding.DecodeString(req.Receipt)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("receipt must be base64url").WithCause(err))
		return
	}
	if err := h.deletions.Request(r.Context(), userID, req.DeleteSharedAlbumIDs, receipt); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// DeletionReceipt handles GET /account-deletions/{receipt}. Unauthenticated
// because acceptance removed the sessions that could have asked
func (h *AccountHandler) DeletionReceipt(w http.ResponseWriter, r *http.Request) {
	receipt, err := base64.RawURLEncoding.DecodeString(mux.Vars(r)["receipt"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("receipt must be base64url").WithCause(err))
		return
	}
	ok, err := h.deletions.ReceiptAccepted(r.Context(), receipt)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if !ok {
		apierr.Write(w, r, apierr.NotFound("no accepted deletion carries this receipt"))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// AbandonDeletion handles POST /account-deletions/{receipt}/abandon. The device
// keeps the account only on 204. On E_DELETION_ACCEPTED it must still wipe
func (h *AccountHandler) AbandonDeletion(w http.ResponseWriter, r *http.Request) {
	receipt, err := base64.RawURLEncoding.DecodeString(mux.Vars(r)["receipt"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("receipt must be base64url").WithCause(err))
		return
	}
	accepted, err := h.deletions.AbandonReceipt(r.Context(), receipt)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	if accepted {
		apierr.Write(w, r, apierr.DeletionAccepted("this deletion was already accepted"))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
