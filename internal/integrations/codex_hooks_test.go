package integrations

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallCodexPreservesLargeJSONNumbers(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	path, _ := CodexHooksPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	const largeNumber = "9007199254740993"
	if err := os.WriteFile(path, []byte(`{"user_value":`+largeNumber+`}`), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := installCodex("/opt/mw", nil); err != nil {
		t.Fatalf("installCodex returned error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), largeNumber) {
		t.Fatalf("Codex hooks changed the user number: %s", data)
	}
}

func TestCodexStatusRejectsDisabledTrustEntry(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	if _, err := installCodex("/opt/mw", nil); err != nil {
		t.Fatalf("installCodex returned error: %v", err)
	}
	configPath, _ := CodexConfigPath()
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	disabled := strings.Replace(string(data), "enabled = true", "enabled = false", 1)
	if err := os.WriteFile(configPath, []byte(disabled), 0o600); err != nil {
		t.Fatal(err)
	}

	status, ok := CodexStatus()
	if ok || status != "hooks installed but not trusted" {
		t.Fatalf("CodexStatus = %q, %v; want disabled trust failure", status, ok)
	}
}

func TestWriteCodexFilesPreservesBackupWhenRestoreFails(t *testing.T) {
	root := t.TempDir()
	hooksWritePath := filepath.Join(root, "hooks-target.json")
	if err := os.WriteFile(hooksWritePath, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	hooksPath := filepath.Join(root, "hooks.json")
	if err := os.Symlink(filepath.Join(root, "missing-target"), hooksPath); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(root, "hooks.bak")
	if err := os.WriteFile(backup, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}

	preserve, err := writeCodexFiles(
		codexFileContext{
			path:          hooksPath,
			writePath:     hooksWritePath,
			mode:          0o600,
			currentBackup: backup,
		},
		codexFileContext{
			path:      root,
			writePath: root,
			mode:      0o600,
		},
		[]byte(`{"hooks":{}}`),
		[]byte("config"),
	)
	if err == nil || !preserve {
		t.Fatalf("writeCodexFiles = preserve %v, error %v; want preserved rollback evidence", preserve, err)
	}
	if _, statErr := os.Stat(backup); statErr != nil {
		t.Fatalf("Codex rollback backup was removed after restore failure: %v", statErr)
	}
}

func TestCodexHookHashMatchesCodexCanonicalJSON(t *testing.T) {
	hook := codexHook{
		event:   "SessionStart",
		status:  "idle",
		message: "Codex session started",
		timeout: 5,
	}
	hash, err := codexHookHash(hook, "'/opt/mw' 'hook' 'codex' 'SessionStart' >/dev/null")
	if err != nil {
		t.Fatal(err)
	}
	const want = "sha256:fcdf7ef00d47e6a690dd7a0bebd6a09df505fc7a25643e5d08c68a960fd1428e"
	if hash != want {
		t.Fatalf("codexHookHash = %s, want %s", hash, want)
	}
}
