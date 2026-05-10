package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/freytastic/keepsy/internal/apierr"
	"github.com/freytastic/keepsy/internal/model"
	"github.com/freytastic/keepsy/internal/repository"
	"github.com/google/uuid"
)

// validInput returns a request body that passes every validateUploadInput check
// Tests mutate fields off this baseline to exercise specific failure modes
func validInput() RequestUploadInput {
	return RequestUploadInput{
		MediaID:    uuid.New(),
		BlobSize:   2048,
		BlobSHA256: bytes.Repeat([]byte{0xAB}, 32),
		MimeType:   "image/jpeg",
		MediaType:  "photo",
		WrapNonce:  bytes.Repeat([]byte{0x11}, 12),
		WrapTagCT:  bytes.Repeat([]byte{0x22}, 48),
		EpochTag:   3,
	}
}

type fakeMediaRepo struct {
	rows          map[uuid.UUID]*model.Media
	createCalls   int
	confirmCalls  int
	deletePending int
	deleteCalls   int
	createErr     error
	confirmErr    error
	getErr        error
	deletePendErr error
}

func newFakeMediaRepo() *fakeMediaRepo {
	return &fakeMediaRepo{rows: map[uuid.UUID]*model.Media{}}
}

func (f *fakeMediaRepo) CreatePending(_ context.Context, m *model.Media) error {
	f.createCalls++
	if f.createErr != nil {
		return f.createErr
	}
	if m.ID == uuid.Nil {
		m.ID = uuid.New()
	}
	m.CreatedAt = time.Now()
	cp := *m
	f.rows[m.ID] = &cp
	return nil
}

func (f *fakeMediaRepo) MarkConfirmed(_ context.Context, mediaID, _ uuid.UUID) error {
	f.confirmCalls++
	if f.confirmErr != nil {
		return f.confirmErr
	}
	row, ok := f.rows[mediaID]
	if !ok {
		return repository.ErrMediaNotFound
	}
	row.Confirmed = true
	return nil
}

func (f *fakeMediaRepo) DeletePending(_ context.Context, mediaID, _ uuid.UUID) error {
	f.deletePending++
	if f.deletePendErr != nil {
		return f.deletePendErr
	}
	delete(f.rows, mediaID)
	return nil
}

func (f *fakeMediaRepo) GetByID(_ context.Context, mediaID, _ uuid.UUID) (*model.Media, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	row, ok := f.rows[mediaID]
	if !ok {
		return nil, repository.ErrMediaNotFound
	}
	cp := *row
	return &cp, nil
}

func (f *fakeMediaRepo) ListConfirmed(_ context.Context, _ uuid.UUID) ([]model.Media, error) {
	return nil, nil
}

func (f *fakeMediaRepo) Delete(_ context.Context, mediaID, _ uuid.UUID) error {
	f.deleteCalls++
	delete(f.rows, mediaID)
	return nil
}

type fakeEpochs struct {
	cur    int
	exists bool
	err    error
}

func (f *fakeEpochs) CurrentEpoch(_ context.Context, _ uuid.UUID) (int, bool, time.Time, error) {
	return f.cur, f.exists, time.Time{}, f.err
}

type fakeS3 struct {
	presignErr    error
	headSize      int64
	headSHA256B64 string
	headErr       error
	deleteCalls   int
	deleteKeys    []string
}

func (f *fakeS3) GetPresignedUploadURLWithChecksum(_ context.Context, _, _ string, _ int64, _ string, _ time.Duration) (*PresignedUpload, error) {
	if f.presignErr != nil {
		return nil, f.presignErr
	}
	return &PresignedUpload{URL: "http://s3/upload", RequiredHeader: map[string]string{"x-amz-checksum-sha256": "x"}}, nil
}

func (f *fakeS3) HeadObject(_ context.Context, _ string) (int64, string, error) {
	return f.headSize, f.headSHA256B64, f.headErr
}

func (f *fakeS3) DeleteObject(_ context.Context, key string) error {
	f.deleteCalls++
	f.deleteKeys = append(f.deleteKeys, key)
	return nil
}

func newSvc(epochs *fakeEpochs) (*MediaService, *fakeMediaRepo, *fakeS3) {
	r := newFakeMediaRepo()
	s := &fakeS3{}
	return NewMediaService(r, epochs, s), r, s
}

func TestRequestUploadURL_RejectsBadInputs(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*RequestUploadInput)
		want string
	}{
		{"bad media_type", func(in *RequestUploadInput) { in.MediaType = "audio" }, "media_type"},
		{"zero blob_size", func(in *RequestUploadInput) { in.BlobSize = 0 }, "blob_size"},
		{"short sha256", func(in *RequestUploadInput) { in.BlobSHA256 = bytes.Repeat([]byte{1}, 31) }, "blob_sha256"},
		{"bad wrap_nonce len", func(in *RequestUploadInput) { in.WrapNonce = bytes.Repeat([]byte{1}, 11) }, "wrap_nonce"},
		{"bad wrap_tag_ct len", func(in *RequestUploadInput) { in.WrapTagCT = bytes.Repeat([]byte{1}, 47) }, "wrap_tag_ct"},
		{"negative epoch", func(in *RequestUploadInput) { in.EpochTag = -1 }, "epoch_tag"},
		{"weird mime", func(in *RequestUploadInput) { in.MimeType = "text/plain" }, "mime_type"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
			in := validInput()
			tt.mut(&in)
			_, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, in)
			if !apierr.IsCode(err, "E_VALIDATION") {
				t.Fatalf("err = %v, want E_VALIDATION mentioning %q", err, tt.want)
			}
		})
	}
}

func TestRequestUploadURL_RejectsStaleEpoch(t *testing.T) {
	svc, repo, _ := newSvc(&fakeEpochs{cur: 5, exists: true})
	in := validInput()
	in.EpochTag = 3 // stale
	_, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, in)
	if !apierr.IsCode(err, "E_EPOCH_REPLAY") {
		t.Fatalf("err = %v, want E_EPOCH_REPLAY", err)
	}
	if repo.createCalls != 0 {
		t.Errorf("CreatePending called %d times on stale epoch ; expected 0", repo.createCalls)
	}
}

func TestRequestUploadURL_RejectsAlbumWithNoEpochYet(t *testing.T) {
	svc, _, _ := newSvc(&fakeEpochs{exists: false})
	_, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, validInput())
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestRequestUploadURL_HappyPath(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	res, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, validInput())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if res.UploadURL == "" {
		t.Errorf("UploadURL empty")
	}
	if res.MediaID == uuid.Nil {
		t.Errorf("MediaID nil")
	}
	if len(res.StorageKey) != 32 {
		// hex(16 bytes) = 32 chars
		t.Errorf("storage_key len = %d, want 32 hex chars", len(res.StorageKey))
	}
	if repo.createCalls != 1 {
		t.Errorf("CreatePending calls = %d, want 1", repo.createCalls)
	}
	if s3.deleteCalls != 0 {
		t.Errorf("DeleteObject called on happy path")
	}
}

func TestRequestUploadURL_StorageKeyHasNoAlbumID(t *testing.T) {
	// M9 : storage_key MUST NOT contain album_id, media_id, or any /
	svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
	albumID := uuid.New()
	in := validInput()
	res, err := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if bytes.Contains([]byte(res.StorageKey), []byte(albumID.String())) {
		t.Errorf("storage_key %q leaks album_id", res.StorageKey)
	}
	if bytes.Contains([]byte(res.StorageKey), []byte(in.MediaID.String())) {
		t.Errorf("storage_key %q leaks media_id", res.StorageKey)
	}
	if bytes.ContainsAny([]byte(res.StorageKey), "/") {
		t.Errorf("storage_key %q contains a path separator", res.StorageKey)
	}
}

func TestConfirmUpload_HappyPath(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headSize = in.BlobSize
	s3.headSHA256B64 = base64.StdEncoding.EncodeToString(in.BlobSHA256)

	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("err = %v", err)
	}
	row := repo.rows[res.MediaID]
	if !row.Confirmed {
		t.Errorf("row not flipped to confirmed")
	}
}

func TestConfirmUpload_SizeMismatchDropsRow(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headSize = in.BlobSize - 1 // S3 stored fewer bytes than promised
	s3.headSHA256B64 = base64.StdEncoding.EncodeToString(in.BlobSHA256)

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if _, ok := repo.rows[res.MediaID]; ok {
		t.Errorf("pending row not dropped on size mismatch")
	}
	if s3.deleteCalls == 0 {
		t.Errorf("orphaned S3 object not deleted")
	}
}

func TestConfirmUpload_SHA256MismatchDropsRow(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headSize = in.BlobSize
	s3.headSHA256B64 = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xFF}, 32))

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if _, ok := repo.rows[res.MediaID]; ok {
		t.Errorf("pending row not dropped on sha256 mismatch")
	}
}

func TestConfirmUpload_SHA256AbsentTrustsPutEnforcement(t *testing.T) {
	// MinIO doesnt always echo ChecksumSHA256 on HEAD : an empty hash from
	// HeadObject must NOT be treated as a mismatch (S3 already enforced the
	// checksum at PUT time)
	svc, _, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headSize = in.BlobSize
	s3.headSHA256B64 = "" // server didnt echo

	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("err = %v ; expected pass through (PUT-time enforcement)", err)
	}
}

func TestConfirmUpload_HeadFailureReturnsValidation(t *testing.T) {
	svc, _, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headErr = errors.New("404 NoSuchKey")

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
}

func TestConfirmUpload_IsIdempotent(t *testing.T) {
	svc, _, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	s3.headSize = in.BlobSize
	s3.headSHA256B64 = base64.StdEncoding.EncodeToString(in.BlobSHA256)
	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("first confirm: %v", err)
	}
	// Second confirm on already confirmed row is a no op
	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("second confirm: %v ; expected nil (idempotent)", err)
	}
}

func TestConfirmUpload_UnknownMediaIs404(t *testing.T) {
	svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
	err := svc.ConfirmUpload(context.Background(), uuid.New(), uuid.New())
	if !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
}
