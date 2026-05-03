// genx3dhkat is a one shot generator for the x3dh_4dh / x3dh_3dh / safety_numbers
// KAT entries in test_vectors/crypto_kat.json. Run it once, paste the output
// into the JSON, then never modify the byte values again : the KAT is the
// byte level contract the Dart side asserts against

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math/big"
	"strings"

	"github.com/freytastic/keepsy/internal/crypto"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

// Fixed seeds picked once : changing them invalidates the frozen KAT
var (
	lkASeed  = bytesPattern(0x01, 32)
	ekASeed  = bytesPattern(0xA0, 32)
	lkBSeed  = bytesPattern(0x40, 32)
	spkBSeed = bytesPattern(0x60, 32)
	opkBSeed = bytesPattern(0x80, 32)
	albumID  = bytesPattern(0xF0, 16)
)

func bytesPattern(start byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = start + byte(i)
	}
	return out
}

func pub(scalar []byte) []byte {
	p, err := curve25519.X25519(scalar, curve25519.Basepoint)
	if err != nil {
		panic(err)
	}
	return p
}

func dh(scalar, peerPub []byte) []byte {
	out, err := curve25519.X25519(scalar, peerPub)
	if err != nil {
		panic(err)
	}
	return out
}

func sharedSecret(km, lkPubA, lkPubB, album []byte) []byte {
	info, err := crypto.X3dhInfo(lkPubA, lkPubB, album)
	if err != nil {
		panic(err)
	}
	r := hkdf.New(sha256.New, km, crypto.SaltX3dh, info)
	out := make([]byte, 32)
	if _, err := io.ReadFull(r, out); err != nil {
		panic(err)
	}
	return out
}

func main() {
	lkAPub := pub(lkASeed)
	ekAPub := pub(ekASeed)
	lkBPub := pub(lkBSeed)
	spkBPub := pub(spkBSeed)
	opkBPub := pub(opkBSeed)

	// Initiator side DHs (responder mirror produces identical bytes)
	dh1 := dh(lkASeed, spkBPub)
	dh2 := dh(ekASeed, lkBPub)
	dh3 := dh(ekASeed, spkBPub)
	dh4 := dh(ekASeed, opkBPub)

	km4 := concat(dh1, dh2, dh3, dh4)
	km3 := concat(dh1, dh2, dh3)

	shared4 := sharedSecret(km4, lkAPub, lkBPub, albumID)
	shared3 := sharedSecret(km3, lkAPub, lkBPub, albumID)

	fmt.Println(`  "x3dh_4dh": [`)
	fmt.Println(`    {`)
	fmt.Println(`      "name": "fixed seeds, 4-DH (with OPK)",`)
	emit("lk_a_seed_hex", lkASeed)
	emit("ek_a_seed_hex", ekASeed)
	emit("lk_b_seed_hex", lkBSeed)
	emit("spk_b_seed_hex", spkBSeed)
	emit("opk_b_seed_hex", opkBSeed)
	emit("album_id_hex", albumID)
	emit("lk_a_pub_hex", lkAPub)
	emit("lk_b_pub_hex", lkBPub)
	emit("ek_a_pub_hex", ekAPub)
	emit("spk_b_pub_hex", spkBPub)
	emit("opk_b_pub_hex", opkBPub)
	emitLast("shared_secret_hex", shared4)
	fmt.Println(`    }`)
	fmt.Println(`  ],`)

	fmt.Println(`  "x3dh_3dh": [`)
	fmt.Println(`    {`)
	fmt.Println(`      "name": "fixed seeds, 3-DH (OPK exhausted)",`)
	emit("lk_a_seed_hex", lkASeed)
	emit("ek_a_seed_hex", ekASeed)
	emit("lk_b_seed_hex", lkBSeed)
	emit("spk_b_seed_hex", spkBSeed)
	emit("album_id_hex", albumID)
	emit("lk_a_pub_hex", lkAPub)
	emit("lk_b_pub_hex", lkBPub)
	emit("ek_a_pub_hex", ekAPub)
	emit("spk_b_pub_hex", spkBPub)
	emitLast("shared_secret_hex", shared3)
	fmt.Println(`    }`)
	fmt.Println(`  ],`)

	// Safety numbers : two cases, fixed IK pub bytes (Ed25519). Sort happens
	// inside SafetyNumber, so we cover both orderings (A,B) and (B,A) via two
	// vectors that exercise both leading byte cases
	ikLow := bytesPattern(0x00, 32)
	ikHigh := bytesPattern(0x80, 32)
	cases := []struct {
		name string
		a, b []byte
	}{
		{"low pub byte vs high pub byte (sort_lex picks low first)", ikLow, ikHigh},
		{"reversed input order (must be symmetric)", ikHigh, ikLow},
	}
	fmt.Println(`  "safety_numbers": [`)
	for i, c := range cases {
		fmt.Println(`    {`)
		fmt.Printf("      \"name\": %q,\n", c.name)
		emit("ik_pub_a_hex", c.a)
		emit("ik_pub_b_hex", c.b)
		emit("album_id_hex", albumID)
		fmt.Printf("      %q: %q\n", "digits", safetyNumberDigits(c.a, c.b, albumID))
		if i == len(cases)-1 {
			fmt.Println(`    }`)
		} else {
			fmt.Println(`    },`)
		}
	}
	fmt.Println(`  ]`)
}

func safetyNumberDigits(ikA, ikB, album []byte) string {
	lo, hi := ikA, ikB
	if compareBytes(ikA, ikB) > 0 {
		lo, hi = ikB, ikA
	}
	pre := concat(lo, hi, album)
	d := sha256.Sum256(pre)

	// BE → big.Int, format as 78-char zero-padded decimal, slice first 30
	n := new(big.Int).SetBytes(d[:])
	s := n.String()
	if len(s) < 78 {
		s = strings.Repeat("0", 78-len(s)) + s
	}
	return s[:30]
}

func compareBytes(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return int(a[i]) - int(b[i])
		}
	}
	return len(a) - len(b)
}

func concat(parts ...[]byte) []byte {
	total := 0
	for _, p := range parts {
		total += len(p)
	}
	out := make([]byte, 0, total)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func emit(name string, b []byte) {
	fmt.Printf("      %q: %q,\n", name, hex.EncodeToString(b))
}

func emitLast(name string, b []byte) {
	fmt.Printf("      %q: %q\n", name, hex.EncodeToString(b))
}
