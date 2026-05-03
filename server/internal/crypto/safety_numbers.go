package crypto

import (
	"crypto/sha256"
	"fmt"
	"math/big"
	"strings"
)

// SafetyNumber computes the pairwise MITM fingerprint :

//	first 30 decimal digits of SHA256(sort_lex(IK_pub_A, IK_pub_B) || album_id)

// The lex sort makes this symmetric (A,B) == (B,A). Used for user visible
// out-of-band verification, so byte parity with Dart matters

// Returns the 30-digit unformatted string. Use SafetyNumberFormatted for the
// space grouped display form
const safetyNumberDigits = 30

// 2^256 < 10^78, so any SHA-256 fits in 78 decimal digits when zero-padded
// slicing the leading 30 makes the digits a fixed positional contract :
// hashes that happen to start with low bytes never produce shorter strings
const safetyNumberPad = 78

func SafetyNumber(ikPubA, ikPubB, albumID []byte) (string, error) {
	if len(ikPubA) != IkPubLen {
		return "", fmt.Errorf("crypto: ikPubA must be %d bytes, got %d", IkPubLen, len(ikPubA))
	}
	if len(ikPubB) != IkPubLen {
		return "", fmt.Errorf("crypto: ikPubB must be %d bytes, got %d", IkPubLen, len(ikPubB))
	}
	if len(albumID) != AlbumIDLen {
		return "", fmt.Errorf("crypto: albumID must be %d bytes, got %d", AlbumIDLen, len(albumID))
	}
	lo, hi := ikPubA, ikPubB
	if compareBytes(ikPubA, ikPubB) > 0 {
		lo, hi = ikPubB, ikPubA
	}
	pre := make([]byte, 0, IkPubLen+IkPubLen+AlbumIDLen)
	pre = append(pre, lo...)
	pre = append(pre, hi...)
	pre = append(pre, albumID...)
	d := sha256.Sum256(pre)

	n := new(big.Int).SetBytes(d[:]).String()
	if len(n) < safetyNumberPad {
		n = strings.Repeat("0", safetyNumberPad-len(n)) + n
	}
	return n[:safetyNumberDigits], nil
}

// SafetyNumberFormatted returns the 30 digits in six space separated groups
// of five : "XXXXX XXXXX XXXXX XXXXX XXXXX XXXXX"
func SafetyNumberFormatted(ikPubA, ikPubB, albumID []byte) (string, error) {
	d, err := SafetyNumber(ikPubA, ikPubB, albumID)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	for i := 0; i < len(d); i += 5 {
		if i > 0 {
			sb.WriteByte(' ')
		}
		sb.WriteString(d[i : i+5])
	}
	return sb.String(), nil
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
