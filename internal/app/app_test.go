package app

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
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

func TestStableInstalledPathUsesHomebrewOptPrefix(t *testing.T) {
	tests := map[string]string{
		"/opt/homebrew/Cellar/mews/0.1.0/bin/mw": "/opt/homebrew/opt/mews/bin/mw",
		"/usr/local/Cellar/mews/2.3.4/bin/mw":    "/usr/local/opt/mews/bin/mw",
		"/usr/local/bin/mw":                      "/usr/local/bin/mw",
	}
	for input, want := range tests {
		if got := StableInstalledPath(input); got != want {
			t.Fatalf("StableInstalledPath(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestRegisterBundleUsesLaunchServices(t *testing.T) {
	original := runLSRegister
	t.Cleanup(func() { runLSRegister = original })

	var got string
	runLSRegister = func(path string) ([]byte, error) {
		got = path
		return nil, nil
	}

	if err := RegisterBundle("/Applications/Mews.app"); err != nil {
		t.Fatalf("RegisterBundle returned error: %v", err)
	}
	if got != "/Applications/Mews.app" {
		t.Fatalf("registered path = %q, want /Applications/Mews.app", got)
	}
}

func TestRegisterBundleReportsLaunchServicesFailure(t *testing.T) {
	original := runLSRegister
	t.Cleanup(func() { runLSRegister = original })

	runLSRegister = func(string) ([]byte, error) {
		return []byte("registration denied"), errors.New("exit status 1")
	}

	err := RegisterBundle("/Applications/Mews.app")
	if err == nil || !strings.Contains(err.Error(), "registration denied") {
		t.Fatalf("RegisterBundle error = %v, want LaunchServices output", err)
	}
}
