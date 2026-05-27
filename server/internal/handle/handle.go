package handle

import (
	"errors"
	"io"
	"strings"
)

// Crockford base32, no I/L/O/U. 8 chars encode 40 bits
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

const Length = 8

var ErrInvalidHandle = errors.New("invalid keepsy_id handle")

// Generate returns an 8 char canonical handle from 40 random bits
func Generate(r io.Reader) (string, error) {
	var b [5]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", err
	}
	out := [Length]byte{
		alphabet[b[0]>>3],
		alphabet[((b[0]&0x07)<<2)|(b[1]>>6)],
		alphabet[(b[1]>>1)&0x1f],
		alphabet[((b[1]&0x01)<<4)|(b[2]>>4)],
		alphabet[((b[2]&0x0f)<<1)|(b[3]>>7)],
		alphabet[(b[3]>>2)&0x1f],
		alphabet[((b[3]&0x03)<<3)|(b[4]>>5)],
		alphabet[b[4]&0x1f],
	}
	return string(out[:]), nil
}

// Normalize folds a user entered handle to canonical form: drop dashes +
// whitespace, upper case, fold Crockford ambiguous chars (I/L→1, O→0), then
// validate length + alphabet
func Normalize(s string) (string, error) {
	out := make([]byte, 0, Length)
	for _, r := range s {
		switch r {
		case '-', ' ', '\t', '\n', '\r':
			continue
		}
		if r >= 'a' && r <= 'z' {
			r -= 'a' - 'A'
		}
		switch r {
		case 'I', 'L':
			r = '1'
		case 'O':
			r = '0'
		}
		idx := strings.IndexRune(alphabet, r)
		if idx < 0 {
			return "", ErrInvalidHandle
		}
		out = append(out, alphabet[idx])
		if len(out) > Length {
			return "", ErrInvalidHandle
		}
	}
	if len(out) != Length {
		return "", ErrInvalidHandle
	}
	return string(out), nil
}

// Format renders the display form XXXX-XXXX. The server stores only the
// canonical (dash-free) value
func Format(canonical string) string {
	if len(canonical) != Length {
		return canonical
	}
	return canonical[:4] + "-" + canonical[4:]
}
