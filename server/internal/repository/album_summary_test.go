package repository_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/repository"
	"github.com/freytastic/keepsy/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Uses a real database because album list authorization lives in the query
func openDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dbURL := os.Getenv("KEEPSY_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set KEEPSY_TEST_DATABASE_URL to run real-DB summary tests")
	}
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

type summaryEnv struct {
	pool  *pgxpool.Pool
	repo  *repository.AlbumRepository
	media *repository.MediaRepository
}

func newSummaryEnv(t *testing.T) *summaryEnv {
	t.Helper()
	pool := openDB(t)
	linker, err := userlink.New(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	return &summaryEnv{
		pool:  pool,
		repo:  repository.NewAlbumRepository(pool, linker),
		media: repository.NewMediaRepository(pool),
	}
}

func (e *summaryEnv) seedUser(t *testing.T) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO users (id, email_hmac, keepsy_id, ik_pub, lk_pub, spk_pub, spk_sig, spk_ts)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		id, []byte(fmt.Sprintf("summary-%s@example.com", id)), id.String(),
		make([]byte, 32), make([]byte, 32), make([]byte, 32), make([]byte, 64),
		time.Now().Unix(),
	); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	t.Cleanup(func() {
		_, _ = e.pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, id)
	})
	return id
}

func (e *summaryEnv) addPhoto(t *testing.T, albumID uuid.UUID, uploader []byte, withThumb bool) int64 {
	t.Helper()
	_, gen := e.addPhotoID(t, albumID, uploader, withThumb)
	return gen
}

func (e *summaryEnv) addPhotoID(t *testing.T, albumID uuid.UUID, uploader []byte, withThumb bool) (uuid.UUID, int64) {
	t.Helper()
	ctx := context.Background()
	id := uuid.New()
	nonce := make([]byte, 12)
	tag := make([]byte, 48)
	sha := make([]byte, 32)
	_, _ = rand.Read(sha)

	var thumbNonce, thumbTag, thumbSHA []byte
	var thumbSize *int64
	var thumbKey *string
	if withThumb {
		thumbNonce, thumbTag, thumbSHA = make([]byte, 12), make([]byte, 48), make([]byte, 32)
		size := int64(2048)
		thumbSize = &size
		k := "thumb/" + id.String()
		thumbKey = &k
	}

	if _, err := e.pool.Exec(ctx,
		`INSERT INTO media (id, album_id, uploader_token, storage_key, thumb_key,
		   wrap_nonce, wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type,
		   confirmed, thumb_wrap_nonce, thumb_wrap_tag_ct, thumb_size, thumb_sha256)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,0,4096,$8,'photo',FALSE,$9,$10,$11,$12)`,
		id, albumID, uploader, "blob/"+id.String(), thumbKey,
		nonce, tag, sha, thumbNonce, thumbTag, thumbSize, thumbSHA,
	); err != nil {
		t.Fatalf("insert media: %v", err)
	}
	gen, err := e.media.MarkConfirmed(ctx, id, albumID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	return id, gen
}

func TestListForUser_ScopesSummaryToMembership(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	stranger := env.seedUser(t)

	album, ownerToken, err := env.repo.CreateWithAdmin(ctx, []byte("mine"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	env.addPhoto(t, album.ID, ownerToken, true)

	mine, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list owner: %v", err)
	}
	if len(mine) != 1 {
		t.Fatalf("owner should see 1 album, got %d", len(mine))
	}
	if mine[0].Summary.MediaCount != 1 {
		t.Errorf("media_count = %d, want 1", mine[0].Summary.MediaCount)
	}
	if len(mine[0].Summary.PreviewMedia) != 1 {
		t.Errorf("preview_media = %d, want 1", len(mine[0].Summary.PreviewMedia))
	}

	theirs, err := env.repo.ListForUser(ctx, stranger)
	if err != nil {
		t.Fatalf("list stranger: %v", err)
	}
	for _, a := range theirs {
		if a.ID == album.ID {
			t.Fatal("stranger received an album they are not a member of")
		}
	}
}

func TestListForUser_ExcludesUnconfirmedAndThumbless(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("counts"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	env.addPhoto(t, album.ID, token, true)
	env.addPhoto(t, album.ID, token, false) // a video-like row, no thumb

	if _, err := env.pool.Exec(ctx,
		`INSERT INTO media (id, album_id, uploader_token, storage_key, wrap_nonce,
		   wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, confirmed)
		 VALUES ($1,$2,$3,'pending',$4,$5,0,1,$6,'photo',FALSE)`,
		uuid.New(), album.ID, token, make([]byte, 12), make([]byte, 48),
		make([]byte, 32),
	); err != nil {
		t.Fatalf("insert pending: %v", err)
	}

	got, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 album, got %d", len(got))
	}
	if got[0].Summary.MediaCount != 2 {
		t.Errorf("media_count = %d, want 2 confirmed", got[0].Summary.MediaCount)
	}
	if n := len(got[0].Summary.PreviewMedia); n != 1 {
		t.Errorf("preview_media = %d, want 1 (thumbless row skipped)", n)
	}
	if got[0].Summary.LatestActivityAt == nil {
		t.Error("latest_activity_at should be set once media is confirmed")
	}
}

func TestListForUser_EmptyAlbumHasNullActivity(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, _, err := env.repo.CreateWithAdmin(ctx, []byte("empty"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	got, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got[0].Summary.LatestActivityAt != nil {
		t.Error("an album with no confirmed media must report null activity")
	}
	if got[0].Summary.MediaGeneration != 0 {
		t.Errorf("generation = %d, want 0", got[0].Summary.MediaGeneration)
	}
	if got[0].Summary.ActiveMemberCount != 1 {
		t.Errorf("active_member_count = %d, want 1", got[0].Summary.ActiveMemberCount)
	}
}

func TestMarkConfirmed_GenerationIsMonotonicAndIdempotent(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("gen"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	if g := env.addPhoto(t, album.ID, token, true); g != 1 {
		t.Errorf("first confirm = %d, want 1", g)
	}
	second := env.addPhoto(t, album.ID, token, true)
	if second != 2 {
		t.Errorf("second confirm = %d, want 2", second)
	}

	if _, err := env.pool.Exec(ctx,
		`DELETE FROM media WHERE album_id = $1`, album.ID); err != nil {
		t.Fatalf("delete media: %v", err)
	}
	after, err := env.media.MediaGeneration(ctx, album.ID)
	if err != nil {
		t.Fatalf("generation: %v", err)
	}
	if after != second {
		t.Errorf("generation moved on delete: %d, want %d", after, second)
	}
}

func TestMarkConfirmed_ConcurrentDuplicateBumpsOnce(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("race"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	mediaID := uuid.New()
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO media (id, album_id, uploader_token, storage_key, wrap_nonce,
		   wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, confirmed)
		 VALUES ($1,$2,$3,'blob',$4,$5,0,1,$6,'photo',FALSE)`,
		mediaID, album.ID, token, make([]byte, 12), make([]byte, 48),
		make([]byte, 32),
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	const racers = 8
	results := make(chan error, racers)
	for i := 0; i < racers; i++ {
		go func() {
			_, err := env.media.MarkConfirmed(ctx, mediaID, album.ID)
			results <- err
		}()
	}
	winners := 0
	for i := 0; i < racers; i++ {
		if err := <-results; err == nil {
			winners++
		}
	}
	if winners != 1 {
		t.Errorf("%d confirms took the branch, want exactly 1", winners)
	}

	gen, err := env.media.MediaGeneration(ctx, album.ID)
	if err != nil {
		t.Fatalf("generation: %v", err)
	}
	if gen != 1 {
		t.Errorf("generation = %d after a duplicate confirm race, want 1", gen)
	}
}

func TestMemberPreviews_ExcludeRevoked(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, ownerToken, err := env.repo.CreateWithAdmin(ctx, []byte("roster"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	revoked := make([]byte, 32)
	_, _ = rand.Read(revoked)
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id)
		 VALUES ($1,$2,$3,$4)`,
		revoked, revoked, revoked, album.ID); err != nil {
		t.Fatalf("seed identity: %v", err)
	}
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_members (album_id, member_token, role, revoked_at)
		 VALUES ($1,$2,'member', now())`, album.ID, revoked); err != nil {
		t.Fatalf("seed revoked member: %v", err)
	}

	got, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got[0].Summary.ActiveMemberCount != 1 {
		t.Errorf("active_member_count = %d, want 1", got[0].Summary.ActiveMemberCount)
	}
	for _, m := range got[0].Summary.MemberPreviews {
		if bytes.Equal(m.MemberToken, revoked) {
			t.Fatal("a revoked member appeared in member_previews")
		}
	}
	if len(got[0].Summary.MemberPreviews) != 1 {
		t.Errorf("member_previews = %d, want 1", len(got[0].Summary.MemberPreviews))
	}
	if !bytes.Equal(got[0].Summary.MemberPreviews[0].MemberToken, ownerToken) {
		t.Error("member_previews did not carry the surviving member")
	}
}

func TestListForUser_OrdersWithinTheSameHour(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	ids := make([]uuid.UUID, 0, 3)
	for i := 0; i < 3; i++ {
		album, token, err := env.repo.CreateWithAdmin(
			ctx, []byte(fmt.Sprintf("album %d", i)), owner)
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		id := album.ID
		t.Cleanup(func() {
			_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, id)
		})
		env.addPhoto(t, album.ID, token, true)
		ids = append(ids, album.ID)
	}

	got, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 albums, got %d", len(got))
	}

	for i, want := range []uuid.UUID{ids[2], ids[1], ids[0]} {
		if got[i].ID != want {
			t.Fatalf("position %d = %s, want %s (most recently filled first)",
				i, got[i].ID, want)
		}
	}
}

func TestGetByID_CarriesTheRowsOwnGeneration(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("seq"), owner)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})

	mine, mineGen := env.addPhotoID(t, album.ID, token, true)
	env.addPhoto(t, album.ID, token, true)
	env.addPhoto(t, album.ID, token, true)

	row, err := env.media.GetByID(ctx, mine, album.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.AlbumSeq == nil {
		t.Fatal("confirmed row has no album_seq")
	}
	if *row.AlbumSeq != mineGen {
		t.Errorf("album_seq = %d, want %d", *row.AlbumSeq, mineGen)
	}

	current, err := env.media.MediaGeneration(ctx, album.ID)
	if err != nil {
		t.Fatalf("generation: %v", err)
	}
	if current == *row.AlbumSeq {
		t.Fatal("album has not moved past this row, test proves nothing")
	}
}

func TestListForUser_OrdersEmptyAlbumsByCreation(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()

	owner := env.seedUser(t)
	ids := make([]uuid.UUID, 0, 3)
	for i := 0; i < 3; i++ {
		album, _, err := env.repo.CreateWithAdmin(
			ctx, []byte(fmt.Sprintf("empty %d", i)), owner)
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		id := album.ID
		t.Cleanup(func() {
			_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, id)
		})
		ids = append(ids, album.ID)
	}

	got, err := env.repo.ListForUser(ctx, owner)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 albums, got %d", len(got))
	}
	for i, want := range []uuid.UUID{ids[2], ids[1], ids[0]} {
		if got[i].ID != want {
			t.Fatalf("position %d = %s, want %s (newest first)", i, got[i].ID, want)
		}
	}
}
