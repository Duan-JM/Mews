package integrations

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Duan-JM/mews/internal/store"
)

type claudeHook struct {
	event   string
	status  string
	message string
}

func ClaudeSettingsPath() (string, error) {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, "settings.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude", "settings.json"), nil
}

func installClaude(mwPath string, previous *store.IntegrationState) (store.IntegrationState, error) {
	path, err := ClaudeSettingsPath()
	if err != nil {
		return store.IntegrationState{}, err
	}
	if previous != nil && previous.Path != path {
		return store.IntegrationState{}, fmt.Errorf(
			"Claude Code integration is recorded at %s; run `mw undo` before changing CLAUDE_CONFIG_DIR",
			previous.Path,
		)
	}
	writePath, err := resolveWritePath(path)
	if err != nil {
		return store.IntegrationState{}, err
	}

	settings := map[string]any{}
	mode := os.FileMode(0o600)
	created := true
	var currentBackup string
	installed := false
	defer func() {
		if !installed && currentBackup != "" {
			_ = os.Remove(currentBackup)
		}
	}()
	if data, err := os.ReadFile(writePath); err == nil {
		created = false
		if err := json.Unmarshal(data, &settings); err != nil {
			return store.IntegrationState{}, fmt.Errorf("%s is malformed JSON: %w", path, err)
		}
		if err := validateClaudeSettings(settings); err != nil {
			return store.IntegrationState{}, fmt.Errorf("%s has invalid hook structure: %w", path, err)
		}
		info, err := os.Stat(writePath)
		if err != nil {
			return store.IntegrationState{}, err
		}
		mode = info.Mode().Perm()
		currentBackup, err = backupFile("claude-code", writePath)
		if err != nil {
			return store.IntegrationState{}, err
		}
	} else if !os.IsNotExist(err) {
		return store.IntegrationState{}, err
	}

	managed := make([]string, 0, 4)
	hooks := []claudeHook{
		{event: "PermissionRequest", status: "needs_input", message: "Claude Code needs input"},
		{event: "Stop", status: "done", message: "Claude Code finished"},
		{event: "StopFailure", status: "failed", message: "Claude Code failed"},
		{event: "SessionEnd", status: "idle", message: "Claude Code session ended"},
	}
	if previous != nil {
		managed := make(map[string]bool, len(previous.Managed))
		for _, command := range previous.Managed {
			managed[command] = true
		}
		removeClaudeCommands(settings, func(existing string) bool {
			return managed[existing]
		})
	}
	for _, hook := range hooks {
		command := claudeCommand(mwPath, hook)
		managed = append(managed, command)
		appendClaudeCommand(settings, hook.event, command)
	}

	data, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return store.IntegrationState{}, err
	}
	data = append(data, '\n')
	if err := writeFileAtomic(writePath, data, mode); err != nil {
		return store.IntegrationState{}, err
	}
	installed = true
	backupPath := currentBackup
	var rollbackPath string
	if previous != nil {
		backupPath = previous.BackupPath
		created = previous.Created
		rollbackPath = currentBackup
	}
	return store.IntegrationState{
		Name:         "claude-code",
		Path:         path,
		BackupPath:   backupPath,
		Created:      created,
		Managed:      managed,
		InstalledAt:  time.Now(),
		RollbackPath: rollbackPath,
	}, nil
}

func removeClaude(state store.IntegrationState) error {
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
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		return fmt.Errorf("%s is malformed JSON: %w", state.Path, err)
	}
	if err := validateClaudeSettings(settings); err != nil {
		return fmt.Errorf("%s has invalid hook structure: %w", state.Path, err)
	}

	managed := make(map[string]bool, len(state.Managed))
	for _, command := range state.Managed {
		managed[command] = true
	}
	removeClaudeCommands(settings, func(command string) bool {
		return managed[command]
	})

	if state.Created && len(settings) == 0 {
		return os.Remove(state.Path)
	}
	info, err := os.Stat(writePath)
	if err != nil {
		return err
	}
	updated, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(writePath, append(updated, '\n'), info.Mode().Perm())
}

func ClaudeStatus() (string, bool) {
	path, err := ClaudeSettingsPath()
	if err != nil {
		return fmt.Sprintf("path error: %v", err), false
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "hooks not installed", false
	}
	if err != nil {
		return fmt.Sprintf("unreadable: %v", err), false
	}
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		return "settings.json is malformed", false
	}
	if err := validateClaudeSettings(settings); err != nil {
		return "settings.json has invalid hook structure", false
	}
	found := false
	visitClaudeCommands(settings, func(command string) {
		if isMewsClaudeCommand(command) {
			found = true
		}
	})
	if !found {
		return "Mews hooks not installed", false
	}
	return "hooks installed", true
}

func claudeCommand(mwPath string, hook claudeHook) string {
	parts := []string{
		mwPath,
		"notify",
		"--source", "claude-code",
		"--hook-event", hook.event,
		"--status", hook.status,
		"--message", hook.message,
	}
	for i, part := range parts {
		parts[i] = shellQuote(part)
	}
	return strings.Join(parts, " ") + " >/dev/null"
}

func appendClaudeCommand(settings map[string]any, event, command string) {
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		settings["hooks"] = hooks
	}
	groups, _ := hooks[event].([]any)
	group := map[string]any{
		"matcher": "",
		"hooks": []any{
			map[string]any{
				"type":    "command",
				"command": command,
				"timeout": 5,
			},
		},
	}
	hooks[event] = append(groups, group)
}

func removeClaudeCommands(settings map[string]any, remove func(string) bool) {
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return
	}
	for event, rawGroups := range hooks {
		groups, ok := rawGroups.([]any)
		if !ok {
			continue
		}
		filteredGroups := make([]any, 0, len(groups))
		for _, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			if !ok {
				filteredGroups = append(filteredGroups, rawGroup)
				continue
			}
			handlers, ok := group["hooks"].([]any)
			if !ok {
				filteredGroups = append(filteredGroups, rawGroup)
				continue
			}
			filteredHandlers := make([]any, 0, len(handlers))
			for _, rawHandler := range handlers {
				handler, ok := rawHandler.(map[string]any)
				if !ok {
					filteredHandlers = append(filteredHandlers, rawHandler)
					continue
				}
				command, _ := handler["command"].(string)
				if command == "" || !remove(command) {
					filteredHandlers = append(filteredHandlers, rawHandler)
				}
			}
			if len(filteredHandlers) > 0 {
				group["hooks"] = filteredHandlers
				filteredGroups = append(filteredGroups, group)
			}
		}
		if len(filteredGroups) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = filteredGroups
		}
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
}

func visitClaudeCommands(settings map[string]any, visit func(string)) {
	hooks, _ := settings["hooks"].(map[string]any)
	for _, rawGroups := range hooks {
		groups, _ := rawGroups.([]any)
		for _, rawGroup := range groups {
			group, _ := rawGroup.(map[string]any)
			handlers, _ := group["hooks"].([]any)
			for _, rawHandler := range handlers {
				handler, _ := rawHandler.(map[string]any)
				if command, ok := handler["command"].(string); ok {
					visit(command)
				}
			}
		}
	}
}

func isMewsClaudeCommand(command string) bool {
	return strings.Contains(command, "notify") &&
		strings.Contains(command, "--source") &&
		strings.Contains(command, "claude-code")
}

func validateClaudeSettings(settings map[string]any) error {
	if settings == nil {
		return fmt.Errorf("top-level value must be an object")
	}
	rawHooks, exists := settings["hooks"]
	if !exists {
		return nil
	}
	hooks, ok := rawHooks.(map[string]any)
	if !ok {
		return fmt.Errorf("hooks must be an object")
	}
	for event, rawGroups := range hooks {
		groups, ok := rawGroups.([]any)
		if !ok {
			return fmt.Errorf("hooks.%s must be an array", event)
		}
		for index, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			if !ok {
				return fmt.Errorf("hooks.%s[%d] must be an object", event, index)
			}
			rawHandlers, exists := group["hooks"]
			if !exists {
				continue
			}
			handlers, ok := rawHandlers.([]any)
			if !ok {
				return fmt.Errorf("hooks.%s[%d].hooks must be an array", event, index)
			}
			for handlerIndex, rawHandler := range handlers {
				handler, ok := rawHandler.(map[string]any)
				if !ok {
					return fmt.Errorf(
						"hooks.%s[%d].hooks[%d] must be an object",
						event, index, handlerIndex,
					)
				}
				if command, exists := handler["command"]; exists {
					if _, ok := command.(string); !ok {
						return fmt.Errorf(
							"hooks.%s[%d].hooks[%d].command must be a string",
							event, index, handlerIndex,
						)
					}
				}
			}
		}
	}
	return nil
}
