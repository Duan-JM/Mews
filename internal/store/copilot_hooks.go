package store

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func MarkCopilotSubagent(sessionID, transcriptPath string) error {
	paths, err := Ensure()
	if err != nil {
		return err
	}
	sessionDir, markerPath, err := copilotHookPaths(paths, sessionID, transcriptPath)
	if err != nil {
		return err
	}
	if err := ensureCopilotHookDirectory(sessionDir); err != nil {
		return err
	}
	return writeFileAtomic(markerPath, []byte("subagent\n"), 0o600)
}

func IsCopilotSubagent(sessionID, transcriptPath string) (bool, error) {
	if strings.TrimSpace(sessionID) == "" || strings.TrimSpace(transcriptPath) == "" {
		return false, nil
	}
	paths, err := Paths()
	if err != nil {
		return false, err
	}
	exists, err := copilotHookDirectoryExists(paths.CopilotHooks)
	if err != nil || !exists {
		return false, err
	}
	sessionDir, markerPath, err := copilotHookPaths(paths, sessionID, transcriptPath)
	if err != nil {
		return false, err
	}
	exists, err = copilotHookDirectoryExists(sessionDir)
	if err != nil || !exists {
		return false, err
	}
	if _, err := os.Stat(markerPath); os.IsNotExist(err) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	return true, nil
}

func ClearCopilotHookSession(sessionID string) error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	exists, err := copilotHookDirectoryExists(paths.CopilotHooks)
	if err != nil || !exists {
		return err
	}
	sessionKey, err := copilotHookKey("session_id", sessionID)
	if err != nil {
		return err
	}
	sessionDir := filepath.Join(paths.CopilotHooks, sessionKey)
	exists, err = copilotHookDirectoryExists(sessionDir)
	if err != nil || !exists {
		return err
	}
	return os.RemoveAll(sessionDir)
}

func RemoveCopilotHookState() error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	exists, err := copilotHookDirectoryExists(paths.CopilotHooks)
	if err != nil || !exists {
		return err
	}
	return os.RemoveAll(paths.CopilotHooks)
}

func copilotHookPaths(
	paths StorePaths,
	sessionID string,
	transcriptPath string,
) (string, string, error) {
	sessionKey, err := copilotHookKey("session_id", sessionID)
	if err != nil {
		return "", "", err
	}
	transcriptKey, err := copilotHookKey("transcript_path", transcriptPath)
	if err != nil {
		return "", "", err
	}
	sessionDir := filepath.Join(paths.CopilotHooks, sessionKey)
	return sessionDir, filepath.Join(sessionDir, transcriptKey), nil
}

func copilotHookKey(name, value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:]), nil
}

func ensureCopilotHookDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	exists, err := copilotHookDirectoryExists(path)
	if err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("%s was not created", path)
	}
	return os.Chmod(path, 0o700)
}

func copilotHookDirectoryExists(path string) (bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return false, fmt.Errorf("%s must be a directory and not a symbolic link", path)
	}
	return true, nil
}
