package middleware

import (
	"context"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/gorilla/mux"
)

type memberCtxKey string

const (
	memberTokenKey memberCtxKey = "member_token"
	memberRoleKey  memberCtxKey = "member_role"
)

type MemberLookup interface {
	GetByUserAndAlbum(ctx context.Context, userID []byte, albumID string) (token []byte, role string, err error)
}

var (
	ErrNotMember = apierr.NotMember("not a member of this album")
	ErrRevoked   = apierr.MemberRevoked("your access to this album has been revoked")
)

// RequireMember gates album scoped routes and injects member_token + role into context
func RequireMember(lookup MemberLookup, albumIDPathVar string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if lookup == nil {
				apierr.Write(w, r, apierr.NotImplemented(
					"album member resolution is not wired yet"))
				return
			}

			userID, ok := GetUserID(r.Context())
			if !ok {
				apierr.Write(w, r, apierr.Auth("authentication required"))
				return
			}

			albumID, ok := getPathVar(r, albumIDPathVar)
			if !ok {
				apierr.Write(w, r, apierr.Validation(
					"missing album id in path: "+albumIDPathVar))
				return
			}

			token, role, err := lookup.GetByUserAndAlbum(r.Context(), userID[:], albumID)
			if err != nil {
				apierr.Write(w, r, err)
				return
			}

			ctx := context.WithValue(r.Context(), memberTokenKey, token)
			ctx = context.WithValue(ctx, memberRoleKey, role)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func MustGetMemberToken(r *http.Request) ([]byte, bool) {
	v, ok := r.Context().Value(memberTokenKey).([]byte)
	return v, ok
}

func MustGetMemberRole(r *http.Request) (string, bool) {
	v, ok := r.Context().Value(memberRoleKey).(string)
	return v, ok
}

var getPathVar = func(r *http.Request, name string) (string, bool) {
	v, ok := mux.Vars(r)[name]
	return v, ok && v != ""
}
