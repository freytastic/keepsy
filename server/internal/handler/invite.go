package handler

import (
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
)

// Invite handlers are in P0.2 (acc to implementation plan)
// Existing user X3DH MK delivery lands in P6.1 , new user invite-blob + deep
// link lands in P6.2, join_complete receipts in P6.3. All against the new
// invite_blobs / invite_links schema with signer_token + Ed25519 signatures.

type InviteHandler struct{}

func NewInviteHandler() *InviteHandler { return &InviteHandler{} }

func (h *InviteHandler) CreateInvite(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite creation lands in P6.2"))
}

func (h *InviteHandler) GetPreview(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite preview lands in P6.2"))
}

func (h *InviteHandler) JoinAlbum(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("join via invite lands in P6.2"))
}

func (h *InviteHandler) CreateInviteBlob(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite blob creation lands in P6.2"))
}

func (h *InviteHandler) GetInviteBlob(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite blob fetch lands in P6.2"))
}
