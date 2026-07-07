package store

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"

	"github.com/Duan-JM/mews/internal/events"
)

func AppendEvent(path string, event events.Event) error {
	if err := event.Validate(); err != nil {
		return err
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	return encoder.Encode(event)
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
