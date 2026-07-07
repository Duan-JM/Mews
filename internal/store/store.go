package store

import (
	"os"
	"path/filepath"
)

type StorePaths struct {
	AppSupport string
	Logs       string
	Config     string
	Events     string
	Socket     string
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

