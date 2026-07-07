package store

import (
	"path/filepath"
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

	if err := AppendEvent(path, first); err != nil {
		t.Fatalf("AppendEvent(first) returned error: %v", err)
	}
	if err := AppendEvent(path, second); err != nil {
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
