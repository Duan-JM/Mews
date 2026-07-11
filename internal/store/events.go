package store

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"

	"github.com/Duan-JM/mews/internal/events"
)

const (
	maxEventLogBytes = 5 << 20
	retainedEvents   = 2000
)

func AppendEvent(path string, event events.Event) error {
	if event.ID == "" {
		id, err := newEventID()
		if err != nil {
			return err
		}
		event.ID = id
	}
	if err := event.Validate(); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	if info, err := os.Stat(path); err != nil && !os.IsNotExist(err) {
		return err
	} else if err == nil && info.Size() >= maxEventLogBytes {
		if err := compactEvents(path); err != nil {
			return err
		}
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	encoder := json.NewEncoder(file)
	if err := encoder.Encode(event); err != nil {
		return err
	}
	return file.Sync()
}

func newEventID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(id[:]), nil
}

func compactEvents(path string) error {
	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()

	scanner := bufio.NewScanner(source)
	scanner.Buffer(make([]byte, 64*1024), 2<<20)
	lines := make([][]byte, 0, retainedEvents)
	for scanner.Scan() {
		line := append([]byte(nil), scanner.Bytes()...)
		lines = append(lines, line)
		if len(lines) > retainedEvents {
			lines = lines[1:]
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}

	temp, err := os.CreateTemp(filepath.Dir(path), ".events-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	for _, line := range lines {
		if _, err := temp.Write(line); err != nil {
			temp.Close()
			return err
		}
		if _, err := temp.Write([]byte{'\n'}); err != nil {
			temp.Close()
			return err
		}
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

func ReadEvents(path string, limit int) ([]events.Event, error) {
	if limit <= 0 {
		return nil, errors.New("limit must be positive")
	}

	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var result []events.Event
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var event events.Event
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return nil, err
		}
		result = append(result, event)
		if len(result) > limit {
			result = result[1:]
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return result, nil
}
