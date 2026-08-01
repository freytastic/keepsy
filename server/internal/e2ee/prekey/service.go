package prekey

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/crypto"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

// tsSkewWindow caps |now - claimed_ts| for both bootstrap and rotate
const tsSkewWindow = 5 * time.Minute

// opkBatchMax bounds POST /users/me/opks (sanity, prevents giant batches)
const opkBatchMax = 100

// opkLowThreshold drives the e2ee.opk_low fan out. A peer fetch that drops
// the target's unconsumed count below this threshold queues an emit
const opkLowThreshold = 5

// store is the repo surface the service depends on. Concrete impl is *Repo
// tests substitute a mock to exercise pure validation paths
type store interface {
	IdentityByID(ctx context.Context, userID uuid.UUID) (*Identity, error)
	PublishOrRefreshIdentity(ctx context.Context, userID uuid.UUID, ikPub, lkPub, spkPub, spkSig []byte, spkTs int64) error
	RotateSPK(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64) error
	CreateBatchAtomic(ctx context.Context, opks []model.OneTimePrekey) error
	PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error)
	Count(ctx context.Context, userID uuid.UUID) (int, error)
}

// Service holds the validation + signaturec verify glue for the §2.2 endpoints
// Notifier is optional : when nil, OPK-low fanouts are dropped silently
type Service struct {
	repo store
	now  func() time.Time
}

func NewService(repo store) *Service {
	return &Service{repo: repo, now: time.Now}
}

// SetClock overrides the wall clock; tests use this to pin ts-skew checks
func (s *Service) SetClock(fn func() time.Time) { s.now = fn }

// UpsertIdentityInput carries the decoded body of PUT /users/me/keys
type UpsertIdentityInput struct {
	IKPub  []byte
	LKPub  []byte
	SPKPub []byte
	SPKSig []byte
	SPKTs  int64
}

// UpsertIdentity validates per spec §4.1 (length → ts-skew → sig → state) and
// writes the row. Returns the spec's *apierr.APIError envelope on failure
func (s *Service) UpsertIdentity(ctx context.Context, userID uuid.UUID, in UpsertIdentityInput) error {
	if len(in.IKPub) != ed25519.PublicKeySize ||
		len(in.LKPub) != 32 ||
		len(in.SPKPub) != 32 {
		return apierr.Validation("ik_pub/lk_pub/spk_pub must be 32 bytes")
	}
	if len(in.SPKSig) != ed25519.SignatureSize {
		return apierr.Validation("spk_sig must be 64 bytes")
	}
	if !withinSkew(s.now(), in.SPKTs, tsSkewWindow) {
		return apierr.TsSkew("spk_ts outside acceptable skew window")
	}
	msg := spkSelfMsg(in.SPKPub, in.SPKTs)
	if err := crypto.VerifyEd25519(ed25519.PublicKey(in.IKPub), msg, in.SPKSig); err != nil {
		return apierr.SigInvalid("spk_sig verification failed").WithCause(err)
	}
	// The repository atomically distinguishes identical retries from conflicts
	err := s.repo.PublishOrRefreshIdentity(ctx, userID, in.IKPub, in.LKPub, in.SPKPub, in.SPKSig, in.SPKTs)
	if errors.Is(err, ErrIdentityConflict) {
		return apierr.IdentityAlreadySet("identity already published; rotate via POST /users/me/spk")
	}
	return err
}

// RotateSPKInput carries the decoded body of POST /users/me/spk
type RotateSPKInput struct {
	SPKPub      []byte
	SPKSig      []byte
	SPKTs       int64
	RotationSig []byte
}

// RotateSPK enforces the spec §4.2 ordering: lengths → ts-skew → state → spk_sig
// → rotation_sig → monotonic ts. Audit row written in the same txn as the users update
func (s *Service) RotateSPK(ctx context.Context, userID uuid.UUID, in RotateSPKInput) error {
	if len(in.SPKPub) != 32 {
		return apierr.Validation("spk_pub must be 32 bytes")
	}
	if len(in.SPKSig) != ed25519.SignatureSize {
		return apierr.Validation("spk_sig must be 64 bytes")
	}
	if len(in.RotationSig) != ed25519.SignatureSize {
		return apierr.Validation("rotation_sig must be 64 bytes")
	}
	if !withinSkew(s.now(), in.SPKTs, tsSkewWindow) {
		return apierr.TsSkew("spk_ts outside acceptable skew window")
	}
	cur, err := s.repo.IdentityByID(ctx, userID)
	if err != nil {
		return err
	}
	if len(cur.IKPub) == 0 {
		return apierr.IdentityNotSet("publish identity via PUT /users/me/keys before rotating")
	}
	ikPub := ed25519.PublicKey(cur.IKPub)
	if err := crypto.VerifyEd25519(ikPub, spkSelfMsg(in.SPKPub, in.SPKTs), in.SPKSig); err != nil {
		return apierr.SigInvalid("spk_sig verification failed").WithCause(err)
	}
	if err := crypto.VerifyEd25519(ikPub, RotationMsg(in.SPKPub, in.SPKTs), in.RotationSig); err != nil {
		return apierr.SigInvalid("rotation_sig verification failed").WithCause(err)
	}
	// Fast fail; the repository repeats this check under the row lock
	if cur.SPKTs != nil && in.SPKTs <= *cur.SPKTs {
		return apierr.TsNotMonotonic("spk_ts must be strictly greater than current spk_ts")
	}
	err = s.repo.RotateSPK(ctx, userID, in.SPKPub, in.SPKSig, in.SPKTs)
	if errors.Is(err, ErrTsNotMonotonic) {
		return apierr.TsNotMonotonic("spk_ts must be strictly greater than current spk_ts")
	}
	return err
}

// OwnKeys returns side-effect-free self key state for reconciliation
func (s *Service) OwnKeys(ctx context.Context, userID uuid.UUID) (*Identity, error) {
	return s.repo.IdentityByID(ctx, userID)
}

// OPKUpload mirrors one entry in the POST /users/me/opks request body
type OPKUpload struct {
	Idx    int
	KeyPub []byte
}

// ReplenishOPKsInput carries the decoded body of POST /users/me/opks
type ReplenishOPKsInput struct {
	OPKs         []OPKUpload
	ReplenishSig []byte
}

// ReplenishOPKs validates per spec §4.3 and inserts atomically. ErrOPKIndexTaken
// from the repo is converted to apierr.OPKIndexTaken
func (s *Service) ReplenishOPKs(ctx context.Context, userID uuid.UUID, in ReplenishOPKsInput) error {
	if len(in.OPKs) == 0 {
		return apierr.Validation("opks must be a non-empty array")
	}
	if len(in.OPKs) > opkBatchMax {
		return apierr.Validation("opks batch exceeds 100")
	}
	if len(in.ReplenishSig) != ed25519.SignatureSize {
		return apierr.Validation("replenish_sig must be 64 bytes")
	}
	for _, o := range in.OPKs {
		if o.Idx < 0 {
			return apierr.Validation("opks[].idx must be >= 0")
		}
		if len(o.KeyPub) != 32 {
			return apierr.Validation("opks[].key_pub must be 32 bytes")
		}
	}
	cur, err := s.repo.IdentityByID(ctx, userID)
	if err != nil {
		return err
	}
	if len(cur.IKPub) == 0 {
		return apierr.IdentityNotSet("publish identity via PUT /users/me/keys before uploading OPKs")
	}
	pubs := make([][]byte, len(in.OPKs))
	for i, o := range in.OPKs {
		pubs[i] = o.KeyPub
	}
	if err := crypto.VerifyEd25519(ed25519.PublicKey(cur.IKPub), ReplenishMsg(pubs), in.ReplenishSig); err != nil {
		return apierr.SigInvalid("replenish_sig verification failed").WithCause(err)
	}
	rows := make([]model.OneTimePrekey, len(in.OPKs))
	for i, o := range in.OPKs {
		rows[i] = model.OneTimePrekey{ID: uuid.New(), UserID: userID, OPKIdx: o.Idx, KeyPub: o.KeyPub}
	}
	if err := s.repo.CreateBatchAtomic(ctx, rows); err != nil {
		if errors.Is(err, ErrOPKIndexTaken) {
			return apierr.OPKIndexTaken("one or more opk_idx values already exist for this user")
		}
		return err
	}
	return nil
}

// GetOPKCount returns the unconsumed OPK count for the given user
func (s *Service) GetOPKCount(ctx context.Context, userID uuid.UUID) (int, error) {
	return s.repo.Count(ctx, userID)
}

// PrekeyBundle is the response body for GET /users/{id}/prekey bundle
type PrekeyBundle struct {
	UserID  uuid.UUID
	IKPub   []byte
	LKPub   []byte
	SPKPub  []byte
	SPKSig  []byte
	SPKTs   int64
	OPK     *OPKUpload
	OPKLeft int // unconsumed count after this fetch : -1 when no OPK was popped
}

// GetPrekeyBundle reads the target's identity + pops one OPK. On success returns
// the bundle; the caller is responsible for emitting e2ee.opk_low when OPKLeft < threshold
func (s *Service) GetPrekeyBundle(ctx context.Context, targetID uuid.UUID) (*PrekeyBundle, error) {
	id, err := s.repo.IdentityByID(ctx, targetID)
	if err != nil {
		return nil, err
	}
	if len(id.IKPub) == 0 || len(id.SPKPub) == 0 {
		return nil, apierr.IdentityNotSet("target has not published an identity")
	}
	out := &PrekeyBundle{
		UserID:  targetID,
		IKPub:   id.IKPub,
		LKPub:   id.LKPub,
		SPKPub:  id.SPKPub,
		SPKSig:  id.SPKSig,
		OPKLeft: -1,
	}
	if id.SPKTs != nil {
		out.SPKTs = *id.SPKTs
	}
	opk, err := s.repo.PopRandom(ctx, targetID)
	if err != nil {
		return nil, err
	}
	if opk != nil {
		out.OPK = &OPKUpload{Idx: opk.OPKIdx, KeyPub: opk.KeyPub}
		// post pop count drives the OPK low decision in the handler
		n, err := s.repo.Count(ctx, targetID)
		if err != nil {
			return nil, err
		}
		out.OPKLeft = n
	}
	return out, nil
}

// OPKLowThreshold is the public threshold for fanout decisions
func OPKLowThreshold() int { return opkLowThreshold }

// spkSelfMsg = spk_pub ‖ uint64_be(spk_ts) , used by both bootstrap and rotate
// for the SPK self-signature. Salt prefix is intentionally absent (rotation_sig
// carries its own domain separator)
func spkSelfMsg(spkPub []byte, spkTs int64) []byte {
	out := make([]byte, 0, 32+8)
	out = append(out, spkPub...)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], uint64(spkTs))
	return append(out, ts[:]...)
}

// RotationMsg = ASCII("rotate-spk-v1") ‖ spk_pub ‖ uint64_be(spk_ts)
// Exported so the KAT generator and tests build the same bytes
func RotationMsg(spkPub []byte, spkTs int64) []byte {
	out := make([]byte, 0, len(crypto.SaltSpkRotate)+32+8)
	out = append(out, crypto.SaltSpkRotate...)
	out = append(out, spkPub...)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], uint64(spkTs))
	return append(out, ts[:]...)
}

// ReplenishMsg = ASCII("opk-batch-v1") ‖ uint32_be(len) ‖ SHA256(concat(opk_pubs))
// hash is over the raw 32-byte pubs concatenated in array order
func ReplenishMsg(opkPubs [][]byte) []byte {
	h := sha256.New()
	for _, p := range opkPubs {
		h.Write(p)
	}
	digest := h.Sum(nil)
	prefix := []byte("opk-batch-v1")
	out := make([]byte, 0, len(prefix)+4+len(digest))
	out = append(out, prefix...)
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(opkPubs)))
	out = append(out, n[:]...)
	return append(out, digest...)
}

func withinSkew(now time.Time, ts int64, window time.Duration) bool {
	delta := now.Unix() - ts
	if delta < 0 {
		delta = -delta
	}
	return time.Duration(delta)*time.Second <= window
}
