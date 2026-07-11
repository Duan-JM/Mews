package integrations

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/Duan-JM/mews/internal/store"
)

type Result struct {
	Name   string
	Status string
	OK     bool
}

func InstallAll(mwPath string) ([]store.IntegrationState, error) {
	previousState, _, err := store.LoadIntegrationState()
	if err != nil {
		return nil, err
	}
	setupState, setupConfigured, err := store.LoadSetupState()
	if err != nil {
		return nil, err
	}
	previous := make(map[string]*store.IntegrationState, len(previousState.Integrations))
	for index := range previousState.Integrations {
		integration := &previousState.Integrations[index]
		previous[integration.Name] = integration
	}

	installers := []struct {
		name    string
		install func(string, *store.IntegrationState) (store.IntegrationState, error)
	}{
		{name: "copilot", install: func(path string, previous *store.IntegrationState) (store.IntegrationState, error) {
			hookPath, pathErr := CopilotHookPath()
			if pathErr != nil {
				return store.IntegrationState{}, pathErr
			}
			allowLegacy := previous == nil && setupConfigured && setupState.CopilotHook == hookPath
			state, _, err := installCopilot(path, previous, allowLegacy)
			return state, err
		}},
		{name: "claude-code", install: installClaude},
		{name: "codex", install: installCodex},
	}

	var installed []store.IntegrationState
	for _, installer := range installers {
		state, err := installer.install(mwPath, previous[installer.name])
		if err != nil {
			rollbackInstall(installed)
			return nil, err
		}
		installed = append(installed, state)
	}

	state := store.IntegrationStateFile{Version: 1, Integrations: installed}
	if err := store.SaveIntegrationState(state); err != nil {
		rollbackInstall(installed)
		return nil, err
	}
	for _, integration := range installed {
		if integration.RollbackPath != "" {
			_ = os.Remove(integration.RollbackPath)
		}
	}
	return installed, nil
}

func UndoAll() error {
	state, configured, err := store.LoadIntegrationState()
	if err != nil {
		return err
	}
	if !configured {
		return RemoveCopilotHooks()
	}

	for i := len(state.Integrations) - 1; i >= 0; i-- {
		integration := state.Integrations[i]
		switch integration.Name {
		case "copilot":
			err = removeCopilot(integration)
		case "claude-code":
			err = removeClaude(integration)
		case "codex":
			err = removeCodex(integration)
		default:
			err = fmt.Errorf("unknown integration %q", integration.Name)
		}
		if err != nil {
			return fmt.Errorf("remove %s integration: %w", integration.Name, err)
		}
		state.Integrations = state.Integrations[:i]
		if len(state.Integrations) > 0 {
			if err := store.SaveIntegrationState(state); err != nil {
				return err
			}
		} else if err := store.RemoveIntegrationState(); err != nil {
			return err
		}
		if integration.BackupPath != "" {
			if err := os.Remove(integration.BackupPath); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
	}
	return nil
}

func Statuses() []Result {
	claudeStatus, claudeOK := ClaudeStatus()
	codexStatus, codexOK := CodexStatus()
	copilotStatus, copilotOK := CopilotHookStatus()
	return []Result{
		{Name: "Claude Code", Status: claudeStatus, OK: claudeOK},
		{Name: "Codex", Status: codexStatus, OK: codexOK},
		{Name: "Copilot CLI", Status: copilotStatus, OK: copilotOK},
	}
}

func rollbackInstall(installed []store.IntegrationState) {
	for i := len(installed) - 1; i >= 0; i-- {
		integration := installed[i]
		if integration.RollbackPath != "" {
			rollback := integration
			rollback.BackupPath = integration.RollbackPath
			_ = restoreBackup(rollback)
			_ = os.Remove(integration.RollbackPath)
			continue
		}
		if integration.BackupPath != "" {
			_ = restoreBackup(integration)
			_ = os.Remove(integration.BackupPath)
			continue
		}
		if integration.Created {
			_ = os.Remove(integration.Path)
		}
	}
}

func backupFile(name, path string) (string, error) {
	paths, err := store.Ensure()
	if err != nil {
		return "", err
	}
	source, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer source.Close()

	info, err := source.Stat()
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256([]byte(path))
	target, err := os.CreateTemp(paths.Backups, fmt.Sprintf("%s-%x-*.bak", name, hash[:8]))
	if err != nil {
		return "", err
	}
	backupPath := target.Name()
	if err := target.Chmod(info.Mode().Perm()); err != nil {
		target.Close()
		os.Remove(backupPath)
		return "", err
	}
	if _, err := io.Copy(target, source); err != nil {
		target.Close()
		os.Remove(backupPath)
		return "", err
	}
	if err := target.Close(); err != nil {
		os.Remove(backupPath)
		return "", err
	}
	return backupPath, nil
}

func restoreBackup(integration store.IntegrationState) error {
	if integration.BackupPath == "" {
		if integration.Created {
			return os.Remove(integration.Path)
		}
		return nil
	}
	data, err := os.ReadFile(integration.BackupPath)
	if err != nil {
		return err
	}
	info, err := os.Stat(integration.BackupPath)
	if err != nil {
		return err
	}
	writePath, err := resolveWritePath(integration.Path)
	if err != nil {
		return err
	}
	return writeFileAtomic(writePath, data, info.Mode().Perm())
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".mews-*")
	if err != nil {
		return err
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)
	if err := file.Chmod(mode); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

func resolveWritePath(path string) (string, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return path, nil
	}
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return path, nil
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve config symlink %s: %w", path, err)
	}
	target, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !target.Mode().IsRegular() {
		return "", fmt.Errorf("config symlink target is not a regular file: %s", resolved)
	}
	return resolved, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
