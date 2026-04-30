// No i don't even trust myself to remember every rule 100% of the time
// that i created myself.

package repository_test

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// only these tables may FK to users(id). Any other reference leaks
// the user→album linkage that the pseudonymous token model is designed to
// hide. If u need to add a new table, prove the privacy story first
var allowedUserFKTables = map[string]bool{
	"sessions":                true,
	"one_time_prekeys":        true,
	"album_member_identities": true,
	"notifications":           true,
}

func TestMigrationsRespectUserFKAllowlist(t *testing.T) {
	data, err := os.ReadFile("../../migrations/000001_initial_schema.up.sql")
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}
	tables := splitCreateTableBlocks(string(data))
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
