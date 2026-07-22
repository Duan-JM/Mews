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

func TestSocketNamespacesUseDistinctFallbacks(t *testing.T) {
	home := filepath.Join(t.TempDir(), strings.Repeat("long-home-", 12))
	t.Setenv("HOME", home)
	t.Setenv("MEWS_SOCKET_NAMESPACE", "first")
	first, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("MEWS_SOCKET_NAMESPACE", "second")
	second, err := Paths()
	if err != nil {
		t.Fatal(err)
	}

	if first.SocketDir == second.SocketDir {
		t.Fatalf("distinct namespaces shared socket directory %s", first.SocketDir)
	}
}

func TestCopilotHookStateUsesOpaqueMarkersAndClearsPerSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sessionID := "session/with/private-details"
	transcriptPath := "/private/path/to/subagent-transcript.jsonl"
	if err := MarkCopilotSubagent(sessionID, transcriptPath); err != nil {
		t.Fatalf("MarkCopilotSubagent returned error: %v", err)
	}
	if marked, err := IsCopilotSubagent(transcriptPath); err != nil || !marked {
		t.Fatalf("IsCopilotSubagent = %v, %v; want true, nil", marked, err)
	}

	paths, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	err = filepath.Walk(paths.CopilotHooks, func(path string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(path, sessionID) || strings.Contains(path, transcriptPath) {
			t.Fatalf("Copilot hook state exposed raw identifiers: %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := ClearCopilotHookSession(sessionID); err != nil {
		t.Fatalf("ClearCopilotHookSession returned error: %v", err)
	}
	if marked, err := IsCopilotSubagent(transcriptPath); err != nil || marked {
		t.Fatalf("IsCopilotSubagent after clear = %v, %v; want false, nil", marked, err)
	}
}

func TestCopilotHookStateRefusesSymlinkDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	paths, err := Paths()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	if err := os.Symlink(target, paths.CopilotHooks); err != nil {
		t.Fatal(err)
	}

	err = MarkCopilotSubagent("session-123", "/tmp/subagent.jsonl")
	if err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("MarkCopilotSubagent error = %v, want symbolic-link refusal", err)
	}
	entries, err := os.ReadDir(target)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("Copilot hook state wrote through symlink: %#v", entries)
	}
}
