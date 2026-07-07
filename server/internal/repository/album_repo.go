package repository

import (
	"context"
	"crypto/rand"
	"errors"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrAlbumNotFound  = errors.New("album not found")
	ErrMemberNotFound = errors.New("member not found in album")
	ErrMemberRevoked  = errors.New("member is revoked from album")
	ErrLastAdmin      = errors.New("cannot remove the last remaining admin")
	ErrCallerRevoked  = errors.New("caller was revoked before the operation committed")
)

type AlbumRepository struct {
	DB     *pgxpool.Pool
	linker *userlink.Hasher
}

func NewAlbumRepository(db *pgxpool.Pool, linker *userlink.Hasher) *AlbumRepository {
	if linker == nil {
		panic("AlbumRepository: linker is required (M-bridge)")
	}
	return &AlbumRepository{DB: db, linker: linker}
}

func newMemberToken() ([]byte, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// CreateWithAdmin creates an album, mints a member_token for the creator,
// inserts the identity bridge row, and adds the creator to album_members
// with role='admin' , all in one transaction
func (r *AlbumRepository) CreateWithAdmin(ctx context.Context, nameCT []byte, creatorUserID uuid.UUID) (*model.Album, []byte, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)

	a := &model.Album{ID: uuid.New(), NameCT: nameCT}
	err = tx.QueryRow(ctx,
		`INSERT INTO albums (id, name_ct) VALUES ($1, $2)
		 RETURNING created_at, updated_at`,
		a.ID, a.NameCT,
	).Scan(&a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		return nil, nil, err
	}

	token, err := newMemberToken()
	if err != nil {
		return nil, nil, err
	}
	handle := r.linker.Hash(creatorUserID)
	sealed, err := r.linker.Seal(creatorUserID, token)
	if err != nil {
		return nil, nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id)
		 VALUES ($1, $2, $3, $4)`,
		token, handle, sealed, a.ID)
	if err != nil {
		return nil, nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'admin')`,
		a.ID, token)
	if err != nil {
		return nil, nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	return a, token, nil
}

func (r *AlbumRepository) GetByID(ctx context.Context, id uuid.UUID) (*model.Album, error) {
	var a model.Album
	err := r.DB.QueryRow(ctx,
		`SELECT id, name_ct, created_at, updated_at FROM albums WHERE id = $1`, id,
	).Scan(&a.ID, &a.NameCT, &a.CreatedAt, &a.UpdatedAt)
	if err == pgx.ErrNoRows {
		return nil, ErrAlbumNotFound
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

func (r *AlbumRepository) ListForUser(ctx context.Context, userID uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	rows, err := r.DB.Query(ctx, `
		SELECT a.id, a.name_ct, a.created_at, a.updated_at, am.role, ami.member_token
		FROM albums a
		JOIN album_member_identities ami ON ami.album_id = a.id
		JOIN album_members am ON am.album_id = a.id AND am.member_token = ami.member_token
		WHERE ami.user_handle = $1 AND am.revoked_at IS NULL
		ORDER BY a.updated_at DESC`,
		r.linker.Hash(userID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.AlbumWithMemberInfo
	for rows.Next() {
		var a model.AlbumWithMemberInfo
		if err := rows.Scan(&a.ID, &a.NameCT, &a.CreatedAt, &a.UpdatedAt, &a.UserRole, &a.MemberToken); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

// LookupMember resolves (userID, albumID) → (memberToken, role)
// Returns ErrMemberNotFound if no row, ErrMemberRevoked if revoked_at is set
// Backs middleware.RequireMember per L6
func (r *AlbumRepository) LookupMember(ctx context.Context, userID uuid.UUID, albumID uuid.UUID) ([]byte, string, error) {
	var token []byte
	var role string
	var revoked *string
	err := r.DB.QueryRow(ctx, `
		SELECT ami.member_token, am.role, am.revoked_at::text
		FROM album_member_identities ami
		JOIN album_members am ON am.album_id = ami.album_id AND am.member_token = ami.member_token
		WHERE ami.user_handle = $1 AND ami.album_id = $2`,
		r.linker.Hash(userID), albumID,
	).Scan(&token, &role, &revoked)
	if err == pgx.ErrNoRows {
		return nil, "", ErrMemberNotFound
	}
	if err != nil {
		return nil, "", err
	}
	if revoked != nil {
		return nil, "", ErrMemberRevoked
	}
	return token, role, nil
}

// AddMember mints a member_token for userID in albumID and inserts the bridge
// row and album_members row. Returns the new token.

// TEST FIXTURE ONLY. This is a raw DB insert with NO X3DH MK delivery, so a
// member added this way cannot decrypt anything ("member without keys"). It is
// retained solely to seed realistic roster fixtures in tests. Production member
// onboarding MUST go through the E2EE invite path (internal/e2ee/invite,
// DeliverMember). Do NOT call this from a request handler or service
func (r *AlbumRepository) AddMember(ctx context.Context, albumID, userID uuid.UUID, role string) ([]byte, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	token, err := newMemberToken()
	if err != nil {
		return nil, err
	}
	handle := r.linker.Hash(userID)
	sealed, err := r.linker.Seal(userID, token)
	if err != nil {
		return nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
		token, handle, sealed, albumID)
	if err != nil {
		return nil, err
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, $3)`,
		albumID, token, role)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return token, nil
}

func (r *AlbumRepository) ListMembers(ctx context.Context, albumID uuid.UUID) ([]model.MemberWithProfile, error) {
	// Two pass : the old single query joined users via ami.user_id, but
	// user_id is sealed in amid.user_id_enc post M-bridge. Pass 1 reads the
	// album rows + sealed blobs : pass 2 bulk fetches IK/LK for the decoded
	// user_ids. name_ct may be NULL until the member publishes their
	// encrypted display name (M7)
	rows, err := r.DB.Query(ctx, `
		SELECT
			am.member_token,
			am.role,
			am.revoked_at IS NOT NULL,
			ami.joined_at,
			ami.user_id_enc,
			am.name_ct
		FROM album_members am
		JOIN album_member_identities ami ON ami.member_token = am.member_token
		WHERE am.album_id = $1
		ORDER BY ami.joined_at ASC`,
		albumID)
	if err != nil {
		return nil, err
	}
	type pending struct {
		idx    int
		userID uuid.UUID
	}
	var members []model.MemberWithProfile
	var pendings []pending
	for rows.Next() {
		var m model.MemberWithProfile
		var sealed []byte
		if err := rows.Scan(
			&m.MemberToken,
			&m.Role,
			&m.Revoked,
			&m.JoinedAt,
			&sealed,
			&m.Profile.NameCT,
		); err != nil {
			rows.Close()
			return nil, err
		}
		userID, err := r.linker.Open(sealed, m.MemberToken)
		if err != nil {
			// A row whose seal cant be opened is unreadable for IK/LK lookup :
			// skip it rather than 500 on the whole list (matches the silent
			// skip in epoch.UserIDsByMemberTokens)
			continue
		}
		pendings = append(pendings, pending{idx: len(members), userID: userID})
		members = append(members, m)
	}
	rows.Close()
	if len(members) == 0 {
		return members, nil
	}

	ids := make([]uuid.UUID, len(pendings))
	for i, p := range pendings {
		ids[i] = p.userID
	}
	pubRows, err := r.DB.Query(ctx,
		`SELECT id, ik_pub, lk_pub FROM users WHERE id = ANY($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer pubRows.Close()
	pubs := make(map[uuid.UUID]struct{ IK, LK []byte }, len(ids))
	for pubRows.Next() {
		var id uuid.UUID
		var ik, lk []byte
		if err := pubRows.Scan(&id, &ik, &lk); err != nil {
			return nil, err
		}
		pubs[id] = struct{ IK, LK []byte }{ik, lk}
	}
	for _, p := range pendings {
		if pk, ok := pubs[p.userID]; ok {
			members[p.idx].Profile.IKPub = pk.IK
			members[p.idx].Profile.LKPub = pk.LK
		}
	}
	return members, nil
}

// UpdateMemberNameCT writes the caller's encrypted display name for one album
// Caller must already be a member (RequireMember middleware enforces). Bytes
// are opaque to the server : it stores the wrap, never decrypts
func (r *AlbumRepository) UpdateMemberNameCT(ctx context.Context, albumID uuid.UUID, memberToken, nameCT []byte) error {
	_, err := r.DB.Exec(ctx,
		`UPDATE album_members SET name_ct = $1 WHERE album_id = $2 AND member_token = $3`,
		nameCT, albumID, memberToken,
	)
	return err
}

// It atomically revokes a member. takes the same albums row
// FOR UPDATE lock that epoch rotation (InsertEpoch) takes, so revoke, rotate,
// and upload reserve all serialize on one album : this is what stops two
// concurrent admin removals from both passing the last admin guard and leaving
// the album adminless, and stops a revoke from interleaving with a rotation's
// active set snapshot

// The caller is re checked under the lock too: revoked_at is the only authz
// input that can change between the service's auth check and this commit (a
// concurrent removal could revoke the caller), so re reading it here closes
// that TOCTOU. The caller's role is NOT re read because roles are immutable
// (there is no promotion/demotion flow) : if that changes, re check role here

// Returns the target's role, whether it was already revoked (idempotent no-op),
// ErrCallerRevoked, ErrMemberNotFound, ErrAlbumNotFound, or ErrLastAdmin
func (r *AlbumRepository) RevokeMemberTx(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (string, bool, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback(ctx)

	var locked uuid.UUID
	err = tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, albumID).Scan(&locked)
	if err == pgx.ErrNoRows {
		return "", false, ErrAlbumNotFound
	}
	if err != nil {
		return "", false, err
	}

	// Caller must still be an active member at commit time
	var callerRevoked bool
	err = tx.QueryRow(ctx,
		`SELECT revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, callerToken,
	).Scan(&callerRevoked)
	if err == pgx.ErrNoRows {
		return "", false, ErrCallerRevoked
	}
	if err != nil {
		return "", false, err
	}
	if callerRevoked {
		return "", false, ErrCallerRevoked
	}

	var role string
	var revoked bool
	err = tx.QueryRow(ctx,
		`SELECT role, revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, targetToken,
	).Scan(&role, &revoked)
	if err == pgx.ErrNoRows {
		return "", false, ErrMemberNotFound
	}
	if err != nil {
		return "", false, err
	}
	if revoked {
		// idempotent : nothing to do, but commit to release the lock cleanly
		if err := tx.Commit(ctx); err != nil {
			return "", false, err
		}
		return role, true, nil
	}

	if role == "admin" {
		var n int
		if err := tx.QueryRow(ctx,
			`SELECT COUNT(*) FROM album_members
			 WHERE album_id = $1 AND role = 'admin' AND revoked_at IS NULL`,
			albumID,
		).Scan(&n); err != nil {
			return "", false, err
		}
		if n <= 1 {
			return role, false, ErrLastAdmin
		}
	}

	if _, err := tx.Exec(ctx,
		`UPDATE album_members SET revoked_at = NOW()
		 WHERE album_id = $1 AND member_token = $2 AND revoked_at IS NULL`,
		albumID, targetToken,
	); err != nil {
		return "", false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", false, err
	}
	return role, false, nil
}

func (r *AlbumRepository) UpdateName(ctx context.Context, albumID uuid.UUID, nameCT []byte) error {
	_, err := r.DB.Exec(ctx,
		`UPDATE albums SET name_ct = $1, updated_at = NOW() WHERE id = $2`,
		nameCT, albumID)
	return err
}

func (r *AlbumRepository) Delete(ctx context.Context, id uuid.UUID) error {
	_, err := r.DB.Exec(ctx, `DELETE FROM albums WHERE id = $1`, id)
	return err
}
