package integrations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/Duan-JM/mews/internal/store"
)

func parseCodexHooks(path string, data []byte) (map[string]any, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return map[string]any{}, nil
	}
	var document map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("%s is malformed JSON: %w", path, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			err = fmt.Errorf("multiple JSON values")
		}
		return nil, fmt.Errorf("%s is malformed JSON: %w", path, err)
	}
	if err := validateCodexHooks(document); err != nil {
		return nil, fmt.Errorf("%s has invalid hook structure: %w", path, err)
	}
	return document, nil
}

func validateCodexHooks(document map[string]any) error {
	rawHooks, exists := document["hooks"]
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
		for _, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			if !ok {
				return fmt.Errorf("hooks.%s entries must be objects", event)
			}
			rawHandlers, ok := group["hooks"]
			if !ok {
				return fmt.Errorf("hooks.%s entry has no hooks", event)
			}
			handlers, ok := rawHandlers.([]any)
			if !ok {
				return fmt.Errorf("hooks.%s entry hooks must be an array", event)
			}
			for _, rawHandler := range handlers {
				handler, ok := rawHandler.(map[string]any)
				if !ok {
					return fmt.Errorf("hooks.%s handlers must be objects", event)
				}
				if handler["type"] == "command" {
					if _, ok := handler["command"].(string); !ok {
						return fmt.Errorf("hooks.%s command handler has no command", event)
					}
				}
			}
		}
	}
	return nil
}

func removeRecordedCodexCommands(document map[string]any, previous *store.IntegrationState) {
	if previous == nil {
		return
	}
	managed := make(map[string]bool, len(previous.Managed))
	for _, command := range previous.Managed {
		managed[command] = true
	}
	removeCodexCommands(document, func(command string) bool {
		return managed[command]
	})
}

func removeCodexCommands(document map[string]any, remove func(string) bool) {
	hooks, ok := document["hooks"].(map[string]any)
	if !ok {
		return
	}
	for event, rawGroups := range hooks {
		groups, ok := rawGroups.([]any)
		if !ok {
			continue
		}
		keptGroups := make([]any, 0, len(groups))
		for _, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			if !ok {
				keptGroups = append(keptGroups, rawGroup)
				continue
			}
			handlers, ok := group["hooks"].([]any)
			if !ok {
				keptGroups = append(keptGroups, rawGroup)
				continue
			}
			keptHandlers := handlers[:0]
			for _, rawHandler := range handlers {
				handler, ok := rawHandler.(map[string]any)
				command, commandOK := handler["command"].(string)
				if ok && commandOK && remove(command) {
					continue
				}
				keptHandlers = append(keptHandlers, rawHandler)
			}
			if len(keptHandlers) == 0 {
				continue
			}
			group["hooks"] = keptHandlers
			keptGroups = append(keptGroups, group)
		}
		if len(keptGroups) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = keptGroups
		}
	}
	if len(hooks) == 0 {
		delete(document, "hooks")
	}
}

func appendCodexHooks(
	document map[string]any,
	hooksPath string,
	mwPath string,
) ([]string, []codexHookReference, error) {
	hooks, _ := document["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		document["hooks"] = hooks
	}
	managed := make([]string, 0, len(codexHooks))
	references := make([]codexHookReference, 0, len(codexHooks))
	for _, hook := range codexHooks {
		command := codexCommand(mwPath, hook)
		groups, _ := hooks[hook.event].([]any)
		groupIndex := len(groups)
		handler := map[string]any{
			"type":    "command",
			"command": command,
			"timeout": hook.timeout,
		}
		group := map[string]any{"hooks": []any{handler}}
		hooks[hook.event] = append(groups, group)
		hash, err := codexHookHash(hook, command)
		if err != nil {
			return nil, nil, err
		}
		managed = append(managed, command)
		references = append(references, codexHookReference{
			key: fmt.Sprintf(
				"%s:%s:%d:0",
				hooksPath,
				codexHookEventLabel(hook.event),
				groupIndex,
			),
			hash: hash,
		})
	}
	return managed, references, nil
}

func codexCommand(mwPath string, hook codexHook) string {
	parts := []string{mwPath, "hook", "codex", hook.event}
	for index, part := range parts {
		parts[index] = shellQuote(part)
	}
	return strings.Join(parts, " ") + " >/dev/null"
}

func codexHookHash(hook codexHook, command string) (string, error) {
	identity := map[string]any{
		"event_name": codexHookEventLabel(hook.event),
		"hooks": []any{map[string]any{
			"async":   false,
			"command": command,
			"timeout": hook.timeout,
			"type":    "command",
		}},
	}
	var serialized bytes.Buffer
	encoder := json.NewEncoder(&serialized)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(identity); err != nil {
		return "", err
	}
	sum := sha256.Sum256(bytes.TrimSuffix(serialized.Bytes(), []byte{'\n'}))
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

func codexHookEventLabel(event string) string {
	switch event {
	case "SessionStart":
		return "session_start"
	case "UserPromptSubmit":
		return "user_prompt_submit"
	case "Stop":
		return "stop"
	case "SessionEnd":
		return "session_end"
	default:
		return strings.ToLower(event)
	}
}
