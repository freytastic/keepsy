package apierr

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEnvelopeShape(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)

	Write(rec, req, Validation("invalid email").WithDetail(map[string]any{
		"field": "email",
	}))

	if got, want := rec.Code, http.StatusBadRequest; got != want {
		t.Fatalf("status = %d, want %d", got, want)
	}
	if got, want := rec.Header().Get("Content-Type"), "application/json; charset=utf-8"; got != want {
		t.Fatalf("content-type = %q, want %q", got, want)
	}

	var body struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Detail  map[string]any `json:"detail"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body.Code != "E_VALIDATION" {
		t.Errorf("code = %q, want E_VALIDATION", body.Code)
	}
	if body.Message != "invalid email" {
		t.Errorf("message = %q, want %q", body.Message, "invalid email")
	}
	if v, _ := body.Detail["field"].(string); v != "email" {
		t.Errorf("detail.field = %v, want %q", body.Detail["field"], "email")
	}
}

func TestWrite_BareErrorBecomesInternal(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)

	Write(rec, req, errors.New("postgres: connection refused"))

	if got := rec.Code; got != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", got)
	}
	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "E_INTERNAL" {
		t.Errorf("code = %q, want E_INTERNAL", body.Code)
	}
	// Verify internal cause does not leak.
	if body.Message == "postgres: connection refused" {
		t.Errorf("internal cause leaked into response body: %q", body.Message)
	}
}

func TestIsCode(t *testing.T) {
	err := AlbumFull("at limit")
	if !IsCode(err, "E_ALBUM_FULL") {
		t.Errorf("IsCode(album-full, E_ALBUM_FULL) = false")
	}
	if IsCode(err, "E_VALIDATION") {
		t.Errorf("IsCode(album-full, E_VALIDATION) = true")
	}
	if IsCode(nil, "E_ALBUM_FULL") {
		t.Errorf("IsCode(nil, ...) = true")
	}
	if IsCode(errors.New("x"), "E_INTERNAL") {
		t.Errorf("IsCode(bare-error, E_INTERNAL) = true")
	}
}

func TestWith_DoesNotMutateTemplate(t *testing.T) {
	a := Validation("first").WithDetail(map[string]any{"k": 1})
	b := Validation("second").WithDetail(map[string]any{"k": 2})
	if a.Detail["k"] == b.Detail["k"] {
		t.Errorf("Validation() shares state across calls; got a=%v b=%v", a.Detail, b.Detail)
	}
	if a.Message == b.Message {
		t.Errorf("Validation() shares message across calls")
	}
}

func TestEveryCodeHasUniqueMapping(t *testing.T) {
	codes := map[string]int{
		"E_VALIDATION":           Validation("").HTTPStatus,
		"E_AUTH":                 Auth("").HTTPStatus,
		"E_FORBIDDEN":            Forbidden("").HTTPStatus,
		"E_NOT_MEMBER":           NotMember("").HTTPStatus,
		"E_MEMBER_REVOKED":       MemberRevoked("").HTTPStatus,
		"E_NOT_FOUND":            NotFound("").HTTPStatus,
		"E_CONFLICT":             Conflict("").HTTPStatus,
		"E_ALBUM_FULL":           AlbumFull("").HTTPStatus,
		"E_OPK_EXHAUSTED":        OPKExhausted("").HTTPStatus,
		"E_EPOCH_REPLAY":         EpochReplay("").HTTPStatus,
		"E_MEMBER_SET_DRIFT":     MemberSetDrift("").HTTPStatus,
		"E_INVITE_EXPIRED":       InviteExpired("").HTTPStatus,
		"E_INVITE_CONSUMED":      InviteConsumed("").HTTPStatus,
		"E_SIG_INVALID":          SigInvalid("").HTTPStatus,
		"E_MANIFEST_TAMPER":      ManifestTamper("").HTTPStatus,
		"E_RATE_LIMITED":         RateLimited("").HTTPStatus,
		"E_TS_SKEW":              TsSkew("").HTTPStatus,
		"E_TS_NOT_MONOTONIC":     TsNotMonotonic("").HTTPStatus,
		"E_IDENTITY_ALREADY_SET": IdentityAlreadySet("").HTTPStatus,
		"E_IDENTITY_NOT_SET":     IdentityNotSet("").HTTPStatus,
		"E_OPK_INDEX_TAKEN":      OPKIndexTaken("").HTTPStatus,
		"E_INTERNAL":             Internal("").HTTPStatus,
		"E_NOT_IMPLEMENTED":      NotImplemented("").HTTPStatus,
	}
	expected := map[string]int{
		"E_VALIDATION":           400,
		"E_AUTH":                 401,
		"E_FORBIDDEN":            403,
		"E_NOT_MEMBER":           403,
		"E_MEMBER_REVOKED":       403,
		"E_NOT_FOUND":            404,
		"E_CONFLICT":             409,
		"E_ALBUM_FULL":           409,
		"E_OPK_EXHAUSTED":        409,
		"E_EPOCH_REPLAY":         409,
		"E_MEMBER_SET_DRIFT":     409,
		"E_INVITE_EXPIRED":       410,
		"E_INVITE_CONSUMED":      410,
		"E_SIG_INVALID":          400,
		"E_MANIFEST_TAMPER":      400,
		"E_RATE_LIMITED":         429,
		"E_TS_SKEW":              400,
		"E_TS_NOT_MONOTONIC":     409,
		"E_IDENTITY_ALREADY_SET": 409,
		"E_IDENTITY_NOT_SET":     409,
		"E_OPK_INDEX_TAKEN":      409,
		"E_INTERNAL":             500,
		"E_NOT_IMPLEMENTED":      501,
	}
	for code, want := range expected {
		if got := codes[code]; got != want {
			t.Errorf("%s -> http %d, want %d", code, got, want)
		}
	}
}
