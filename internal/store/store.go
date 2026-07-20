package store

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"time"
)

type StorePaths struct {
	AppSupport         string
	Logs               string
	Config             string
	Events             string
	Integrations       string
	Backups            string
	CopilotHooks       string
	NotificationStatus string
	SocketDir          string
	Socket             string
}

type SetupState struct {
	Version          int       `json:"version"`
	SetupAt          time.Time `json:"setup_at"`
	Agent            string    `json:"agent"`
	Copilot          string    `json:"copilot"`
	CopilotHook      string    `json:"copilot_hook,omitempty"`
	IncludeTaskTitle bool      `json:"include_task_title,omitempty"`
	Terminal         string    `json:"terminal,omitempty"`
	Claude           string    `json:"claude"`
	UndoReady        bool      `json:"undo_ready"`
}

type IntegrationState struct {
	Name         string    `json:"name"`
	Path         string    `json:"path"`
	BackupPath   string    `json:"backup_path,omitempty"`
	Created      bool      `json:"created,omitempty"`
	Managed      []string  `json:"managed,omitempty"`
	InstalledAt  time.Time `json:"installed_at"`
	RollbackPath string    `json:"-"`
}

type IntegrationStateFile struct {
	Version      int                `json:"version"`
	Integrations []IntegrationState `json:"integrations"`
}

func Paths() (StorePaths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return StorePaths{}, err
	}

	appSupport := filepath.Join(home, "Library", "Application Support", "Mews")
	logs := filepath.Join(home, "Library", "Logs", "Mews")
	socketDir := appSupport
	socket := filepath.Join(socketDir, "mews.sock")
	if len(socket) >= 100 {
		name := fmt.Sprintf("mews-%d", os.Getuid())
		if namespace := os.Getenv("MEWS_SOCKET_NAMESPACE"); namespace != "" {
			namespaceHash := fnv.New64a()
			_, _ = namespaceHash.Write([]byte(namespace))
			name = fmt.Sprintf("%s-%x", name, namespaceHash.Sum64())
		}
		socketDir = filepath.Join(os.TempDir(), name)
		socket = filepath.Join(socketDir, "mews.sock")
	}

	return StorePaths{
		AppSupport:         appSupport,
		Logs:               logs,
		Config:             filepath.Join(appSupport, "config.json"),
		Events:             filepath.Join(appSupport, "events.jsonl"),
		Integrations:       filepath.Join(appSupport, "integrations.json"),
		Backups:            filepath.Join(appSupport, "backups"),
		CopilotHooks:       filepath.Join(appSupport, "copilot-hooks"),
		NotificationStatus: filepath.Join(appSupport, "notification-status.json"),
		SocketDir:          socketDir,
		Socket:             socket,
	}, nil
}

func Ensure() (StorePaths, error) {
	paths, err := Paths()
	if err != nil {
		return StorePaths{}, err
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		return StorePaths{}, err
	}
	if err := os.MkdirAll(paths.Logs, 0o700); err != nil {
		return StorePaths{}, err
	}
	if err := os.MkdirAll(paths.Backups, 0o700); err != nil {
		return StorePaths{}, err
	}
	if err := ensureCopilotHookDirectory(paths.CopilotHooks); err != nil {
		return StorePaths{}, err
	}
	if err := os.MkdirAll(paths.SocketDir, 0o700); err != nil {
		return StorePaths{}, err
	}
	if err := os.Chmod(paths.SocketDir, 0o700); err != nil {
		return StorePaths{}, err
	}
	return paths, nil
}

func LoadSetupState() (SetupState, bool, error) {
	paths, err := Paths()
	if err != nil {
		return SetupState{}, false, err
	}

	data, err := os.ReadFile(paths.Config)
	if os.IsNotExist(err) {
		return SetupState{}, false, nil
	}
	if err != nil {
		return SetupState{}, false, err
	}

	var state SetupState
	if err := json.Unmarshal(data, &state); err != nil {
		return SetupState{}, false, err
	}
	return state, true, nil
}

func SaveSetupState(state SetupState) error {
	paths, err := Ensure()
	if err != nil {
		return err
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeFileAtomic(paths.Config, data, 0o600)
}

func RemoveSetupState() error {
	paths, err := Paths()
	if err != nil {
		return err
	}

	if err := os.Remove(paths.Config); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func LoadIntegrationState() (IntegrationStateFile, bool, error) {
	paths, err := Paths()
	if err != nil {
		return IntegrationStateFile{}, false, err
	}

	data, err := os.ReadFile(paths.Integrations)
	if os.IsNotExist(err) {
		return IntegrationStateFile{}, false, nil
	}
	if err != nil {
		return IntegrationStateFile{}, false, err
	}

	var state IntegrationStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		return IntegrationStateFile{}, false, err
	}
	if state.Version != 1 {
		return IntegrationStateFile{}, false, fmt.Errorf("unsupported integration state version %d", state.Version)
	}
	return state, true, nil
}

func SaveIntegrationState(state IntegrationStateFile) error {
	paths, err := Ensure()
	if err != nil {
		return err
	}
	state.Version = 1

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeFileAtomic(paths.Integrations, data, 0o600)
}

func RemoveIntegrationState() error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	if err := os.Remove(paths.Integrations); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func Reset() error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	if err := os.RemoveAll(paths.AppSupport); err != nil {
		return err
	}
	if err := os.RemoveAll(paths.Logs); err != nil {
		return err
	}
	if paths.SocketDir != paths.AppSupport {
		if err := os.RemoveAll(paths.SocketDir); err != nil {
			return err
		}
	}
	return nil
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

func AppendEventJSON(data []byte) error {
	paths, err := Ensure()
	if err != nil {
		return err
	}

	file, err := os.OpenFile(paths.Events, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := file.Write(data); err != nil {
		return err
	}
	if _, err := file.Write([]byte("\n")); err != nil {
		return err
	}
	return nil
}
