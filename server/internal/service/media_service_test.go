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
	downloadURL   string
	downloadErr   error
	downloadKeys  []string
	deleteCalls   int
	deleteKeys    []string
	presignKeys   []string //  track call order so tests can assert dual presign
	//per-key HEAD overrides for dual-confirm tests. Empty map → fall
	// back to headSize/headSHA256B64/headErr (default behavior, same as before)
	headByKey map[string]headResult
}

type headResult struct {
	size      int64
	sha256B64 string
	err       error
}

func (f *fakeS3) GetPresignedUploadURLWithChecksum(_ context.Context, key, _ string, _ int64, _ string, _ time.Duration) (*PresignedUpload, error) {
	f.presignKeys = append(f.presignKeys, key)
	if f.presignErr != nil {
		return nil, f.presignErr
	}
	return &PresignedUpload{URL: "http://s3/upload/" + key, RequiredHeader: map[string]string{"x-amz-checksum-sha256": "x"}}, nil
}

func (f *fakeS3) GetPresignedDownloadURL(_ context.Context, key string, _ time.Duration) (string, error) {
	f.downloadKeys = append(f.downloadKeys, key)
	if f.downloadErr != nil {
		return "", f.downloadErr
	}
	if f.downloadURL == "" {
		return "http://s3/download/" + key, nil
	}
	return f.downloadURL, nil
}

func (f *fakeS3) HeadObject(_ context.Context, key string) (int64, string, error) {
	if r, ok := f.headByKey[key]; ok {
		return r.size, r.sha256B64, r.err
	}
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

// confirmedRow drives the upload happy path so RequestDownloadURL has a
// confirmed row to read. Returns (albumID, mediaID, storageKey)
func confirmedRow(t *testing.T, svc *MediaService, repo *fakeMediaRepo, s3 *fakeS3) (uuid.UUID, uuid.UUID, string) {
	t.Helper()
	in := validInput()
	albumID := uuid.New()
	res, err := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	if err != nil {
		t.Fatalf("RequestUploadURL: %v", err)
	}
	s3.headSize = in.BlobSize
	s3.headSHA256B64 = base64.StdEncoding.EncodeToString(in.BlobSHA256)
	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("ConfirmUpload: %v", err)
	}
	return albumID, res.MediaID, repo.rows[res.MediaID].StorageKey
}

func TestRequestDownloadURL_HappyPath(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	albumID, mediaID, storageKey := confirmedRow(t, svc, repo, s3)

	res, err := svc.RequestDownloadURL(context.Background(), albumID, mediaID, "file")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if res.URL == "" {
		t.Errorf("URL empty")
	}
	if len(s3.downloadKeys) != 1 || s3.downloadKeys[0] != storageKey {
		t.Errorf("presigned for keys %v, want [%q]", s3.downloadKeys, storageKey)
	}
	if !res.ExpiresAt.After(time.Now()) {
		t.Errorf("ExpiresAt %v not in future", res.ExpiresAt)
	}
}

func TestRequestDownloadURL_RefusesPendingRow(t *testing.T) {
	svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validInput()
	albumID := uuid.New()
	res, err := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	if err != nil {
		t.Fatalf("RequestUploadURL: %v", err)
	}
	// no Confirm : row stays pending. Download must refuse so the client
	// doesnt try to GET an S3 object that may not exist
	_, err = svc.RequestDownloadURL(context.Background(), albumID, res.MediaID, "file")
	if !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
}

func TestRequestDownloadURL_UnknownMediaIs404(t *testing.T) {
	svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
	_, err := svc.RequestDownloadURL(context.Background(), uuid.New(), uuid.New(), "file")
	if !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
}

func TestRequestDownloadURL_S3PresignFailureBubblesUp(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	albumID, mediaID, _ := confirmedRow(t, svc, repo, s3)
	s3.downloadErr = errors.New("s3 down")

	_, err := svc.RequestDownloadURL(context.Background(), albumID, mediaID, "file")
	if !apierr.IsCode(err, "E_INTERNAL") {
		t.Fatalf("err = %v, want E_INTERNAL", err)
	}
}

// validThumbInput : validInput() + the four thumb fields set with byte-valid
// shapes. Tests mutate to exercise specific failure modes
func validThumbInput() RequestUploadInput {
	in := validInput()
	in.ThumbSize = 20 * 1024
	in.ThumbSHA256 = bytes.Repeat([]byte{0xCD}, 32)
	in.ThumbWrapNonce = bytes.Repeat([]byte{0x33}, 12)
	in.ThumbWrapTagCT = bytes.Repeat([]byte{0x44}, 48)
	return in
}

func TestRequestUploadURL_ThumbAbsentReturnsSingleURL(t *testing.T) {
	svc, _, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	res, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, validInput())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if res.UploadURL == "" {
		t.Fatalf("UploadURL empty")
	}
	if res.ThumbUploadURL != "" {
		t.Errorf("ThumbUploadURL = %q ; want empty when no thumb requested", res.ThumbUploadURL)
	}
	if len(s3.presignKeys) != 1 {
		t.Errorf("presign called %d times ; want 1", len(s3.presignKeys))
	}
}

func TestRequestUploadURL_ThumbReturnsTwoURLs(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	res, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, validThumbInput())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if res.UploadURL == "" || res.ThumbUploadURL == "" {
		t.Fatalf("URLs = (%q, %q) ; want both set", res.UploadURL, res.ThumbUploadURL)
	}
	if res.UploadURL == res.ThumbUploadURL {
		t.Errorf("file + thumb URLs identical ; storage_key wasnt unique")
	}
	if len(s3.presignKeys) != 2 {
		t.Errorf("presign called %d times ; want 2", len(s3.presignKeys))
	}
	row := repo.rows[res.MediaID]
	if row.ThumbKey == nil {
		t.Fatalf("row.ThumbKey is nil after thumb upload request")
	}
	if *row.ThumbKey == row.StorageKey {
		t.Errorf("thumb_key equals storage_key ; should be distinct random hex")
	}
}

func TestRequestUploadURL_RejectsPartialThumb(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*RequestUploadInput)
		want string
	}{
		{"size only", func(in *RequestUploadInput) {
			in.ThumbSHA256 = nil
			in.ThumbWrapNonce = nil
			in.ThumbWrapTagCT = nil
		}, "thumb_wrap_nonce"},
		{"missing thumb wrap nonce", func(in *RequestUploadInput) { in.ThumbWrapNonce = nil }, "thumb_wrap_nonce"},
		{"missing thumb wrap tag ct", func(in *RequestUploadInput) { in.ThumbWrapTagCT = nil }, "thumb_wrap_tag_ct"},
		{"missing thumb sha256", func(in *RequestUploadInput) { in.ThumbSHA256 = nil }, "thumb_sha256"},
		{"zero thumb size", func(in *RequestUploadInput) { in.ThumbSize = 0 }, "thumb_size"},
		{"wrong thumb nonce len", func(in *RequestUploadInput) { in.ThumbWrapNonce = bytes.Repeat([]byte{1}, 11) }, "thumb_wrap_nonce"},
		{"wrong thumb wrap tag ct len", func(in *RequestUploadInput) { in.ThumbWrapTagCT = bytes.Repeat([]byte{1}, 47) }, "thumb_wrap_tag_ct"},
		{"wrong thumb sha256 len", func(in *RequestUploadInput) { in.ThumbSHA256 = bytes.Repeat([]byte{1}, 31) }, "thumb_sha256"},
		{"thumb too big", func(in *RequestUploadInput) { in.ThumbSize = 600 * 1024 }, "thumb_size"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc, _, _ := newSvc(&fakeEpochs{cur: 3, exists: true})
			in := validThumbInput()
			tt.mut(&in)
			_, err := svc.RequestUploadURL(context.Background(), uuid.New(), []byte{0xCC}, in)
			if !apierr.IsCode(err, "E_VALIDATION") {
				t.Fatalf("err = %v, want E_VALIDATION mentioning %q", err, tt.want)
			}
		})
	}
}

func TestConfirmUpload_ThumbHappyPath(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validThumbInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)

	fileKey := s3.presignKeys[0]
	thumbKey := s3.presignKeys[1]
	s3.headByKey = map[string]headResult{
		fileKey:  {size: in.BlobSize, sha256B64: base64.StdEncoding.EncodeToString(in.BlobSHA256)},
		thumbKey: {size: in.ThumbSize, sha256B64: base64.StdEncoding.EncodeToString(in.ThumbSHA256)},
	}

	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("err = %v", err)
	}
	if !repo.rows[res.MediaID].Confirmed {
		t.Errorf("row not flipped to confirmed")
	}
}

func TestConfirmUpload_ThumbMissingDropsRow(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validThumbInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)

	fileKey := s3.presignKeys[0]
	thumbKey := s3.presignKeys[1]
	s3.headByKey = map[string]headResult{
		fileKey:  {size: in.BlobSize, sha256B64: base64.StdEncoding.EncodeToString(in.BlobSHA256)},
		thumbKey: {err: errors.New("404 NoSuchKey")},
	}

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if _, ok := repo.rows[res.MediaID]; ok {
		t.Errorf("pending row not dropped when thumb missing")
	}
}

func TestConfirmUpload_ThumbSizeMismatchDropsRow(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validThumbInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)

	fileKey := s3.presignKeys[0]
	thumbKey := s3.presignKeys[1]
	s3.headByKey = map[string]headResult{
		fileKey:  {size: in.BlobSize, sha256B64: base64.StdEncoding.EncodeToString(in.BlobSHA256)},
		thumbKey: {size: in.ThumbSize - 1, sha256B64: base64.StdEncoding.EncodeToString(in.ThumbSHA256)},
	}

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if _, ok := repo.rows[res.MediaID]; ok {
		t.Errorf("pending row not dropped on thumb size mismatch")
	}
}

func TestConfirmUpload_ThumbSHA256MismatchDropsRow(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validThumbInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)

	fileKey := s3.presignKeys[0]
	thumbKey := s3.presignKeys[1]
	s3.headByKey = map[string]headResult{
		fileKey:  {size: in.BlobSize, sha256B64: base64.StdEncoding.EncodeToString(in.BlobSHA256)},
		thumbKey: {size: in.ThumbSize, sha256B64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xFF}, 32))},
	}

	err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID)
	if !apierr.IsCode(err, "E_VALIDATION") {
		t.Fatalf("err = %v, want E_VALIDATION", err)
	}
	if _, ok := repo.rows[res.MediaID]; ok {
		t.Errorf("pending row not dropped on thumb sha256 mismatch")
	}
}

func TestRequestDownloadURL_ThumbAssetUsesThumbKey(t *testing.T) {
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	in := validThumbInput()
	albumID := uuid.New()
	res, _ := svc.RequestUploadURL(context.Background(), albumID, []byte{0xCC}, in)
	fileKey := s3.presignKeys[0]
	thumbKey := s3.presignKeys[1]
	s3.headByKey = map[string]headResult{
		fileKey:  {size: in.BlobSize, sha256B64: base64.StdEncoding.EncodeToString(in.BlobSHA256)},
		thumbKey: {size: in.ThumbSize, sha256B64: base64.StdEncoding.EncodeToString(in.ThumbSHA256)},
	}
	if err := svc.ConfirmUpload(context.Background(), albumID, res.MediaID); err != nil {
		t.Fatalf("confirm: %v", err)
	}

	_, err := svc.RequestDownloadURL(context.Background(), albumID, res.MediaID, "thumb")
	if err != nil {
		t.Fatalf("thumb download: %v", err)
	}
	// downloadKeys[0] should be thumbKey (= row.ThumbKey), not fileKey
	if len(s3.downloadKeys) != 1 || s3.downloadKeys[0] != *repo.rows[res.MediaID].ThumbKey {
		t.Errorf("downloaded keys = %v ; want [%v]", s3.downloadKeys, *repo.rows[res.MediaID].ThumbKey)
	}
}

func TestRequestDownloadURL_ThumbAsset404sWhenRowHasNoThumb(t *testing.T) {
	// A row uploaded without a thumb should 404 on asset=thumb request
	svc, repo, s3 := newSvc(&fakeEpochs{cur: 3, exists: true})
	albumID, mediaID, _ := confirmedRow(t, svc, repo, s3)
	_, err := svc.RequestDownloadURL(context.Background(), albumID, mediaID, "thumb")
	if !apierr.IsCode(err, "E_NOT_FOUND") {
		t.Fatalf("err = %v, want E_NOT_FOUND", err)
	}
}
