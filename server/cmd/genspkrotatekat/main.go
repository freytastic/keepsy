// genspkrotatekat is the one shot generator for test_vectors/spk_rotate_kat.json
// Output is byte- stable : re running emits identical JSON. The fixture is
// consumed by both Go (internal/e2ee/prekey/kat_test.go) and Dart
// (frontend/test/e2ee/kat_test.dart). Run it once, redirect stdout into the
// JSON, then never modify the byte values again

package main

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/freytastic/keepsy/internal/crypto"
)

type vector struct {
	Name                string `json:"name"`
	IKSeedHex           string `json:"ik_seed"`
	SPKPubHex           string `json:"spk_pub"`
	SPKTs               int64  `json:"spk_ts"`
	ExpectedMsgHex      string `json:"expected_msg"`
	ExpectedRotationSig string `json:"expected_rotation_sig"`
}

type kat struct {
	Category string   `json:"category"`
	Vectors  []vector `json:"vectors"`
}

func bytesPattern(start byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = start + byte(i)
	}
	return out
}

// rotateMsg = ASCII("rotate-spk-v1") ‖ spk_pub ‖ uint64_be(spk_ts
// Mirrors prekey.RotationMsg byte-for-byte : duplicated here so the generator
// has zero non stdlib runtime deps beyond internal/crypto's salt constant
func rotateMsg(spkPub []byte, spkTs int64) []byte {
	out := make([]byte, 0, len(crypto.SaltSpkRotate)+32+8)
	out = append(out, crypto.SaltSpkRotate...)
	out = append(out, spkPub...)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], uint64(spkTs))
	return append(out, ts[:]...)
}

func main() {
	specs := []struct {
		name     string
		seedByte byte
		ts       int64
	}{
		{"rotate-spk basic", 0xA1, 1714838400},
		{"rotate-spk +1d", 0xB2, 1714924800},
		{"rotate-spk +2d", 0xC3, 1715011200},
	}

	out := kat{Category: "spk_rotate", Vectors: make([]vector, 0, len(specs))}
	for _, s := range specs {
		seed := bytesPattern(s.seedByte, 32)
		priv := ed25519.NewKeyFromSeed(seed)
		// SPK pub bytes are deterministic under a fixed scheme too : derive a
		// 32 byte pattern from the same seed anchor so Dart can reproduce them
		// without an X25519 dependency in this fixture
		spkPub := bytesPattern(s.seedByte+0x10, 32)
		msg := rotateMsg(spkPub, s.ts)
		sig := ed25519.Sign(priv, msg)

		out.Vectors = append(out.Vectors, vector{
			Name:                s.name,
			IKSeedHex:           hex.EncodeToString(seed),
			SPKPubHex:           hex.EncodeToString(spkPub),
			SPKTs:               s.ts,
			ExpectedMsgHex:      hex.EncodeToString(msg),
			ExpectedRotationSig: hex.EncodeToString(sig),
		})
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
