package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPathsUsesShortSocketFallbackForLongHome(t *testing.T) {
	home := filepath.Join(t.TempDir(), strings.Repeat("long-home-", 12))
	t.Setenv("HOME", home)

	paths, err := Ensure()
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	if len(paths.Socket) >= 100 {
		t.Fatalf("socket path is too long: %s", paths.Socket)
	}
	if paths.SocketDir == paths.AppSupport {
		t.Fatalf("long home did not use socket fallback: %s", paths.Socket)
	}
	info, err := os.Stat(paths.SocketDir)
	if err != nil {
		t.Fatalf("socket directory missing: %v", err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode = %o, want 700", info.Mode().Perm())
	}
	t.Cleanup(func() { _ = os.RemoveAll(paths.SocketDir) })
}
