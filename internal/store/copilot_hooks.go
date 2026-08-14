package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const copilotMainStopPending = "main-stop-pending"
const copilotHookStateDisabled = ".copilot-hooks-disabled"
const copilotSubagentLifetime = 24 * time.Hour

type copilotPendingStop struct {
	ID           string    `json:"id"`
	CompletionAt time.Time `json:"completion_at,omitempty"`
}

func StartCopilotSubagent(sessionID, transcriptPath string) error {
	return withCopilotHookSession(sessionID, func(sessionDir string) error {
		markerPath, err := copilotSubagentMarkerPath(sessionDir, transcriptPath)
		if err != nil {
			return err
		}
		return writeFileAtomic(markerPath, []byte("active\n"))
	})
}

func ProcessCopilotMainStop(
	sessionID string,
	deliverDeferred func() error,
	deliverCompletion func(completionID string, completionAt time.Time) error,
) (bool, error) {
	deferred := false
	err := withCopilotHookSession(sessionID, func(sessionDir string) error {
		active, err := activeCopilotSubagentCount(sessionDir)
		if err != nil {
			return err
		}
		if _, err := copilotPendingStopID(sessionDir); err != nil {
			return err
		}
		if active > 0 {
			deferred = true
			return deliverDeferred()
		}
		pending, err := prepareCopilotPendingCompletion(sessionDir)
		if err != nil {
			return err
		}
		if err := deliverCompletion(pending.ID, pending.CompletionAt); err != nil {
			return err
		}
		return os.Remove(filepath.Join(sessionDir, copilotMainStopPending))
	})
	return deferred, err
}

func CopilotHookStateDisabled() (bool, error) {
	paths, err := Paths()
	if err != nil {
		return false, err
	}
	_, err = os.Stat(filepath.Join(paths.AppSupport, copilotHookStateDisabled))
	if os.IsNotExist(err) {
		return false, nil
	}
	return err == nil, err
}

func ProcessCopilotSubagentStop(
	sessionID string,
	transcriptPath string,
	deliverCompletion func(completionID string, completionAt time.Time) error,
) (bool, error) {
	completeMain := false
	err := withCopilotHookSession(sessionID, func(sessionDir string) error {
		markerPath, err := copilotSubagentMarkerPath(sessionDir, transcriptPath)
		if err != nil {
			return err
		}
		if err := os.Remove(markerPath); err != nil && !os.IsNotExist(err) {
			return err
		}
		active, err := activeCopilotSubagentCount(sessionDir)
		if err != nil || active > 0 {
			return err
		}
		pending, err := prepareCopilotPendingCompletion(sessionDir)
		if err != nil || pending.ID == "" {
			return err
		}
		if err := deliverCompletion(pending.ID, pending.CompletionAt); err != nil {
			return err
		}
		completeMain = true
		return os.Remove(filepath.Join(sessionDir, copilotMainStopPending))
	})
	return completeMain, err
}

func CancelCopilotMainStop(sessionID string) error {
	return withCopilotHookSession(sessionID, func(sessionDir string) error {
		err := os.Remove(filepath.Join(sessionDir, copilotMainStopPending))
		if os.IsNotExist(err) {
			return nil
		}
		return err
	})
}

func ClearCopilotHookSession(sessionID string) error {
	return withCopilotHookSession(sessionID, os.RemoveAll)
}

func RemoveCopilotHookState() error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		return err
	}
	return withCopilotHookRootLock(paths, syscall.LOCK_EX, func() error {
		exists, err := copilotHookDirectoryExists(paths.CopilotHooks)
		if err != nil {
			return err
		}
		if exists {
			if err := os.RemoveAll(paths.CopilotHooks); err != nil {
				return err
			}
		}
		return writeFileAtomic(
			filepath.Join(paths.AppSupport, copilotHookStateDisabled),
			[]byte("disabled\n"),
		)
	})
}

func EnableCopilotHookState() error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		return err
	}
	return withCopilotHookRootLock(paths, syscall.LOCK_EX, func() error {
		err := os.Remove(filepath.Join(paths.AppSupport, copilotHookStateDisabled))
		if os.IsNotExist(err) {
			return nil
		}
		return err
	})
}

func withCopilotHookSession(
	sessionID string,
	operation func(sessionDir string) error,
) error {
	paths, err := Paths()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(paths.AppSupport, 0o700); err != nil {
		return err
	}
	return withCopilotHookRootLock(paths, syscall.LOCK_SH, func() error {
		if _, err := os.Stat(
			filepath.Join(paths.AppSupport, copilotHookStateDisabled),
		); err == nil {
			return fmt.Errorf("copilot hook state is disabled")
		} else if !os.IsNotExist(err) {
			return err
		}
		if err := ensureCopilotHookDirectory(paths.CopilotHooks); err != nil {
			return err
		}
		return withLockedCopilotSession(paths, sessionID, operation)
	})
}

func withLockedCopilotSession(
	paths StorePaths,
	sessionID string,
	operation func(sessionDir string) error,
) error {
	sessionKey, err := copilotHookKey("session_id", sessionID)
	if err != nil {
		return err
	}
	lock, err := os.OpenFile(
		filepath.Join(paths.CopilotHooks, sessionKey+".lock"),
		os.O_CREATE|os.O_RDWR,
		0o600,
	)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	sessionDir := filepath.Join(paths.CopilotHooks, sessionKey)
	if err := ensureCopilotHookDirectory(sessionDir); err != nil {
		return err
	}
	return operation(sessionDir)
}

func withCopilotHookRootLock(
	paths StorePaths,
	mode int,
	operation func() error,
) error {
	lock, err := os.OpenFile(
		filepath.Join(paths.AppSupport, ".copilot-hooks.lock"),
		os.O_CREATE|os.O_RDWR,
		0o600,
	)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), mode); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	return operation()
}

func copilotSubagentMarkerPath(sessionDir, transcriptPath string) (string, error) {
	transcriptKey, err := copilotHookKey("transcript_path", transcriptPath)
	if err != nil {
		return "", err
	}
	return filepath.Join(sessionDir, "active-"+transcriptKey), nil
}

func activeCopilotSubagentCount(sessionDir string) (int, error) {
	entries, err := os.ReadDir(sessionDir)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "active-") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return 0, err
		}
		if time.Since(info.ModTime()) > copilotSubagentLifetime {
			if err := os.Remove(filepath.Join(sessionDir, entry.Name())); err != nil {
				return 0, err
			}
			continue
		}
		count++
	}
	return count, nil
}

func copilotPendingStopID(sessionDir string) (string, error) {
	if existing, err := readCopilotPendingStop(sessionDir); err != nil || existing.ID != "" {
		return existing.ID, err
	}
	id, err := newEventID()
	if err != nil {
		return "", err
	}
	if err := writeCopilotPendingStop(
		sessionDir,
		copilotPendingStop{ID: id},
	); err != nil {
		return "", err
	}
	return id, nil
}

func prepareCopilotPendingCompletion(
	sessionDir string,
) (copilotPendingStop, error) {
	pending, err := readCopilotPendingStop(sessionDir)
	if err != nil || pending.ID == "" || !pending.CompletionAt.IsZero() {
		return pending, err
	}
	pending.CompletionAt = time.Now()
	if err := writeCopilotPendingStop(sessionDir, pending); err != nil {
		return copilotPendingStop{}, err
	}
	return pending, nil
}

func readCopilotPendingStop(sessionDir string) (copilotPendingStop, error) {
	data, err := os.ReadFile(filepath.Join(sessionDir, copilotMainStopPending))
	if os.IsNotExist(err) {
		return copilotPendingStop{}, nil
	}
	if err != nil {
		return copilotPendingStop{}, err
	}
	var pending copilotPendingStop
	if err := json.Unmarshal(data, &pending); err != nil {
		return copilotPendingStop{}, fmt.Errorf("invalid Copilot pending stop: %w", err)
	}
	decoded, err := hex.DecodeString(pending.ID)
	if err != nil || len(decoded) != 16 {
		return copilotPendingStop{}, fmt.Errorf("invalid Copilot pending stop identifier")
	}
	return pending, nil
}

func writeCopilotPendingStop(
	sessionDir string,
	pending copilotPendingStop,
) error {
	data, err := json.Marshal(pending)
	if err != nil {
		return err
	}
	return writeFileAtomic(
		filepath.Join(sessionDir, copilotMainStopPending),
		append(data, '\n'),
	)
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
