package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/store"
)

func TestResetRequiresUndoWhenIntegrationsAreConfigured(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var setupOut, setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}

	var resetOut, resetErr bytes.Buffer
	if code := Run([]string{"reset", "--yes"}, strings.NewReader(""), &resetOut, &resetErr); code != 1 {
		t.Fatalf("reset returned %d, want 1", code)
	}
	if !strings.Contains(resetErr.String(), "Run `mw undo`") {
		t.Fatalf("reset did not explain required undo: %q", resetErr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if _, err := os.Stat(hookPath); err != nil {
		t.Fatalf("reset removed integration before undo: %v", err)
	}
}

func TestSetupCanBeRepeatedWithoutLosingUndoOwnership(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	for attempt := 0; attempt < 2; attempt++ {
		var stdout, stderr bytes.Buffer
		if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
			t.Fatalf("setup attempt %d returned %d, stderr: %s", attempt+1, code, stderr.String())
		}
	}
	var undoOut, undoErr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &undoOut, &undoErr); code != 0 {
		t.Fatalf("undo returned %d, stderr: %s", code, undoErr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("Copilot hook remains after repeated setup and undo: %v", err)
	}
}

func TestUndoUsesIntegrationStateWithoutSetupState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	if _, err := integrations.InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("undo returned %d, stderr: %s", code, stderr.String())
	}
	if _, configured, err := store.LoadIntegrationState(); err != nil || configured {
		t.Fatalf("integration state remains: configured=%v err=%v", configured, err)
	}
}

func TestLegacyUndoUsesRecordedCopilotPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	firstHome := filepath.Join(home, "copilot-a")
	t.Setenv("COPILOT_HOME", firstHome)
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	hookPath := filepath.Join(firstHome, "hooks", "mews.json")
	if err := os.MkdirAll(filepath.Dir(hookPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hookPath, legacyCopilotHookJSON(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSetupState(store.SetupState{
		Version:     1,
		SetupAt:     time.Now(),
		Agent:       "not packaged yet",
		Copilot:     "hooks installed",
		CopilotHook: hookPath,
		Claude:      "hooks not installed",
		UndoReady:   true,
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot-b"))
	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("legacy undo returned %d, stderr: %s", code, stderr.String())
	}
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("recorded legacy Copilot hook remains: %v", err)
	}
}

func TestUndoRefusesWhenCurrentIntegrationStateIsMissing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var setupOut, setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}
	if err := store.RemoveIntegrationState(); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 1 {
		t.Fatalf("undo returned %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "integration rollback state is missing") {
		t.Fatalf("undo did not explain missing rollback state: %q", stderr.String())
	}
	if _, configured, err := store.LoadSetupState(); err != nil || !configured {
		t.Fatalf("setup state was removed: configured=%v err=%v", configured, err)
	}
	for _, path := range []string{
		filepath.Join(home, "copilot", "hooks", "mews.json"),
		filepath.Join(home, "claude", "settings.json"),
		filepath.Join(home, "codex", "config.toml"),
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("integration was changed after failed undo: %s: %v", path, err)
		}
	}
}

func TestSetupMigratesRecordedLegacyCopilotHook(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("initial setup returned %d, stderr: %s", code, stderr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if err := os.WriteFile(hookPath, legacyCopilotHookJSON(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.RemoveIntegrationState(); err != nil {
		t.Fatal(err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("migration setup returned %d, stderr: %s", code, stderr.String())
	}
	data, err := os.ReadFile(hookPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "MEWS_MANAGED_INTEGRATION") {
		t.Fatalf("legacy hook was not migrated: %s", data)
	}
}

func legacyCopilotHookJSON() []byte {
	type hook struct {
		Type       string `json:"type"`
		Bash       string `json:"bash"`
		TimeoutSec int    `json:"timeoutSec"`
	}
	config := struct {
		Version int               `json:"version"`
		Hooks   map[string][]hook `json:"hooks"`
	}{
		Version: 1,
		Hooks:   make(map[string][]hook),
	}
	events := map[string][2]string{
		"agentStop":     {"done", "Copilot agent stopped"},
		"sessionEnd":    {"idle", "Copilot session ended"},
		"errorOccurred": {"failed", "Copilot error occurred"},
	}
	for event, values := range events {
		parts := []string{
			"/legacy/mw", "notify",
			"--source", "copilot",
			"--hook-event", event,
			"--status", values[0],
			"--message", values[1],
		}
		for index, part := range parts {
			parts[index] = strconv.Quote(part)
		}
		config.Hooks[event] = []hook{{
			Type:       "command",
			Bash:       strings.Join(parts, " ") + " >/dev/null",
			TimeoutSec: 5,
		}}
	}
	data, _ := json.Marshal(config)
	return data
}
