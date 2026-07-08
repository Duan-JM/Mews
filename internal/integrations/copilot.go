package integrations

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const copilotHookFile = "mews.json"

type CopilotInstall struct {
	HookPath string
	Existed  bool
}

type copilotHookConfig struct {
	Version int                             `json:"version"`
	Hooks   map[string][]copilotCommandHook `json:"hooks"`
}

type copilotCommandHook struct {
	Type       string `json:"type"`
	Bash       string `json:"bash"`
	TimeoutSec int    `json:"timeoutSec"`
}

func CopilotHookPath() (string, error) {
	home := os.Getenv("COPILOT_HOME")
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		home = filepath.Join(userHome, ".copilot")
	}
	return filepath.Join(home, "hooks", copilotHookFile), nil
}

func InstallCopilotHooks(mwPath string) (CopilotInstall, error) {
	if mwPath == "" {
		return CopilotInstall{}, fmt.Errorf("mw executable path is required")
	}

	hookPath, err := CopilotHookPath()
	if err != nil {
		return CopilotInstall{}, err
	}
	existed := fileExists(hookPath)

	config := copilotHookConfig{
		Version: 1,
		Hooks: map[string][]copilotCommandHook{
			"agentStop": {
				notifyHook(mwPath, "agentStop", "done", "Copilot agent stopped"),
			},
			"sessionEnd": {
				notifyHook(mwPath, "sessionEnd", "idle", "Copilot session ended"),
			},
			"errorOccurred": {
				notifyHook(mwPath, "errorOccurred", "failed", "Copilot error occurred"),
			},
		},
	}
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return CopilotInstall{}, err
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(hookPath), 0o700); err != nil {
		return CopilotInstall{}, err
	}
	if existed {
		current, err := os.ReadFile(hookPath)
		if err != nil {
			return CopilotInstall{}, err
		}
		if !isMewsHook(current) {
			return CopilotInstall{}, fmt.Errorf("%s exists but is not Mews-owned", hookPath)
		}
	}
	if err := os.WriteFile(hookPath, data, 0o600); err != nil {
		return CopilotInstall{}, err
	}

	return CopilotInstall{HookPath: hookPath, Existed: existed}, nil
}

func RemoveCopilotHooks() error {
	hookPath, err := CopilotHookPath()
	if err != nil {
		return err
	}

	data, err := os.ReadFile(hookPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !isMewsHook(data) {
		return fmt.Errorf("%s exists but is not Mews-owned", hookPath)
	}
	if err := os.Remove(hookPath); err != nil {
		return err
	}
	return nil
}

func CopilotHookStatus() (string, bool) {
	hookPath, err := CopilotHookPath()
	if err != nil {
		return fmt.Sprintf("path error: %v", err), false
	}

	data, err := os.ReadFile(hookPath)
	if os.IsNotExist(err) {
		return "hooks not installed", false
	}
	if err != nil {
		return fmt.Sprintf("unreadable: %v", err), false
	}
	if !isMewsHook(data) {
		return "non-Mews hook file exists", false
	}

	var config copilotHookConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return "hook file is invalid JSON", false
	}
	if len(config.Hooks["agentStop"]) == 0 {
		return "missing agentStop hook", false
	}
	return "hooks installed", true
}

func notifyHook(mwPath, hookEvent, status, message string) copilotCommandHook {
	parts := []string{
		mwPath,
		"notify",
		"--source", "copilot",
		"--hook-event", hookEvent,
		"--status", status,
		"--message", message,
	}
	for i, part := range parts {
		parts[i] = strconv.Quote(part)
	}
	return copilotCommandHook{
		Type:       "command",
		Bash:       strings.Join(parts, " ") + " >/dev/null",
		TimeoutSec: 5,
	}
}

func isMewsHook(data []byte) bool {
	content := string(data)
	return strings.Contains(content, "agentStop") &&
		strings.Contains(content, "copilot") &&
		strings.Contains(content, "notify")
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
