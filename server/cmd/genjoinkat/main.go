// genjoinkat is the one shot geneator for test_vectors/join_complete_kat.json
// Output is byte-stable : re-running emits identical JSON. Consumed by both Go
// (internal/e2ee/invite/join_kat_test.go) and Dart (frontend/test/e2ee/
// join_kat_test.dart). Run once, redirect stdout into the JSON, then never edit
// the byte values again :  go run ./cmd/genjoinkat > test_vectors/join_complete_kat.json
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/freytastic/keepsy/internal/e2ee/invite"
	"github.com/google/uuid"
)

type vector struct {
	Name           string `json:"name"`
	IKSeedHex      string `json:"ik_seed_hex"`
	AlbumIDHex     string `json:"album_id_hex"`
	Epoch          uint32 `json:"epoch"`
	EkPubAdminHex  string `json:"ek_pub_admin_hex"`
	ExpectedMsgHex string `json:"expected_msg_hex"`
	ExpectedSigHex string `json:"expected_sig_hex"`
}

type kat struct {
	Category string   `json:"category"`
	Vectors  []vector `json:"vectors"`
}

func main() {
	specs := []struct {
		name      string
		seedByte  byte
		albumByte byte
		ekByte    byte
		epoch     uint32
	}{
		{"join_complete basic", 0xC1, 0xB1, 0x51, 0},
		{"join_complete epoch=3", 0xC2, 0xB2, 0x52, 3},
		{"join_complete epoch=42", 0xC3, 0xB3, 0x53, 42},
	}

	out := kat{Category: "join_complete", Vectors: make([]vector, 0, len(specs))}
	for _, s := range specs {
		seed := bytes.Repeat([]byte{s.seedByte}, 32)
		albumBytes := bytes.Repeat([]byte{s.albumByte}, 16)
		albumID, err := uuid.FromBytes(albumBytes)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		ekPubAdmin := bytes.Repeat([]byte{s.ekByte}, 32)

		priv := ed25519.NewKeyFromSeed(seed)
		msg := invite.JoinCompleteMsg(albumID, int(s.epoch), ekPubAdmin)
		sig := ed25519.Sign(priv, msg)

		out.Vectors = append(out.Vectors, vector{
			Name:           s.name,
			IKSeedHex:      hex.EncodeToString(seed),
			AlbumIDHex:     hex.EncodeToString(albumBytes),
			Epoch:          s.epoch,
			EkPubAdminHex:  hex.EncodeToString(ekPubAdmin),
			ExpectedMsgHex: hex.EncodeToString(msg),
			ExpectedSigHex: hex.EncodeToString(sig),
		})
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
