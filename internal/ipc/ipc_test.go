package ipc

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

func TestServeAcceptsEventsAndStops(t *testing.T) {
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "mews.sock")
	eventPath := filepath.Join(dir, "events.jsonl")

	errs := make(chan error, 1)
	go func() {
		errs <- Serve(socketPath, eventPath)
	}()

	waitForPing(t, socketPath)

	event := events.Event{
		Version:   1,
		Source:    "test",
		Status:    events.StatusDone,
		Timestamp: time.Now(),
	}
	if err := SendEvent(socketPath, event); err != nil {
		t.Fatalf("SendEvent returned error: %v", err)
	}

	got, err := store.ReadEvents(eventPath, 1)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != 1 || got[0].Status != events.StatusDone {
		t.Fatalf("stored events = %#v, want one done event", got)
	}

	if err := Stop(socketPath); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	select {
	case err := <-errs:
		if err != nil {
			t.Fatalf("Serve returned error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not stop")
	}
}

func waitForPing(t *testing.T, socketPath string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if err := Ping(socketPath); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("agent did not become available")
}
