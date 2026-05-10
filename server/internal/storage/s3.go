package storage

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type S3Client struct {
	client        *s3.Client
	presignClient *s3.PresignClient
	bucket        string
}

func NewS3Client(endpoint, accessKey, secretKey, bucket, region string, usePathStyle bool) (*S3Client, error) {
	customResolver := aws.EndpointResolverWithOptionsFunc(func(service, reg string, options ...interface{}) (aws.Endpoint, error) {
		return aws.Endpoint{
			URL:               endpoint,
			SigningRegion:     region,
			HostnameImmutable: usePathStyle,
		}, nil
	})

	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion(region),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
		config.WithEndpointResolverWithOptions(customResolver),
	)
	if err != nil {
		return nil, err
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = usePathStyle
	})

	return &S3Client{
		client:        client,
		presignClient: s3.NewPresignClient(client),
		bucket:        bucket,
	}, nil
}

// GetPresignedUploadURL generates a URL that allows a client to upload a file directly to S3/R2.
// the URL is valid for the specified duration
func (s *S3Client) GetPresignedUploadURL(ctx context.Context, key string, contentType string, expires time.Duration) (string, error) {
	request, err := s.presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(key),
		ContentType: aws.String(contentType),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return "", err
	}

	return request.URL, nil
}

// PresignedUpload bundles a presigned URL with the headers the client must send
// S3 enforces ContentLength + ChecksumSHA256 server side : if the client uploads
// the wrong number of bytes or the wrong content, the PUT fails before our
// ConfirmUpload ever runs
type PresignedUpload struct {
	URL            string
	RequiredHeader map[string]string // headers the client MUST set on PUT
}

// GetPresignedUploadURLWithChecksum returns a PUT URL that S3 will reject
// unless the body is exactly contentLength bytes and its SHA256 matches
// sha256B64. contentType is set so MinIO doesnt default to octet stream
func (s *S3Client) GetPresignedUploadURLWithChecksum(ctx context.Context, key, contentType string, contentLength int64, sha256B64 string, expires time.Duration) (*PresignedUpload, error) {
	req, err := s.presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:         aws.String(s.bucket),
		Key:            aws.String(key),
		ContentType:    aws.String(contentType),
		ContentLength:  aws.Int64(contentLength),
		ChecksumSHA256: aws.String(sha256B64),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return nil, err
	}
	return &PresignedUpload{
		URL: req.URL,
		RequiredHeader: map[string]string{
			"Content-Type":          contentType,
			"x-amz-checksum-sha256": sha256B64,
		},
	}, nil
}

// HeadObject returns the size + base64 SHA256 of an uploaded object. Used by
// ConfirmUpload to validate the client's claimed size+sha256 against what S3
// actually stored. Returns ErrObjectNotFound if the upload never happened
func (s *S3Client) HeadObject(ctx context.Context, key string) (size int64, sha256B64 string, err error) {
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket:       aws.String(s.bucket),
		Key:          aws.String(key),
		ChecksumMode: "ENABLED",
	})
	if err != nil {
		return 0, "", err
	}
	if out.ContentLength != nil {
		size = *out.ContentLength
	}
	if out.ChecksumSHA256 != nil {
		sha256B64 = *out.ChecksumSHA256
	}
	return size, sha256B64, nil
}

// GetPresignedDownloadURL generates a URL that allows a client to download a file from S3/R2
func (s *S3Client) GetPresignedDownloadURL(ctx context.Context, key string, expires time.Duration) (string, error) {
	request, err := s.presignClient.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return "", err
	}

	return request.URL, nil
}

// DeleteObject removes a file from S3/R2
func (s *S3Client) DeleteObject(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	return err
}

func (s *S3Client) CreateBucketIfNotExists(ctx context.Context) error {
	_, err := s.client.HeadBucket(ctx, &s3.HeadBucketInput{
		Bucket: aws.String(s.bucket),
	})
	if err != nil {
		// bucket doesnt exist, create it
		_, err = s.client.CreateBucket(ctx, &s3.CreateBucketInput{
			Bucket: aws.String(s.bucket),
		})
		return err
	}
	return nil
}
