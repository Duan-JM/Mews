package integrations

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Duan-JM/mews/internal/store"
)

const (
	codexMarkerStart = "# >>> mews managed notify >>>"
	codexMarkerEnd   = "# <<< mews managed notify <<<"
	codexTrustStart  = "# >>> mews managed hooks trust >>>"
	codexTrustEnd    = "# <<< mews managed hooks trust <<<"
)

type codexHook struct {
	event   string
	status  string
	message string
	timeout int
}

type codexFileContext struct {
	path          string
	writePath     string
	current       []byte
	mode          os.FileMode
	created       bool
	currentBackup string
}

type codexHookReference struct {
	key  string
	hash string
}

var codexHooks = []codexHook{
	{event: "SessionStart", status: "idle", message: "Codex session started", timeout: 5},
	{event: "UserPromptSubmit", status: "running", message: "Codex is running", timeout: 5},
	{event: "Stop", status: "done", message: "Codex finished", timeout: 5},
	{event: "SessionEnd", status: "idle", message: "Codex session ended", timeout: 3},
}

func CodexConfigPath() (string, error) {
	home, err := codexHome()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "config.toml"), nil
}

func CodexHooksPath() (string, error) {
	home, err := codexHome()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "hooks.json"), nil
}

func codexHome() (string, error) {
	if home := os.Getenv("CODEX_HOME"); home != "" {
		return home, nil
	}
	userHome, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(userHome, ".codex"), nil
}

func installCodex(mwPath string, previous *store.IntegrationState) (store.IntegrationState, error) {
	hooksPath, configPath, err := codexInstallPaths(previous)
	if err != nil {
		return store.IntegrationState{}, err
	}

	hooksContext, configContext, err := prepareCodexFiles(hooksPath, configPath)
	if err != nil {
		return store.IntegrationState{}, err
	}
	installed := false
	preserveTemporaryBackups := false
	defer func() {
		if !installed && !preserveTemporaryBackups {
			removeTemporaryBackup(hooksContext)
			removeTemporaryBackup(configContext)
		}
	}()

	hooksDocument, err := parseCodexHooks(hooksContext.path, hooksContext.current)
	if err != nil {
		return store.IntegrationState{}, err
	}
	removeRecordedCodexCommands(hooksDocument, previous)
	managed, references, err := appendCodexHooks(hooksDocument, hooksContext.path, mwPath)
	if err != nil {
		return store.IntegrationState{}, err
	}
	hooksData, err := json.MarshalIndent(hooksDocument, "", "  ")
	if err != nil {
		return store.IntegrationState{}, err
	}
	hooksData = append(hooksData, '\n')

	configData, err := installCodexTrustBlock(configContext.current, references)
	if err != nil {
		return store.IntegrationState{}, fmt.Errorf("%s: %w", configContext.path, err)
	}
	preserveTemporaryBackups, err = writeCodexFiles(
		hooksContext,
		configContext,
		hooksData,
		configData,
	)
	if err != nil {
		return store.IntegrationState{}, err
	}
	installed = true

	hooksState, configState := codexPersistedFiles(previous, hooksContext, configContext)
	var rollbackPath string
	var rollbackFiles []store.IntegrationFileState
	if previous != nil {
		rollbackPath = hooksContext.currentBackup
		rollbackFiles = []store.IntegrationFileState{{
			Path:       configContext.path,
			BackupPath: configContext.currentBackup,
			Created:    configContext.created,
		}}
	}
	return store.IntegrationState{
		Name:            "codex",
		Path:            hooksState.Path,
		BackupPath:      hooksState.BackupPath,
		Created:         hooksState.Created,
		Managed:         managed,
		AdditionalFiles: []store.IntegrationFileState{configState},
		InstalledAt:     time.Now(),
		RollbackPath:    rollbackPath,
		RollbackFiles:   rollbackFiles,
	}, nil
}

func writeCodexFiles(
	hooksContext codexFileContext,
	configContext codexFileContext,
	hooksData []byte,
	configData []byte,
) (bool, error) {
	if err := writeFileAtomic(hooksContext.writePath, hooksData, hooksContext.mode); err != nil {
		return false, err
	}
	if err := writeFileAtomic(configContext.writePath, configData, configContext.mode); err != nil {
		if restoreErr := restoreCodexContext(hooksContext); restoreErr != nil {
			return true, fmt.Errorf(
				"write %s: %w; restore %s from %s: %v",
				configContext.path,
				err,
				hooksContext.path,
				hooksContext.currentBackup,
				restoreErr,
			)
		}
		return false, err
	}
	return false, nil
}

func codexInstallPaths(previous *store.IntegrationState) (string, string, error) {
	hooksPath, err := CodexHooksPath()
	if err != nil {
		return "", "", err
	}
	configPath, err := CodexConfigPath()
	if err != nil {
		return "", "", err
	}
	if err := validateCodexRecordedPaths(previous, hooksPath, configPath); err != nil {
		return "", "", err
	}
	return hooksPath, configPath, nil
}

func prepareCodexFiles(hooksPath, configPath string) (codexFileContext, codexFileContext, error) {
	hooksContext, err := prepareCodexFile(hooksPath, "codex-hooks")
	if err != nil {
		return codexFileContext{}, codexFileContext{}, err
	}
	configContext, err := prepareCodexFile(configPath, "codex-config")
	if err != nil {
		removeTemporaryBackup(hooksContext)
		return codexFileContext{}, codexFileContext{}, err
	}
	return hooksContext, configContext, nil
}

func validateCodexRecordedPaths(previous *store.IntegrationState, hooksPath, configPath string) error {
	if previous == nil {
		return nil
	}
	if previous.Path == hooksPath {
		for _, file := range previous.AdditionalFiles {
			if file.Path == configPath {
				return nil
			}
		}
		return fmt.Errorf("configured Codex hooks are missing recorded config state; run `mw undo`")
	}
	if previous.Path == configPath && len(previous.AdditionalFiles) == 0 {
		return nil
	}
	return fmt.Errorf(
		"configured Codex integration is recorded at %s; run `mw undo` before changing CODEX_HOME",
		previous.Path,
	)
}

func prepareCodexFile(path, backupName string) (codexFileContext, error) {
	writePath, err := resolveWritePath(path)
	if err != nil {
		return codexFileContext{}, err
	}
	context := codexFileContext{
		path:      path,
		writePath: writePath,
		mode:      0o600,
		created:   true,
	}
	data, err := os.ReadFile(writePath)
	if os.IsNotExist(err) {
		return context, nil
	}
	if err != nil {
		return codexFileContext{}, err
	}
	info, err := os.Stat(writePath)
	if err != nil {
		return codexFileContext{}, err
	}
	context.current = data
	context.mode = info.Mode().Perm()
	context.created = false
	context.currentBackup, err = backupFile(backupName, writePath)
	if err != nil {
		return codexFileContext{}, err
	}
	return context, nil
}

func removeTemporaryBackup(context codexFileContext) {
	if context.currentBackup != "" {
		_ = os.Remove(context.currentBackup)
	}
}

func restoreCodexContext(context codexFileContext) error {
	return restoreIntegrationFile(store.IntegrationFileState{
		Path:       context.path,
		BackupPath: context.currentBackup,
		Created:    context.created,
	})
}

func codexPersistedFiles(
	previous *store.IntegrationState,
	hooksContext codexFileContext,
	configContext codexFileContext,
) (store.IntegrationFileState, store.IntegrationFileState) {
	hooks := store.IntegrationFileState{
		Path:       hooksContext.path,
		BackupPath: hooksContext.currentBackup,
		Created:    hooksContext.created,
	}
	config := store.IntegrationFileState{
		Path:       configContext.path,
		BackupPath: configContext.currentBackup,
		Created:    configContext.created,
	}
	if previous == nil {
		return hooks, config
	}
	if previous.Path == hooksContext.path {
		hooks.BackupPath = previous.BackupPath
		hooks.Created = previous.Created
		for _, file := range previous.AdditionalFiles {
			if file.Path == configContext.path {
				config.BackupPath = file.BackupPath
				config.Created = file.Created
			}
		}
		return hooks, config
	}

	config.BackupPath = previous.BackupPath
	config.Created = previous.Created
	return hooks, config
}
