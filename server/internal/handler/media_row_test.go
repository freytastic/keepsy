package handler

import (
	"testing"

	"github.com/freytastic/keepsy/internal/model"
	"github.com/google/uuid"
)

func TestMediaRow_CarriesAlbumSeq(t *testing.T) {
	seq := int64(7)
	row := mediaRow(model.Media{ID: uuid.New(), AlbumID: uuid.New(), AlbumSeq: &seq})
	if row["album_seq"] != seq {
		t.Fatalf("album_seq = %v, want %d", row["album_seq"], seq)
	}
}

func TestMediaRow_OmitsMissingAlbumSeq(t *testing.T) {
	row := mediaRow(model.Media{ID: uuid.New(), AlbumID: uuid.New()})
	if _, ok := row["album_seq"]; ok {
		t.Fatalf("album_seq present for a row without one: %v", row["album_seq"])
	}
}
