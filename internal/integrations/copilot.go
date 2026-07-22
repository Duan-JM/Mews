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
const copilotOwnershipMarker = "copilot-v3"
const previousCopilotOwnershipMarker = "copilot-v2"
const legacyCopilotOwnershipMarker = "copilot-v1"

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

type previousCopilotHookFormat struct {
	marker string
	quote  func(string) string
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
) (store.IntegrationState, error) {
	if mwPath == "" {
		return store.IntegrationState{}, fmt.Errorf("mw executable path is required")
	}

	hookPath, writePath, err := prepareCopilotPaths(previous)
	if err != nil {
		return store.IntegrationState{}, err
	}

	config, managed := copilotManagedConfig(mwPath)
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return store.IntegrationState{}, err
	}
	data = append(data, '\n')

	existed, currentBackup, err := prepareCopilotBackup(writePath, hookPath, previous, allowLegacy)
	if err != nil {
		return store.IntegrationState{}, err
	}

	installed := false
	defer func() {
		if !installed && currentBackup != "" {
			_ = os.Remove(currentBackup)
		}
	}()
	if err := writeFileAtomic(writePath, data, 0o600); err != nil {
		return store.IntegrationState{}, err
	}
	installed = true

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
	}, nil
}

func prepareCopilotPaths(previous *store.IntegrationState) (string, string, error) {
	hookPath, err := CopilotHookPath()
	if err != nil {
		return "", "", err
	}
	if err := ensureRecordedIntegrationPath(previous, hookPath, "Copilot", "COPILOT_HOME"); err != nil {
		return "", "", err
	}
	writePath, err := resolveWritePath(hookPath)
	if err != nil {
		return "", "", err
	}
	return hookPath, writePath, nil
}

func prepareCopilotBackup(
	writePath, hookPath string,
	previous *store.IntegrationState,
	allowLegacy bool,
) (bool, string, error) {
	if !fileExists(writePath) {
		return false, "", nil
	}

	current, err := os.ReadFile(writePath)
	if err != nil {
		return false, "", err
	}
	if err := validateCopilotOwnership(current, hookPath, previous, allowLegacy); err != nil {
		return false, "", err
	}
	currentBackup, err := backupFile("copilot", writePath)
	if err != nil {
		return false, "", err
	}
	return true, currentBackup, nil
}

func validateCopilotOwnership(
	current []byte,
	hookPath string,
	previous *store.IntegrationState,
	allowLegacy bool,
) error {
	switch {
	case previous != nil:
		if !isRecordedMewsHook(current) || !matchesManagedCopilot(current, previous.Managed) {
			return fmt.Errorf("%s changed after Mews setup; refusing to overwrite it", hookPath)
		}
	case allowLegacy:
		if !isRecordedMewsHook(current) {
			return fmt.Errorf("%s does not match the recorded legacy Mews hook", hookPath)
		}
	case !isMewsHook(current):
		return fmt.Errorf("%s exists but is not Mews-owned", hookPath)
	}
	return nil
}

func RemoveCopilotHooks() error {
	hookPath, err := CopilotHookPath()
	if err != nil {
		return err
	}
	return removeCopilotHookAt(hookPath, true)
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

	owned := isMewsHook(data) ||
		allowLegacy && (isPreviousMewsHook(data) || isLegacyMewsHook(data))
	if !owned {
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
	if !isRecordedMewsHook(data) || !matchesManagedCopilot(data, state.Managed) {
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
		if isPreviousMewsHook(data) || isLegacyMewsHook(data) {
			return "legacy hooks installed; rerun `mw setup --yes`", false
		}
		return "non-Mews hook file exists", false
	}
	return "hooks installed", true
}

func copilotHook(mwPath, hookEvent string) copilotCommandHook {
	parts := []string{
		mwPath,
		"hook",
		"copilot",
		hookEvent,
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

func copilotManagedConfig(mwPath string) (copilotHookConfig, []string) {
	events := copilotHookEvents()
	hooks := make(map[string][]copilotCommandHook, len(events))
	managed := make([]string, 0, len(events))
	for _, event := range events {
		hook := copilotHook(mwPath, event)
		hooks[event] = []copilotCommandHook{hook}
		managed = append(managed, hook.Bash)
	}

	return copilotHookConfig{
		Version: 1,
		Hooks:   hooks,
	}, managed
}

func isMewsHook(data []byte) bool {
	return matchesCopilotControlHook(
		data,
		copilotOwnershipMarker,
		copilotHookEvents(),
	)
}

func matchesCopilotControlHook(
	data []byte,
	marker string,
	expectedEvents []string,
) bool {
	var config copilotHookConfig
	if err := json.Unmarshal(data, &config); err != nil || config.Version != 1 {
		return false
	}
	if len(config.Hooks) != len(expectedEvents) {
		return false
	}
	for _, event := range expectedEvents {
		hooks := config.Hooks[event]
		if len(hooks) != 1 {
			return false
		}
		hook := hooks[0]
		if hook.Type != "command" || hook.TimeoutSec != 5 {
			return false
		}
		if hook.Env["MEWS_MANAGED_INTEGRATION"] != marker {
			return false
		}
		suffix := strings.Join([]string{
			shellQuote("hook"),
			shellQuote("copilot"),
			shellQuote(event),
		}, " ") + " >/dev/null"
		if !strings.HasSuffix(hook.Bash, suffix) {
			return false
		}
	}
	return true
}

func isPreviousMewsHook(data []byte) bool {
	return matchesCopilotControlHook(
		data,
		previousCopilotOwnershipMarker,
		previousCopilotHookEvents(),
	) || matchesPreviousMewsHook(data, previousCopilotHookFormat{
		marker: legacyCopilotOwnershipMarker,
		quote:  shellQuote,
	})
}

func isLegacyMewsHook(data []byte) bool {
	return matchesPreviousMewsHook(data, previousCopilotHookFormat{
		quote: strconv.Quote,
	})
}

func isRecordedMewsHook(data []byte) bool {
	return isMewsHook(data) || isPreviousMewsHook(data) || isLegacyMewsHook(data)
}

func copilotHookEvents() []string {
	return []string{
		"sessionStart",
		"userPromptSubmitted",
		"subagentStop",
		"agentStop",
		"sessionEnd",
		"errorOccurred",
	}
}

func previousCopilotHookEvents() []string {
	return []string{
		"sessionStart",
		"subagentStart",
		"subagentStop",
		"agentStop",
		"sessionEnd",
		"errorOccurred",
	}
}

func matchesPreviousMewsHook(
	data []byte,
	format previousCopilotHookFormat,
) bool {
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
		if len(hooks) != 1 || hooks[0].Type != "command" || hooks[0].TimeoutSec != 5 {
			return false
		}
		if format.marker != "" {
			if hooks[0].Env["MEWS_MANAGED_INTEGRATION"] != format.marker {
				return false
			}
		} else if len(hooks[0].Env) != 0 {
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
			parts[index] = format.quote(part)
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
