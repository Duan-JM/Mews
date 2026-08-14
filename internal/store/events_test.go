package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/events"
)

func TestAppendAndReadEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")

	first := events.Event{
		Version:   1,
		Source:    "test",
		Status:    events.StatusRunning,
		Timestamp: time.Now(),
	}
	second := events.Event{
		Version:   1,
		Source:    "test",
		Status:    events.StatusDone,
		Message:   "finished",
		Timestamp: time.Now(),
	}

	if err := AppendEvent(path, &first); err != nil {
		t.Fatalf("AppendEvent(first) returned error: %v", err)
	}
	if err := AppendEvent(path, &second); err != nil {
		t.Fatalf("AppendEvent(second) returned error: %v", err)
	}

	got, err := ReadEvents(path, 1)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ReadEvents returned %d events, want 1", len(got))
	}
	if got[0].Status != events.StatusDone {
		t.Fatalf("latest status = %q, want %q", got[0].Status, events.StatusDone)
	}
	if got[0].ID == "" {
		t.Fatal("stored event ID is empty")
	}
}

func TestReadEventsMissingFile(t *testing.T) {
	got, err := ReadEvents(filepath.Join(t.TempDir(), "missing.jsonl"), 10)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("ReadEvents returned %d events, want 0", len(got))
	}
}

func TestAppendEventCompactsOversizedLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	event := events.Event{
		Version:   1,
		Source:    "test",
		Status:    events.StatusRunning,
		Message:   strings.Repeat("x", 900),
		Timestamp: time.Now(),
	}
	line, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	line = append(line, '\n')
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	for fileSize := 0; fileSize < maxEventLogBytes; fileSize += len(line) {
		if _, err := file.Write(line); err != nil {
			file.Close()
			t.Fatal(err)
		}
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	event.Status = events.StatusDone
	event.Message = "latest"
	if err := AppendEvent(path, &event); err != nil {
		t.Fatalf("AppendEvent returned error: %v", err)
	}
	got, err := ReadEvents(path, retainedEvents+10)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != retainedEvents+1 {
		t.Fatalf("ReadEvents returned %d events, want %d", len(got), retainedEvents+1)
	}
	if got[len(got)-1].Status != events.StatusDone {
		t.Fatalf("latest status = %q, want done", got[len(got)-1].Status)
	}
}
