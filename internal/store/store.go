package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type StorePaths struct {
	AppSupport string
	Logs       string
	Config     string
	Events     string
	Socket     string
}

type SetupState struct {
	Version          int       `json:"version"`
	SetupAt          time.Time `json:"setup_at"`
	Agent            string    `json:"agent"`
	Copilot          string    `json:"copilot"`
	CopilotHook      string    `json:"copilot_hook,omitempty"`
	IncludeTaskTitle bool      `json:"include_task_title,omitempty"`
	Claude           string    `json:"claude"`
	UndoReady        bool      `json:"undo_ready"`
}

func Paths() (StorePaths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return StorePaths{}, err
	}

	appSupport := filepath.Join(home, "Library", "Application Support", "Mews")
	logs := filepath.Join(home, "Library", "Logs", "Mews")

	return StorePaths{
		AppSupport: appSupport,
		Logs:       logs,
		Config:     filepath.Join(appSupport, "config.json"),
		Events:     filepath.Join(appSupport, "events.jsonl"),
		Socket:     filepath.Join(appSupport, "mews.sock"),
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
	return os.WriteFile(paths.Config, data, 0o600)
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
	return nil
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
