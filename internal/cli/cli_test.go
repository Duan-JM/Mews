package cli

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

func TestRunCommandRecordsSuccess(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	code := Run([]string{"run", "--", "sh", "-c", "exit 0"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("Run returned %d, want 0; stderr=%q", code, stderr.String())
	}

	paths, err := store.Paths()
	if err != nil {
		t.Fatalf("Paths returned error: %v", err)
	}
	got, err := store.ReadEvents(paths.Events, 2)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadEvents returned %d events, want 2", len(got))
	}
	if got[0].Status != events.StatusRunning || got[1].Status != events.StatusDone {
		t.Fatalf("statuses = %q, %q; want running, done", got[0].Status, got[1].Status)
	}
}

func TestRunCommandRecordsFailureExitCode(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	code := Run([]string{"run", "--", "sh", "-c", "exit 7"}, &stdout, &stderr)
	if code != 7 {
		t.Fatalf("Run returned %d, want 7; stderr=%q", code, stderr.String())
	}

	paths, err := store.Paths()
	if err != nil {
		t.Fatalf("Paths returned error: %v", err)
	}
	got, err := store.ReadEvents(paths.Events, 2)
	if err != nil {
		t.Fatalf("ReadEvents returned error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadEvents returned %d events, want 2", len(got))
	}
	if got[0].Status != events.StatusRunning || got[1].Status != events.StatusFailed {
		t.Fatalf("statuses = %q, %q; want running, failed", got[0].Status, got[1].Status)
	}
}

func TestCommandEventUsesWorkingDirectoryName(t *testing.T) {
	event := commandEvent(events.StatusDone, "echo ok", filepath.Join(string(filepath.Separator), "tmp", "mews"), 123)
	if event.Source != "runner" {
		t.Fatalf("source = %q, want runner", event.Source)
	}
	if event.Project != "mews" {
		t.Fatalf("project = %q, want mews", event.Project)
	}
	if event.PID != 123 {
		t.Fatalf("pid = %d, want 123", event.PID)
	}
}
