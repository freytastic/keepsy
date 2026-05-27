package handle

import (
	"strings"
	"testing"
)

// seqReader yields a distinct 40-bit value per Read (big-endian), so each
// Generate gets unique input → unique output, deterministically
type seqReader struct{ n uint64 }

func (s *seqReader) Read(p []byte) (int, error) {
	s.n++
	v := s.n
	for i := len(p) - 1; i >= 0; i-- {
		p[i] = byte(v)
		v >>= 8
	}
	return len(p), nil
}

func TestGenerate_validAndCanonical(t *testing.T) {
	r := &seqReader{}
	for i := 0; i < 5; i++ {
		h, err := Generate(r)
		if err != nil {
			t.Fatal(err)
		}
		if len(h) != Length {
			t.Fatalf("len=%d want %d", len(h), Length)
		}
		for _, c := range h {
			if !strings.ContainsRune(alphabet, c) {
				t.Fatalf("char %q not in alphabet", c)
			}
		}
		n, err := Normalize(h)
		if err != nil || n != h {
			t.Fatalf("Generate output not canonical: %q err=%v norm=%q", h, err, n)
		}
	}
}

func TestGenerate_unique(t *testing.T) {
	r := &seqReader{}
	seen := make(map[string]struct{}, 1000)
	for i := 0; i < 1000; i++ {
		h, err := Generate(r)
		if err != nil {
			t.Fatal(err)
		}
		if _, dup := seen[h]; dup {
			t.Fatalf("duplicate %q at iter %d", h, i)
		}
		seen[h] = struct{}{}
	}
}

var normalizeVectors = []struct{ in, want string }{
	{"K7F29QXM", "K7F29QXM"},
	{"k7f2-9qxm", "K7F29QXM"},
	{"ILOl0o1i", "11010011"},
	{"  abcd efgh ", "ABCDEFGH"},
	{"0123-4567", "01234567"},
}

func TestNormalize_vectors(t *testing.T) {
	for _, v := range normalizeVectors {
		got, err := Normalize(v.in)
		if err != nil {
			t.Fatalf("Normalize(%q) unexpected err: %v", v.in, err)
		}
		if got != v.want {
			t.Fatalf("Normalize(%q)=%q want %q", v.in, got, v.want)
		}
	}
}

func TestNormalize_rejects(t *testing.T) {
	for _, b := range []string{"", "ABC", "ABCDEFGHI", "ABCDEFGU", "ABCDEF!@", "1234567"} {
		if _, err := Normalize(b); err == nil {
			t.Fatalf("Normalize(%q) expected error, got nil", b)
		}
	}
}

func TestFormat_roundTrip(t *testing.T) {
	const x = "ABCDEFGH"
	if got := Format(x); got != "ABCD-EFGH" {
		t.Fatalf("Format(%q)=%q", x, got)
	}
	n, err := Normalize(Format(x))
	if err != nil || n != x {
		t.Fatalf("Normalize(Format(x))=%q err=%v want %q", n, err, x)
	}
}
