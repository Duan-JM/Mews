package integrations

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Duan-JM/mews/internal/store"
)

const (
	codexMarkerStart = "# >>> mews managed notify >>>"
	codexMarkerEnd   = "# <<< mews managed notify <<<"
)

type codexInstallContext struct {
	path          string
	writePath     string
	current       []byte
	mode          os.FileMode
	created       bool
	currentBackup string
}

func CodexConfigPath() (string, error) {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "config.toml"), nil
}

func installCodex(mwPath string, previous *store.IntegrationState) (store.IntegrationState, error) {
	ctx, err := prepareCodexInstall(previous)
	if err != nil {
		return store.IntegrationState{}, err
	}
	installed := false
	defer func() {
		if !installed && ctx.currentBackup != "" {
			_ = os.Remove(ctx.currentBackup)
		}
	}()

	command := codexNotifyLine(mwPath)
	updated, err := installCodexBlock(ctx.current, command)
	if err != nil {
		return store.IntegrationState{}, fmt.Errorf("%s: %w", ctx.path, err)
	}
	if !ctx.created {
		ctx.currentBackup, err = backupFile("codex", ctx.writePath)
		if err != nil {
			return store.IntegrationState{}, err
		}
	}
	if err := writeFileAtomic(ctx.writePath, updated, ctx.mode); err != nil {
		return store.IntegrationState{}, err
	}
	installed = true
	backupPath := ctx.currentBackup
	var rollbackPath string
	if previous != nil {
		backupPath = previous.BackupPath
		ctx.created = previous.Created
		rollbackPath = ctx.currentBackup
	}
	return store.IntegrationState{
		Name:         "codex",
		Path:         ctx.path,
		BackupPath:   backupPath,
		Created:      ctx.created,
		Managed:      []string{command},
		InstalledAt:  time.Now(),
		RollbackPath: rollbackPath,
	}, nil
}

func prepareCodexInstall(previous *store.IntegrationState) (codexInstallContext, error) {
	path, err := CodexConfigPath()
	if err != nil {
		return codexInstallContext{}, err
	}
	if err := ensureRecordedIntegrationPath(previous, path, "Codex", "CODEX_HOME"); err != nil {
		return codexInstallContext{}, err
	}
	writePath, err := resolveWritePath(path)
	if err != nil {
		return codexInstallContext{}, err
	}

	ctx := codexInstallContext{
		path:      path,
		writePath: writePath,
		mode:      0o600,
		created:   true,
	}

	data, err := os.ReadFile(writePath)
	if os.IsNotExist(err) {
		return ctx, nil
	}
	if err != nil {
		return codexInstallContext{}, err
	}

	ctx.current = data
	ctx.created = false
	info, err := os.Stat(writePath)
	if err != nil {
		return codexInstallContext{}, err
	}
	ctx.mode = info.Mode().Perm()
	return ctx, nil
}

func removeCodex(state store.IntegrationState) error {
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
	updated, found, err := removeCodexBlock(data)
	if err != nil {
		return err
	}
	if !found {
		return nil
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
	path, err := CodexConfigPath()
	if err != nil {
		return fmt.Sprintf("path error: %v", err), false
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return "notify integration not installed", false
	}
	if err != nil {
		return fmt.Sprintf("unreadable: %v", err), false
	}
	block, found, err := codexBlock(data)
	if err != nil {
		return err.Error(), false
	}
	if !found || !strings.Contains(block, `"hook", "codex"`) {
		if _, err := installCodexBlock(data, codexNotifyLine("/path/to/mw")); err != nil {
			return fmt.Sprintf("not safely editable: %v", err), false
		}
		return "Mews notify integration not installed", false
	}
	return "notify integration installed", true
}

func codexNotifyLine(mwPath string) string {
	parts := []string{mwPath, "hook", "codex"}
	for i, part := range parts {
		parts[i] = strconv.Quote(part)
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
	withoutManaged, _, err := removeCodexBlock(data)
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

func removeCodexBlock(data []byte) ([]byte, bool, error) {
	lines := strings.Split(string(data), "\n")
	start := -1
	end := -1
	for index, line := range lines {
		switch strings.TrimSpace(line) {
		case codexMarkerStart:
			if start >= 0 {
				return nil, false, fmt.Errorf("multiple Mews marker blocks found")
			}
			start = index
		case codexMarkerEnd:
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

func codexBlock(data []byte) (string, bool, error) {
	lines := strings.Split(string(data), "\n")
	start := -1
	for index, line := range lines {
		switch strings.TrimSpace(line) {
		case codexMarkerStart:
			if start >= 0 {
				return "", false, fmt.Errorf("multiple Mews marker blocks found")
			}
			start = index
		case codexMarkerEnd:
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
