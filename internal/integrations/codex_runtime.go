package integrations

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Duan-JM/mews/internal/store"
)

func installCodexTrustBlock(data []byte, references []codexHookReference) ([]byte, error) {
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("config is not valid UTF-8")
	}
	if bytes.Contains(data, []byte(`"""`)) || bytes.Contains(data, []byte(`'''`)) {
		return nil, fmt.Errorf("multiline TOML strings are not edited automatically")
	}
	withoutNotify, _, err := removeCodexMarkedBlock(data, codexMarkerStart, codexMarkerEnd)
	if err != nil {
		return nil, err
	}
	withoutTrust, _, err := removeCodexMarkedBlock(withoutNotify, codexTrustStart, codexTrustEnd)
	if err != nil {
		return nil, err
	}

	var block strings.Builder
	block.WriteString(codexTrustStart)
	block.WriteByte('\n')
	for _, reference := range references {
		fmt.Fprintf(&block, "[hooks.state.%s]\n", strconv.Quote(reference.key))
		block.WriteString("enabled = true\n")
		fmt.Fprintf(&block, "trusted_hash = %s\n\n", strconv.Quote(reference.hash))
	}
	block.WriteString(codexTrustEnd)
	block.WriteByte('\n')

	trimmed := strings.TrimRight(string(withoutTrust), "\n")
	if trimmed == "" {
		return []byte(block.String()), nil
	}
	return []byte(trimmed + "\n\n" + block.String()), nil
}

func removeCodexMarkedBlock(data []byte, startMarker, endMarker string) ([]byte, bool, error) {
	lines := strings.Split(string(data), "\n")
	start := -1
	end := -1
	for index, line := range lines {
		switch strings.TrimSpace(line) {
		case startMarker:
			if start >= 0 {
				return nil, false, fmt.Errorf("multiple Mews marker blocks found")
			}
			start = index
		case endMarker:
			if start < 0 || end >= 0 {
				return nil, false, fmt.Errorf("unmatched Mews marker")
			}
			end = index
		}
	}
	if start < 0 && end < 0 {
		return data, false, nil
	}
	if start < 0 || end < start {
		return nil, false, fmt.Errorf("unmatched Mews marker")
	}
	updated := append([]string{}, lines[:start]...)
	after := lines[end+1:]
	if len(updated) > 0 && len(after) > 0 &&
		strings.TrimSpace(updated[len(updated)-1]) == "" &&
		strings.TrimSpace(after[0]) == "" {
		after = after[1:]
	}
	updated = append(updated, after...)
	return []byte(strings.Join(updated, "\n")), true, nil
}

func removeCodex(state store.IntegrationState) error {
	if state.Path == "" {
		return nil
	}
	if filepath.Base(state.Path) == "config.toml" && len(state.AdditionalFiles) == 0 {
		return removeLegacyCodex(state)
	}

	if err := removeCodexHooksFile(state); err != nil {
		return err
	}
	for _, file := range state.AdditionalFiles {
		if filepath.Base(file.Path) == "config.toml" {
			if err := removeCodexConfigFile(file); err != nil {
				return err
			}
		}
	}
	return nil
}

func removeCodexHooksFile(state store.IntegrationState) error {
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
	document, err := parseCodexHooks(state.Path, data)
	if err != nil {
		return err
	}
	managed := make(map[string]bool, len(state.Managed))
	for _, command := range state.Managed {
		managed[command] = true
	}
	removeCodexCommands(document, func(command string) bool {
		return managed[command]
	})
	if state.Created && len(document) == 0 {
		return os.Remove(state.Path)
	}
	info, err := os.Stat(writePath)
	if err != nil {
		return err
	}
	updated, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(writePath, append(updated, '\n'), info.Mode().Perm())
}

func removeCodexConfigFile(file store.IntegrationFileState) error {
	writePath, err := resolveWritePath(file.Path)
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
	updated, _, err := removeCodexMarkedBlock(data, codexTrustStart, codexTrustEnd)
	if err != nil {
		return err
	}
	updated, _, err = removeCodexMarkedBlock(updated, codexMarkerStart, codexMarkerEnd)
	if err != nil {
		return err
	}
	if file.Created && len(bytes.TrimSpace(updated)) == 0 {
		return os.Remove(file.Path)
	}
	info, err := os.Stat(writePath)
	if err != nil {
		return err
	}
	return writeFileAtomic(writePath, updated, info.Mode().Perm())
}

func removeLegacyCodex(state store.IntegrationState) error {
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
	updated, found, err := removeCodexMarkedBlock(data, codexMarkerStart, codexMarkerEnd)
	if err != nil || !found {
		return err
	}
	if state.Created && len(bytes.TrimSpace(updated)) == 0 {
		return os.Remove(state.Path)
	}
	info, err := os.Stat(writePath)
	if err != nil {
		return err
	}
	return writeFileAtomic(writePath, updated, info.Mode().Perm())
}

func CodexStatus() (string, bool) {
	hooksPath, err := CodexHooksPath()
	if err != nil {
		return fmt.Sprintf("path error: %v", err), false
	}
	data, err := os.ReadFile(hooksPath)
	if os.IsNotExist(err) {
		return "hooks not installed", false
	}
	if err != nil {
		return fmt.Sprintf("unreadable: %v", err), false
	}
	document, err := parseCodexHooks(hooksPath, data)
	if err != nil {
		return err.Error(), false
	}
	references, found := installedCodexReferences(document, hooksPath)
	if !found {
		return "Mews hooks not installed", false
	}
	configPath, err := CodexConfigPath()
	if err != nil {
		return fmt.Sprintf("path error: %v", err), false
	}
	config, err := os.ReadFile(configPath)
	if os.IsNotExist(err) {
		return "hooks installed but not trusted", false
	}
	if err != nil {
		return fmt.Sprintf("unreadable: %v", err), false
	}
	block, found, err := codexMarkedBlock(config, codexTrustStart, codexTrustEnd)
	if err != nil {
		return err.Error(), false
	}
	if !found || !codexTrustBlockMatches(block, references) {
		return "hooks installed but not trusted", false
	}
	return "hooks installed and trusted", true
}

func installedCodexReferences(
	document map[string]any,
	hooksPath string,
) ([]codexHookReference, bool) {
	hooks, ok := document["hooks"].(map[string]any)
	if !ok {
		return nil, false
	}
	references := make([]codexHookReference, 0, len(codexHooks))
	for _, hook := range codexHooks {
		groups, ok := hooks[hook.event].([]any)
		if !ok {
			return nil, false
		}
		found := false
		for groupIndex, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			if !ok {
				continue
			}
			handlers, ok := group["hooks"].([]any)
			if !ok {
				continue
			}
			for handlerIndex, rawHandler := range handlers {
				handler, ok := rawHandler.(map[string]any)
				if !ok || handler["type"] != "command" {
					continue
				}
				command, ok := handler["command"].(string)
				if !ok || !isMewsCodexCommand(command, hook.event) {
					continue
				}
				hash, err := codexHookHash(hook, command)
				if err != nil {
					return nil, false
				}
				references = append(references, codexHookReference{
					key: fmt.Sprintf(
						"%s:%s:%d:%d",
						hooksPath,
						codexHookEventLabel(hook.event),
						groupIndex,
						handlerIndex,
					),
					hash: hash,
				})
				found = true
			}
		}
		if !found {
			return nil, false
		}
	}
	return references, true
}

func isMewsCodexCommand(command, event string) bool {
	return strings.Contains(command, "'hook' 'codex' '"+event+"'") &&
		strings.HasSuffix(command, " >/dev/null")
}

func codexTrustBlockMatches(block string, references []codexHookReference) bool {
	for _, reference := range references {
		header := "[hooks.state." + strconv.Quote(reference.key) + "]"
		hash := "trusted_hash = " + strconv.Quote(reference.hash)
		if !codexTrustEntryMatches(block, header, hash) {
			return false
		}
	}
	return true
}

func codexTrustEntryMatches(block, header, hash string) bool {
	start := strings.Index(block, header)
	if start < 0 {
		return false
	}
	entry := block[start+len(header):]
	if end := strings.Index(entry, "\n[hooks.state."); end >= 0 {
		entry = entry[:end]
	}
	return strings.Contains(entry, "enabled = true") && strings.Contains(entry, hash)
}

func codexMarkedBlock(data []byte, startMarker, endMarker string) (string, bool, error) {
	lines := strings.Split(string(data), "\n")
	start := -1
	for index, line := range lines {
		switch strings.TrimSpace(line) {
		case startMarker:
			if start >= 0 {
				return "", false, fmt.Errorf("multiple Mews marker blocks found")
			}
			start = index
		case endMarker:
			if start < 0 {
				return "", false, fmt.Errorf("unmatched Mews marker")
			}
			return strings.Join(lines[start:index+1], "\n"), true, nil
		}
	}
	if start >= 0 {
		return "", false, fmt.Errorf("unmatched Mews marker")
	}
	return "", false, nil
}

func codexNotifyLine(mwPath string) string {
	parts := []string{mwPath, "hook", "codex"}
	for index, part := range parts {
		parts[index] = strconv.Quote(part)
	}
	return "notify = [" + strings.Join(parts, ", ") + "]"
}

func installCodexBlock(data []byte, notifyLine string) ([]byte, error) {
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("config is not valid UTF-8")
	}
	if bytes.Contains(data, []byte(`"""`)) || bytes.Contains(data, []byte(`'''`)) {
		return nil, fmt.Errorf("multiline TOML strings are not edited automatically")
	}
	withoutManaged, _, err := removeCodexMarkedBlock(data, codexMarkerStart, codexMarkerEnd)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(withoutManaged), "\n")
	insertAt := len(lines)
	for index, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "[") {
			insertAt = index
			break
		}
		key, _, ok := strings.Cut(trimmed, "=")
		if !ok {
			return nil, fmt.Errorf("config has an invalid top-level line %q", trimmed)
		}
		key = strings.TrimSpace(key)
		if strings.HasPrefix(key, `"`) || strings.HasPrefix(key, `'`) {
			return nil, fmt.Errorf("quoted top-level TOML keys are not edited automatically")
		}
		if key == "notify" {
			return nil, fmt.Errorf("top-level notify is already configured and was left unchanged")
		}
	}

	block := []string{codexMarkerStart, notifyLine, codexMarkerEnd, ""}
	updated := append([]string{}, lines[:insertAt]...)
	if len(updated) > 0 && strings.TrimSpace(updated[len(updated)-1]) != "" {
		updated = append(updated, "")
	}
	updated = append(updated, block...)
	updated = append(updated, lines[insertAt:]...)
	return []byte(strings.TrimLeft(strings.Join(updated, "\n"), "\n")), nil
}
