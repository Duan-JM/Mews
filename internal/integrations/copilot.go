package integrations

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/store"
)

const copilotHookFile = "mews.json"
const copilotOwnershipMarker = "copilot-v1"

type copilotHookConfig struct {
	Version int                             `json:"version"`
	Hooks   map[string][]copilotCommandHook `json:"hooks"`
}

type copilotCommandHook struct {
	Type       string            `json:"type"`
	Bash       string            `json:"bash"`
	TimeoutSec int               `json:"timeoutSec"`
	Env        map[string]string `json:"env,omitempty"`
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

func installCopilot(
	mwPath string,
	previous *store.IntegrationState,
	allowLegacy bool,
) (store.IntegrationState, bool, error) {
	if mwPath == "" {
		return store.IntegrationState{}, false, fmt.Errorf("mw executable path is required")
	}

	hookPath, err := CopilotHookPath()
	if err != nil {
		return store.IntegrationState{}, false, err
	}
	if previous != nil && previous.Path != hookPath {
		return store.IntegrationState{}, false, fmt.Errorf(
			"Copilot integration is recorded at %s; run `mw undo` before changing COPILOT_HOME",
			previous.Path,
		)
	}
	writePath, err := resolveWritePath(hookPath)
	if err != nil {
		return store.IntegrationState{}, false, err
	}
	existed := fileExists(writePath)

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
		return store.IntegrationState{}, false, err
	}
	data = append(data, '\n')

	var currentBackup string
	installed := false
	defer func() {
		if !installed && currentBackup != "" {
			_ = os.Remove(currentBackup)
		}
	}()
	if existed {
		current, err := os.ReadFile(writePath)
		if err != nil {
			return store.IntegrationState{}, false, err
		}
		if previous != nil {
			if !isMewsHook(current) || !matchesManagedCopilot(current, previous.Managed) {
				return store.IntegrationState{}, false, fmt.Errorf(
					"%s changed after Mews setup; refusing to overwrite it",
					hookPath,
				)
			}
		} else if allowLegacy {
			if !isLegacyMewsHook(current) {
				return store.IntegrationState{}, false, fmt.Errorf(
					"%s does not match the recorded legacy Mews hook",
					hookPath,
				)
			}
		} else if !isMewsHook(current) {
			return store.IntegrationState{}, false, fmt.Errorf("%s exists but is not Mews-owned", hookPath)
		}
		currentBackup, err = backupFile("copilot", writePath)
		if err != nil {
			return store.IntegrationState{}, false, err
		}
	}
	if err := writeFileAtomic(writePath, data, 0o600); err != nil {
		return store.IntegrationState{}, false, err
	}
	installed = true

	managed := make([]string, 0, len(config.Hooks))
	for _, hooks := range config.Hooks {
		for _, hook := range hooks {
			managed = append(managed, hook.Bash)
		}
	}
	backupPath := currentBackup
	created := !existed
	var rollbackPath string
	if previous != nil {
		backupPath = previous.BackupPath
		created = previous.Created
		rollbackPath = currentBackup
	} else if allowLegacy {
		backupPath = ""
		created = true
		rollbackPath = currentBackup
	}
	return store.IntegrationState{
		Name:         "copilot",
		Path:         hookPath,
		BackupPath:   backupPath,
		Created:      created,
		Managed:      managed,
		InstalledAt:  time.Now(),
		RollbackPath: rollbackPath,
	}, existed, nil
}

func RemoveCopilotHooks() error {
	hookPath, err := CopilotHookPath()
	if err != nil {
		return err
	}
	return RemoveCopilotHookAt(hookPath)
}

func RemoveCopilotHookAt(hookPath string) error {
	return removeCopilotHookAt(hookPath, false)
}

func RemoveRecordedCopilotHookAt(hookPath string) error {
	return removeCopilotHookAt(hookPath, true)
}

func removeCopilotHookAt(hookPath string, allowLegacy bool) error {
	data, err := os.ReadFile(hookPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !isMewsHook(data) && !(allowLegacy && isLegacyMewsHook(data)) {
		return fmt.Errorf("%s exists but is not Mews-owned", hookPath)
	}
	if err := os.Remove(hookPath); err != nil {
		return err
	}
	return nil
}

func removeCopilot(state store.IntegrationState) error {
	writePath, err := resolveWritePath(state.Path)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(writePath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !isMewsHook(data) || !matchesManagedCopilot(data, state.Managed) {
		return fmt.Errorf("%s exists but is not Mews-owned", state.Path)
	}
	if !state.Created && state.BackupPath != "" {
		return restoreBackup(state)
	}
	return os.Remove(writePath)
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
		if isLegacyMewsHook(data) {
			return "legacy hooks installed; rerun `mw setup --yes`", false
		}
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
		parts[i] = shellQuote(part)
	}
	return copilotCommandHook{
		Type:       "command",
		Bash:       strings.Join(parts, " ") + " >/dev/null",
		TimeoutSec: 5,
		Env: map[string]string{
			"MEWS_MANAGED_INTEGRATION": copilotOwnershipMarker,
		},
	}
}

func isMewsHook(data []byte) bool {
	var config copilotHookConfig
	if err := json.Unmarshal(data, &config); err != nil || config.Version != 1 {
		return false
	}
	expectedEvents := map[string]struct {
		status  string
		message string
	}{
		"agentStop":     {status: "done", message: "Copilot agent stopped"},
		"sessionEnd":    {status: "idle", message: "Copilot session ended"},
		"errorOccurred": {status: "failed", message: "Copilot error occurred"},
	}
	if len(config.Hooks) != len(expectedEvents) {
		return false
	}
	for event, expected := range expectedEvents {
		hooks := config.Hooks[event]
		if len(hooks) != 1 {
			return false
		}
		hook := hooks[0]
		if hook.Type != "command" || hook.TimeoutSec != 5 {
			return false
		}
		if hook.Env["MEWS_MANAGED_INTEGRATION"] != copilotOwnershipMarker {
			return false
		}
		suffix := strings.Join([]string{
			shellQuote("notify"),
			shellQuote("--source"), shellQuote("copilot"),
			shellQuote("--hook-event"), shellQuote(event),
			shellQuote("--status"), shellQuote(expected.status),
			shellQuote("--message"), shellQuote(expected.message),
		}, " ") + " >/dev/null"
		if !strings.HasSuffix(hook.Bash, suffix) {
			return false
		}
	}
	return true
}

func isLegacyMewsHook(data []byte) bool {
	var config copilotHookConfig
	if err := json.Unmarshal(data, &config); err != nil || config.Version != 1 {
		return false
	}
	expectedEvents := map[string]struct {
		status  string
		message string
	}{
		"agentStop":     {status: "done", message: "Copilot agent stopped"},
		"sessionEnd":    {status: "idle", message: "Copilot session ended"},
		"errorOccurred": {status: "failed", message: "Copilot error occurred"},
	}
	if len(config.Hooks) != len(expectedEvents) {
		return false
	}
	for event, expected := range expectedEvents {
		hooks := config.Hooks[event]
		if len(hooks) != 1 || hooks[0].Type != "command" ||
			hooks[0].TimeoutSec != 5 || len(hooks[0].Env) != 0 {
			return false
		}
		parts := []string{
			"notify",
			"--source", "copilot",
			"--hook-event", event,
			"--status", expected.status,
			"--message", expected.message,
		}
		for index, part := range parts {
			parts[index] = strconv.Quote(part)
		}
		if !strings.HasSuffix(hooks[0].Bash, strings.Join(parts, " ")+" >/dev/null") {
			return false
		}
	}
	return true
}

func matchesManagedCopilot(data []byte, managed []string) bool {
	var config copilotHookConfig
	if err := json.Unmarshal(data, &config); err != nil || config.Version != 1 {
		return false
	}
	actual := make(map[string]int)
	for _, hooks := range config.Hooks {
		for _, hook := range hooks {
			actual[hook.Bash]++
		}
	}
	if len(actual) != len(managed) {
		return false
	}
	for _, command := range managed {
		if actual[command] != 1 {
			return false
		}
	}
	return true
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
