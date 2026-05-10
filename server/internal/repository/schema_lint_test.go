// No i don't even trust myself to remember every rule 100% of the time
// that i created myself.

package repository_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// only these tables may FK to users(id). Any other reference leaks
// the user→album linkage that the pseudonymous token model is designed to
// hide. If u need to add a new table, prove the privacy story first
var allowedUserFKTables = map[string]bool{
	"sessions":         true,
	"one_time_prekeys": true,
	"spk_rotations":    true,
}

func TestMigrationsRespectUserFKAllowlist(t *testing.T) {
	// every *.up.sql under migrations/ contributes tables : the allowlist must
	// stay closed across the whole history, not just the initial schema
	matches, err := filepath.Glob("../../migrations/*.up.sql")
	if err != nil {
		t.Fatalf("glob migrations: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no up.sql migrations found")
	}
	tables := map[string]string{}
	for _, p := range matches {
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s: %v", p, err)
		}
		for k, v := range splitCreateTableBlocks(string(data)) {
			tables[k] = v
		}
	}
	if len(tables) == 0 {
		t.Fatal("no CREATE TABLE blocks parsed")
	}
	usersFK := regexp.MustCompile(`(?i)references\s+users\s*\(\s*id\s*\)`)
	for name, body := range tables {
		if !usersFK.MatchString(body) {
			continue
		}
		if !allowedUserFKTables[name] {
			t.Errorf("table %q has FK to users(id) but is not in the allowlist; "+
				"adding such an FK leaks user↔album linkage. "+
				"If this is intentional, justify in plan and update allowedUserFKTables.", name)
		}
	}
}

var createTableRe = regexp.MustCompile(`(?is)CREATE\s+TABLE\s+(\w+)\s*\((.*?)\n\)\s*;`)

func splitCreateTableBlocks(sql string) map[string]string {
	out := map[string]string{}
	for _, m := range createTableRe.FindAllStringSubmatch(sql, -1) {
		out[strings.ToLower(m[1])] = m[2]
	}
	return out
}

func TestSchemaLinterCatchesViolation(t *testing.T) {
	bad := `
CREATE TABLE leaky (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id)
);
CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id)
);
`
	tables := splitCreateTableBlocks(bad)
	usersFK := regexp.MustCompile(`(?i)references\s+users\s*\(\s*id\s*\)`)
	got := []string{}
	for name, body := range tables {
		if usersFK.MatchString(body) && !allowedUserFKTables[name] {
			got = append(got, name)
		}
	}
	if len(got) != 1 || got[0] != "leaky" {
		t.Errorf("expected linter to flag [leaky], got %v", got)
	}
}
