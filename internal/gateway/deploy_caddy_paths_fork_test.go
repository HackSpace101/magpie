package gateway

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// TestForkCaddyClientPaths holds the fork's Docker deploy to the gateway's
// client routes. Caddy (deploy/docker/magpie.sh, CLIENT_PATHS) lets these
// past the web UI's password, since each brings a gateway key; a client
// route upstream adds and the list lacks would ask an agent for the
// password, and one the list keeps that is gone would skip it for a page.
func TestForkCaddyClientPaths(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "deploy", "docker", "magpie.sh"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^CLIENT_PATHS="([^"]*)"$`).FindSubmatch(b)
	if m == nil {
		t.Fatal(`magpie.sh has no CLIENT_PATHS="…" line`)
	}
	got := strings.Fields(string(m[1]))
	want := slices.Clone(clientPrefixes)
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Errorf("magpie.sh CLIENT_PATHS = %v\nclientPrefixes      = %v\nmake CLIENT_PATHS the gateway's client routes", got, want)
	}
}
