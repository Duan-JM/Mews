package app

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveBundleFromEnvironment(t *testing.T) {
	dir := filepath.Join(t.TempDir(), BundleName)
	executable := filepath.Join(dir, "Contents", "MacOS", "Mews")
	if err := os.MkdirAll(filepath.Dir(executable), 0o700); err != nil {
		t.Fatalf("MkdirAll returned error: %v", err)
	}
	if err := os.WriteFile(executable, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatalf("WriteFile returned error: %v", err)
	}
	t.Setenv("MEWS_APP_PATH", dir)

	bundle, err := ResolveBundle()
	if err != nil {
		t.Fatalf("ResolveBundle returned error: %v", err)
	}
	if bundle.Path != dir {
		t.Fatalf("bundle path = %q, want %q", bundle.Path, dir)
	}
	if bundle.Executable != executable {
		t.Fatalf("executable = %q, want %q", bundle.Executable, executable)
	}
}

func TestResolveBundleRejectsMissingBundle(t *testing.T) {
	t.Setenv("MEWS_APP_PATH", filepath.Join(t.TempDir(), BundleName))

	if _, err := ResolveBundle(); err != ErrNotFound {
		t.Fatalf("ResolveBundle error = %v, want ErrNotFound", err)
	}
}
