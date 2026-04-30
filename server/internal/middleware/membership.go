package middleware

import (
	"context"
	"errors"
	"net/http"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type memberCtxKey string

const (
	memberTokenKey memberCtxKey = "member_token"
	memberRoleKey  memberCtxKey = "member_role"
)

type MemberLookup interface {
	LookupMember(ctx context.Context, userID, albumID uuid.UUID) (token []byte, role string, err error)
}

func RequireMember(lookup MemberLookup, albumIDPathVar string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if lookup == nil {
				apierr.Write(w, r, apierr.NotImplemented("album member resolution not wired"))
				return
			}
			userID, ok := GetUserID(r.Context())
			if !ok {
				apierr.Write(w, r, apierr.Auth("authentication required"))
				return
			}
			raw, ok := getPathVar(r, albumIDPathVar)
			if !ok {
				apierr.Write(w, r, apierr.Validation("missing album id in path: "+albumIDPathVar))
				return
			}
			albumID, err := uuid.Parse(raw)
			if err != nil {
				apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
				return
			}

			token, role, err := lookup.LookupMember(r.Context(), userID, albumID)
			if err != nil {
				switch {
				case errors.Is(err, repository.ErrMemberNotFound):
					apierr.Write(w, r, apierr.NotMember("not a member of this album"))
				case errors.Is(err, repository.ErrMemberRevoked):
					apierr.Write(w, r, apierr.MemberRevoked("your access to this album has been revoked"))
				default:
					apierr.Write(w, r, apierr.Internal("member lookup failed").WithCause(err))
				}
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
