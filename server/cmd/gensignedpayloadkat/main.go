// gensignedpayloadkat is the one shot generator for
// test_vectors/signed_payload_kat.json. Output is byte stable: re running
// emits identical JSON. The fixture is consumed by both Go (internal/e2ee/
// epoch/signed_payload_kat_test.go) and Dart (frontend/test/e2ee/
// mk_delivery_kat_test.dart). Run it once, redirect stdout into the JSON,
// then never modify the byte values again

package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/freytastic/keepsy/internal/crypto"
)

type vector struct {
	Name           string `json:"name"`
	IKSeedHex      string `json:"ik_seed_hex"`
	AlbumIDHex     string `json:"album_id_hex"`
	Epoch          uint32 `json:"epoch"`
	WrapBlobHex    string `json:"wrap_blob_hex"`
	ExpectedMsgHex string `json:"expected_msg_hex"`
	ExpectedSigHex string `json:"expected_sig_hex"`
}

type kat struct {
	Category string   `json:"category"`
	Vectors  []vector `json:"vectors"`
}

// signedPayloadMsg = SHA256(album_id(16) ‖ uint32_be(epoch) ‖ wrap_blob(61))
// Same as in the §4.2 D3 wire format byte for byte
func signedPayloadMsg(albumID []byte, epoch uint32, wrapBlob []byte) [32]byte {
	buf := make([]byte, 0, 16+4+61)
	buf = append(buf, albumID...)
	var ep [4]byte
	binary.BigEndian.PutUint32(ep[:], epoch)
	buf = append(buf, ep[:]...)
	buf = append(buf, wrapBlob...)
	return crypto.SHA256(buf)
}

func main() {
	specs := []struct {
		name      string
		seedByte  byte
		albumByte byte
		epoch     uint32
		wrapByte  byte
	}{
		{"signed_payload basic", 0xD1, 0xA1, 0, 0x11},
		{"signed_payload epoch=1", 0xE2, 0xA2, 1, 0x22},
		{"signed_payload epoch=7", 0xF3, 0xA3, 7, 0x33},
	}

	out := kat{Category: "signed_payload", Vectors: make([]vector, 0, len(specs))}
	for _, s := range specs {
		seed := bytes.Repeat([]byte{s.seedByte}, 32)
		albumID := bytes.Repeat([]byte{s.albumByte}, 16)
		wrap := bytes.Repeat([]byte{s.wrapByte}, 61)
		// VER=0x01 prefix matches the §4.1 wrap_blob shape : the rest of the
		// blob is synthesised, no AES-GCM is run here
		wrap[0] = 0x01

		priv := ed25519.NewKeyFromSeed(seed)
		msg := signedPayloadMsg(albumID, s.epoch, wrap)
		sig := ed25519.Sign(priv, msg[:])

		out.Vectors = append(out.Vectors, vector{
			Name:           s.name,
			IKSeedHex:      hex.EncodeToString(seed),
			AlbumIDHex:     hex.EncodeToString(albumID),
			Epoch:          s.epoch,
			WrapBlobHex:    hex.EncodeToString(wrap),
			ExpectedMsgHex: hex.EncodeToString(msg[:]),
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
