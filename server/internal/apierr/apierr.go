package apierr

import (
	"errors"
	"fmt"
	"net/http"
)

type APIError struct {
	Code       string         `json:"code"`
	Message    string         `json:"message"`
	Detail     map[string]any `json:"detail,omitempty"`
	HTTPStatus int            `json:"-"`
	Cause      error          `json:"-"`
}

func (e *APIError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.Cause)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *APIError) Unwrap() error { return e.Cause }

func (e *APIError) WithCause(cause error) *APIError {
	cp := *e
	cp.Cause = cause
	return &cp
}

func (e *APIError) WithDetail(d map[string]any) *APIError {
	cp := *e
	cp.Detail = d
	return &cp
}

func (e *APIError) WithMessage(msg string) *APIError {
	cp := *e
	cp.Message = msg
	return &cp
}

func IsCode(err error, code string) bool {
	var ae *APIError
	if !errors.As(err, &ae) {
		return false
	}
	return ae.Code == code
}

func Validation(message string) *APIError {
	return &APIError{Code: "E_VALIDATION", HTTPStatus: http.StatusBadRequest, Message: message}
}

func Auth(message string) *APIError {
	return &APIError{Code: "E_AUTH", HTTPStatus: http.StatusUnauthorized, Message: message}
}

func Forbidden(message string) *APIError {
	return &APIError{Code: "E_FORBIDDEN", HTTPStatus: http.StatusForbidden, Message: message}
}

func NotMember(message string) *APIError {
	return &APIError{Code: "E_NOT_MEMBER", HTTPStatus: http.StatusForbidden, Message: message}
}

func MemberRevoked(message string) *APIError {
	return &APIError{Code: "E_MEMBER_REVOKED", HTTPStatus: http.StatusForbidden, Message: message}
}

func NotFound(message string) *APIError {
	return &APIError{Code: "E_NOT_FOUND", HTTPStatus: http.StatusNotFound, Message: message}
}

func Conflict(message string) *APIError {
	return &APIError{Code: "E_CONFLICT", HTTPStatus: http.StatusConflict, Message: message}
}

func AlbumFull(message string) *APIError {
	return &APIError{Code: "E_ALBUM_FULL", HTTPStatus: http.StatusConflict, Message: message}
}

func OPKExhausted(message string) *APIError {
	return &APIError{Code: "E_OPK_EXHAUSTED", HTTPStatus: http.StatusConflict, Message: message}
}

func EpochReplay(message string) *APIError {
	return &APIError{Code: "E_EPOCH_REPLAY", HTTPStatus: http.StatusConflict, Message: message}
}

func MemberSetDrift(message string) *APIError {
	return &APIError{Code: "E_MEMBER_SET_DRIFT", HTTPStatus: http.StatusConflict, Message: message}
}

func InviteExpired(message string) *APIError {
	return &APIError{Code: "E_INVITE_EXPIRED", HTTPStatus: http.StatusGone, Message: message}
}

func InviteConsumed(message string) *APIError {
	return &APIError{Code: "E_INVITE_CONSUMED", HTTPStatus: http.StatusGone, Message: message}
}

func SigInvalid(message string) *APIError {
	return &APIError{Code: "E_SIG_INVALID", HTTPStatus: http.StatusBadRequest, Message: message}
}

func ManifestTamper(message string) *APIError {
	return &APIError{Code: "E_MANIFEST_TAMPER", HTTPStatus: http.StatusBadRequest, Message: message}
}

func RateLimited(message string) *APIError {
	return &APIError{Code: "E_RATE_LIMITED", HTTPStatus: http.StatusTooManyRequests, Message: message}
}

func TsSkew(message string) *APIError {
	return &APIError{Code: "E_TS_SKEW", HTTPStatus: http.StatusBadRequest, Message: message}
}

func TsNotMonotonic(message string) *APIError {
	return &APIError{Code: "E_TS_NOT_MONOTONIC", HTTPStatus: http.StatusConflict, Message: message}
}

func IdentityAlreadySet(message string) *APIError {
	return &APIError{Code: "E_IDENTITY_ALREADY_SET", HTTPStatus: http.StatusConflict, Message: message}
}

func IdentityNotSet(message string) *APIError {
	return &APIError{Code: "E_IDENTITY_NOT_SET", HTTPStatus: http.StatusConflict, Message: message}
}

func OPKIndexTaken(message string) *APIError {
	return &APIError{Code: "E_OPK_INDEX_TAKEN", HTTPStatus: http.StatusConflict, Message: message}
}

func Internal(message string) *APIError {
	return &APIError{Code: "E_INTERNAL", HTTPStatus: http.StatusInternalServerError, Message: message}
}

func NotImplemented(message string) *APIError {
	return &APIError{Code: "E_NOT_IMPLEMENTED", HTTPStatus: http.StatusNotImplemented, Message: message}
}
