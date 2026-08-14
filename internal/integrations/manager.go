package integrations

import (
	"crypto/sha256"
	"errors"
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
	copilotStateDisabled, err := store.CopilotHookStateDisabled()
	if err != nil {
		return nil, err
	}
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
			state, err := installCopilot(path, previous, allowLegacy)
			return state, err
		}},
		{name: "claude-code", install: installClaude},
		{name: "codex", install: installCodex},
	}

	var installed []store.IntegrationState
	for _, installer := range installers {
		state, err := installer.install(mwPath, previous[installer.name])
		if err != nil {
			rollbackErr := rollbackInstall(installed)
			return nil, restoreCopilotHookState(copilotStateDisabled, errors.Join(err, rollbackErr))
		}
		installed = append(installed, state)
	}

	state := store.IntegrationStateFile{Version: 1, Integrations: installed}
	if err := store.SaveIntegrationState(state); err != nil {
		rollbackErr := rollbackInstall(installed)
		return nil, restoreCopilotHookState(copilotStateDisabled, errors.Join(err, rollbackErr))
	}
	for index := range installed {
		integration := &installed[index]
		if integration.RollbackPath != "" {
			_ = os.Remove(integration.RollbackPath)
		}
		for _, file := range integration.RollbackFiles {
			if file.BackupPath != "" {
				_ = os.Remove(file.BackupPath)
			}
		}
	}
	return installed, nil
}

func restoreCopilotHookState(disabled bool, installErr error) error {
	if !disabled {
		return installErr
	}
	if err := store.RemoveCopilotHookState(); err != nil {
		return fmt.Errorf("%w; restore Copilot hook state: %v", installErr, err)
	}
	return installErr
}

func UndoAll() error {
	state, configured, err := store.LoadIntegrationState()
	if err != nil {
		return err
	}
	if !configured {
		return undoUnrecordedCopilot()
	}

	for i := len(state.Integrations) - 1; i >= 0; i-- {
		integration := state.Integrations[i]
		if err := removeIntegration(integration); err != nil {
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
		if err := removeIntegrationBackups(integration); err != nil {
			return err
		}
	}
	return store.RemoveCopilotHookState()
}

func removeIntegration(integration store.IntegrationState) error {
	switch integration.Name {
	case "copilot":
		return removeCopilot(integration)
	case "claude-code":
		return removeClaude(integration)
	case "codex":
		return removeCodex(integration)
	default:
		return fmt.Errorf("unknown integration %q", integration.Name)
	}
}

func removeIntegrationBackups(integration store.IntegrationState) error {
	if err := removeBackupFile(integration.BackupPath); err != nil {
		return err
	}
	for index := range integration.AdditionalFiles {
		if err := removeBackupFile(integration.AdditionalFiles[index].BackupPath); err != nil {
			return err
		}
	}
	return nil
}

func removeBackupFile(path string) error {
	if path == "" {
		return nil
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func undoUnrecordedCopilot() error {
	if err := RemoveCopilotHooks(); err != nil {
		return err
	}
	return store.RemoveCopilotHookState()
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

func rollbackInstall(installed []store.IntegrationState) error {
	var rollbackErr error
	for i := len(installed) - 1; i >= 0; i-- {
		integration := installed[i]
		primary := store.IntegrationFileState{
			Path:       integration.Path,
			BackupPath: integration.BackupPath,
			Created:    integration.Created,
		}
		if integration.RollbackPath != "" {
			primary.BackupPath = integration.RollbackPath
			primary.Created = false
		}
		if err := restoreIntegrationFile(primary); err != nil {
			rollbackErr = errors.Join(rollbackErr, fmt.Errorf("restore %s: %w", primary.Path, err))
		} else if err := removeBackupFile(primary.BackupPath); err != nil {
			rollbackErr = errors.Join(rollbackErr, err)
		}

		files := integration.AdditionalFiles
		if len(integration.RollbackFiles) > 0 {
			files = integration.RollbackFiles
		}
		for index := range files {
			file := files[index]
			if err := restoreIntegrationFile(file); err != nil {
				rollbackErr = errors.Join(rollbackErr, fmt.Errorf("restore %s: %w", file.Path, err))
			} else if err := removeBackupFile(file.BackupPath); err != nil {
				rollbackErr = errors.Join(rollbackErr, err)
			}
		}
	}
	return rollbackErr
}

func ensureRecordedIntegrationPath(previous *store.IntegrationState, path, name, envVar string) error {
	if previous == nil || previous.Path == path {
		return nil
	}

	return fmt.Errorf(
		"configured %s integration is recorded at %s; run `mw undo` before changing %s",
		name,
		previous.Path,
		envVar,
	)
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
	return restoreIntegrationFile(store.IntegrationFileState{
		Path:       integration.Path,
		BackupPath: integration.BackupPath,
		Created:    integration.Created,
	})
}

func restoreIntegrationFile(file store.IntegrationFileState) error {
	if file.BackupPath == "" {
		if file.Created {
			if err := os.Remove(file.Path); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
		return nil
	}
	data, err := os.ReadFile(file.BackupPath)
	if err != nil {
		return err
	}
	info, err := os.Stat(file.BackupPath)
	if err != nil {
		return err
	}
	writePath, err := resolveWritePath(file.Path)
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
