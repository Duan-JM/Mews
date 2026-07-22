package integrations

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Duan-JM/mews/internal/store"
)

func TestInstallAllPreservesUserConfigAndUndoRemovesOnlyMews(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	claudePath, _ := ClaudeSettingsPath()
	if err := os.MkdirAll(filepath.Dir(claudePath), 0o700); err != nil {
		t.Fatal(err)
	}
	claudeOriginal := `{
  "theme": "dark",
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "/usr/local/bin/user-hook"}]
      }
    ]
  }
}`
	if err := os.WriteFile(claudePath, []byte(claudeOriginal), 0o600); err != nil {
		t.Fatal(err)
	}

	codexPath, _ := CodexConfigPath()
	if err := os.MkdirAll(filepath.Dir(codexPath), 0o700); err != nil {
		t.Fatal(err)
	}
	codexOriginal := "model = \"gpt-5\"\n\n[tui]\nnotifications = true\n"
	if err := os.WriteFile(codexPath, []byte(codexOriginal), 0o600); err != nil {
		t.Fatal(err)
	}

	installed, err := InstallAll("/opt/mews/bin/mw")
	if err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}
	if len(installed) != 3 {
		t.Fatalf("installed %d integrations, want 3", len(installed))
	}
	for _, integration := range installed {
		if integration.BackupPath != "" {
			if _, err := os.Stat(integration.BackupPath); err != nil {
				t.Fatalf("%s backup missing: %v", integration.Name, err)
			}
		}
	}

	claudeData, err := os.ReadFile(claudePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(claudeData), "/usr/local/bin/user-hook") ||
		!strings.Contains(string(claudeData), "claude-code") {
		t.Fatalf("Claude settings did not preserve user hook and add Mews: %s", claudeData)
	}

	codexData, err := os.ReadFile(codexPath)
	if err != nil {
		t.Fatal(err)
	}
	content := string(codexData)
	if !strings.Contains(content, codexMarkerStart) ||
		strings.Index(content, codexMarkerStart) > strings.Index(content, "[tui]") {
		t.Fatalf("Codex notify block was not inserted at top level: %s", content)
	}

	var claudeSettings map[string]any
	if err := json.Unmarshal(claudeData, &claudeSettings); err != nil {
		t.Fatal(err)
	}
	claudeSettings["user_edit_after_setup"] = true
	editedClaude, _ := json.MarshalIndent(claudeSettings, "", "  ")
	if err := os.WriteFile(claudePath, append(editedClaude, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(codexPath, append(codexData, []byte("\nreview_model = \"gpt-5\"\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkCopilotSubagent("session-123", "/tmp/subagent.jsonl"); err != nil {
		t.Fatal(err)
	}

	if err := UndoAll(); err != nil {
		t.Fatalf("UndoAll returned error: %v", err)
	}

	claudeData, err = os.ReadFile(claudePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(claudeData), "claude-code") ||
		!strings.Contains(string(claudeData), "/usr/local/bin/user-hook") ||
		!strings.Contains(string(claudeData), "user_edit_after_setup") {
		t.Fatalf("Claude undo removed user config or kept Mews config: %s", claudeData)
	}
	codexData, err = os.ReadFile(codexPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(codexData), codexMarkerStart) ||
		!strings.Contains(string(codexData), "review_model") {
		t.Fatalf("Codex undo removed user config or kept Mews block: %s", codexData)
	}
	hookPath, _ := CopilotHookPath()
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("Copilot hook still exists after undo: %v", err)
	}
	if _, configured, err := store.LoadIntegrationState(); err != nil || configured {
		t.Fatalf("integration state remains after undo: configured=%v err=%v", configured, err)
	}
	paths, err := store.Paths()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(paths.CopilotHooks); !os.IsNotExist(err) {
		t.Fatalf("Copilot runtime hook state remains after undo: %v", err)
	}
}

func TestInstallAllRollsBackWhenClaudeSettingsAreMalformed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	claudePath, _ := ClaudeSettingsPath()
	if err := os.MkdirAll(filepath.Dir(claudePath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(claudePath, []byte(`{"hooks":`), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := InstallAll("/opt/mews/bin/mw"); err == nil ||
		!strings.Contains(err.Error(), "malformed JSON") {
		t.Fatalf("InstallAll error = %v, want malformed JSON", err)
	}
	hookPath, _ := CopilotHookPath()
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("Copilot hook was not rolled back: %v", err)
	}
}

func TestInstallCodexRefusesExistingNotify(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	path, _ := CodexConfigPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	original := `notify = ["/usr/local/bin/custom-notify"]` + "\n"
	if err := os.WriteFile(path, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := installCodex("/opt/mews/bin/mw", nil); err == nil ||
		!strings.Contains(err.Error(), "already configured") {
		t.Fatalf("installCodex error = %v, want existing notify conflict", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != original {
		t.Fatalf("Codex config changed after refusal: %s", data)
	}
}

func TestInstallClaudeDoesNotClaimSimilarUserCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	path, _ := ClaudeSettingsPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	userCommand := "/usr/local/bin/team-notify --source claude-code"
	settings := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"` + userCommand + `"}]}]}}`
	if err := os.WriteFile(path, []byte(settings), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}
	if err := UndoAll(); err != nil {
		t.Fatalf("UndoAll returned error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), userCommand) {
		t.Fatalf("similar user command was removed: %s", data)
	}
}

func TestUndoUsesRecordedCopilotPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	firstHome := filepath.Join(home, "copilot-a")
	t.Setenv("COPILOT_HOME", firstHome)
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	if _, err := InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}
	firstHook := filepath.Join(firstHome, "hooks", "mews.json")

	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot-b"))
	if err := UndoAll(); err != nil {
		t.Fatalf("UndoAll returned error: %v", err)
	}
	if _, err := os.Stat(firstHook); !os.IsNotExist(err) {
		t.Fatalf("recorded Copilot hook still exists: %v", err)
	}
}

func TestUndoCanResumeAfterPartialFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	if _, err := InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}
	claudePath, _ := ClaudeSettingsPath()
	if err := os.WriteFile(claudePath, []byte(`{"hooks":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := UndoAll(); err == nil {
		t.Fatal("UndoAll succeeded with malformed Claude settings")
	}
	if err := os.WriteFile(claudePath, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := UndoAll(); err != nil {
		t.Fatalf("UndoAll retry returned error: %v", err)
	}
}

func TestClaudeSymlinkIsPreserved(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	target := filepath.Join(home, "dotfiles", "claude-settings.json")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	path, _ := ClaudeSettingsPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}

	if _, err := InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}
	if info, err := os.Lstat(path); err != nil {
		t.Fatalf("Claude config symlink missing: %v", err)
	} else if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("Claude config symlink was replaced: mode=%v", info.Mode())
	}
	if err := UndoAll(); err != nil {
		t.Fatalf("UndoAll returned error: %v", err)
	}
	if info, err := os.Lstat(path); err != nil {
		t.Fatalf("Claude config symlink missing after undo: %v", err)
	} else if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("Claude config symlink was not preserved by undo: mode=%v", info.Mode())
	}
}

func TestInstallCodexRefusesMultilineStrings(t *testing.T) {
	data := []byte("developer_instructions = \"\"\"\n[section]\nKeep this text\n\"\"\"\n")
	if _, err := installCodexBlock(data, `notify = ["/opt/mw", "hook", "codex"]`); err == nil ||
		!strings.Contains(err.Error(), "multiline TOML strings") {
		t.Fatalf("installCodexBlock error = %v, want multiline refusal", err)
	}
}

func TestInstallCodexRefusesQuotedTopLevelKeys(t *testing.T) {
	data := []byte(`"notify" = ["/usr/local/bin/custom-notify"]` + "\n")
	if _, err := installCodexBlock(data, `notify = ["/opt/mw", "hook", "codex"]`); err == nil ||
		!strings.Contains(err.Error(), "quoted top-level TOML keys") {
		t.Fatalf("installCodexBlock error = %v, want quoted-key refusal", err)
	}
}

func TestCopilotOwnershipRejectsSimilarUserHooks(t *testing.T) {
	config := copilotHookConfig{
		Version: 1,
		Hooks: map[string][]copilotCommandHook{
			"agentStop": {
				{Type: "command", Bash: "/usr/local/bin/my-notify --source copilot"},
			},
			"sessionEnd": {
				{Type: "command", Bash: "/usr/local/bin/my-notify --source copilot"},
			},
			"errorOccurred": {
				{Type: "command", Bash: "/usr/local/bin/my-notify --source copilot"},
			},
		},
	}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if isMewsHook(data) {
		t.Fatal("similar user hooks were classified as Mews-owned")
	}
}

func TestCopilotOwnershipRequiresMarkerForCurrentFormat(t *testing.T) {
	config, _ := copilotManagedConfig("/opt/mews/bin/mw")
	for event, hooks := range config.Hooks {
		hooks[0].Env = nil
		config.Hooks[event] = hooks
	}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if isMewsHook(data) {
		t.Fatal("markerless current-format hooks were classified as Mews-owned")
	}
}

func TestInstallCopilotMigratesPreviousManagedFormats(t *testing.T) {
	tests := []struct {
		name   string
		config func(string) (copilotHookConfig, []string)
	}{
		{name: "v2 lifecycle hooks", config: previousControlCopilotConfigForTest},
		{name: "v1 notification hooks", config: previousCopilotConfigForTest},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))

			config, managed := test.config("/old/mw")
			data, err := json.MarshalIndent(config, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			hookPath, _ := CopilotHookPath()
			if err := os.MkdirAll(filepath.Dir(hookPath), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(hookPath, append(data, '\n'), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := RemoveCopilotHooks(); err != nil {
				t.Fatalf("RemoveCopilotHooks returned error: %v", err)
			}
			if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
				t.Fatalf("previous Copilot hook still exists after removal: %v", err)
			}
			if err := os.WriteFile(hookPath, append(data, '\n'), 0o600); err != nil {
				t.Fatal(err)
			}

			previous := &store.IntegrationState{
				Name:    "copilot",
				Path:    hookPath,
				Created: true,
				Managed: managed,
			}
			state, err := installCopilot("/new/mw", previous, false)
			if err != nil {
				t.Fatalf("installCopilot returned error: %v", err)
			}
			t.Cleanup(func() {
				if state.RollbackPath != "" {
					_ = os.Remove(state.RollbackPath)
				}
			})

			updated, err := os.ReadFile(hookPath)
			if err != nil {
				t.Fatal(err)
			}
			if !isMewsHook(updated) ||
				!strings.Contains(string(updated), copilotOwnershipMarker) ||
				!strings.Contains(string(updated), "userPromptSubmitted") {
				t.Fatalf("previous Copilot hooks were not migrated: %s", updated)
			}
		})
	}
}

func previousControlCopilotConfigForTest(
	mwPath string,
) (copilotHookConfig, []string) {
	config := copilotHookConfig{
		Version: 1,
		Hooks:   make(map[string][]copilotCommandHook),
	}
	managed := make([]string, 0, len(previousCopilotHookEvents()))
	for _, event := range previousCopilotHookEvents() {
		hook := copilotHook(mwPath, event)
		hook.Env["MEWS_MANAGED_INTEGRATION"] = previousCopilotOwnershipMarker
		config.Hooks[event] = []copilotCommandHook{hook}
		managed = append(managed, hook.Bash)
	}
	return config, managed
}

func previousCopilotConfigForTest(mwPath string) (copilotHookConfig, []string) {
	specs := map[string][2]string{
		"agentStop":     {"done", "Copilot agent stopped"},
		"sessionEnd":    {"idle", "Copilot session ended"},
		"errorOccurred": {"failed", "Copilot error occurred"},
	}
	config := copilotHookConfig{
		Version: 1,
		Hooks:   make(map[string][]copilotCommandHook, len(specs)),
	}
	managed := make([]string, 0, len(specs))
	for event, values := range specs {
		parts := []string{
			mwPath,
			"notify",
			"--source", "copilot",
			"--hook-event", event,
			"--status", values[0],
			"--message", values[1],
		}
		for index, part := range parts {
			parts[index] = shellQuote(part)
		}
		command := strings.Join(parts, " ") + " >/dev/null"
		config.Hooks[event] = []copilotCommandHook{{
			Type:       "command",
			Bash:       command,
			TimeoutSec: 5,
			Env: map[string]string{
				"MEWS_MANAGED_INTEGRATION": legacyCopilotOwnershipMarker,
			},
		}}
		managed = append(managed, command)
	}
	return config, managed
}

func TestRemoveClaudeRefusesMalformedConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(`{"hooks":`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := removeClaude(store.IntegrationState{Path: path})
	if err == nil || !strings.Contains(err.Error(), "malformed JSON") {
		t.Fatalf("removeClaude error = %v, want malformed JSON", err)
	}
}
