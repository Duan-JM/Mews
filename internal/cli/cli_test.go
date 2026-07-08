package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

func TestRunCommandForwardsStdin(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := Run(
		[]string{"run", "--", "sh", "-c", `read line; printf 'got:%s\n' "$line"`},
		strings.NewReader("hello\n"),
		&stdout,
		&stderr,
	)

	if code != 0 {
		t.Fatalf("Run returned %d, stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "got:hello\n") {
		t.Fatalf("stdout did not include forwarded stdin output: %q", stdout.String())
	}
}

func TestRunCommandRecordsSuccess(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout, stderr bytes.Buffer
	code := Run([]string{"run", "--", "sh", "-c", "exit 0"}, strings.NewReader(""), &stdout, &stderr)
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
	code := Run([]string{"run", "--", "sh", "-c", "exit 7"}, strings.NewReader(""), &stdout, &stderr)
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

func TestStartRequiresSetup(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run([]string{"start"}, strings.NewReader(""), &stdout, &stderr)

	if code != 1 {
		t.Fatalf("Run returned %d, want 1", code)
	}
	if !strings.Contains(stdout.String(), "Mews is not set up yet.") {
		t.Fatalf("stdout did not explain setup requirement: %q", stdout.String())
	}
}

func TestSetupYesRecordsStateAndUndoRemovesIt(t *testing.T) {
	home := t.TempDir()
	copilotHome := filepath.Join(home, ".copilot")
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", copilotHome)

	var setupOut bytes.Buffer
	var setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}
	hookPath := filepath.Join(copilotHome, "hooks", "mews.json")
	hookData, err := os.ReadFile(hookPath)
	if err != nil {
		t.Fatalf("setup did not write Copilot hook: %v", err)
	}
	if !strings.Contains(string(hookData), "agentStop") ||
		!strings.Contains(string(hookData), "notify") ||
		!strings.Contains(string(hookData), "copilot") {
		t.Fatalf("hook file does not include expected Copilot hook command: %s", string(hookData))
	}

	var undoOut bytes.Buffer
	var undoErr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &undoOut, &undoErr); code != 0 {
		t.Fatalf("undo returned %d, stderr: %s", code, undoErr.String())
	}
	if !strings.Contains(undoOut.String(), "Removed Mews setup state.") {
		t.Fatalf("stdout did not describe undo: %q", undoOut.String())
	}
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("undo did not remove Copilot hook, stat err: %v", err)
	}
}

func TestNotifyWritesEventLog(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"notify", "--source", "copilot", "--status", "done", "--message", "Agent stopped"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)

	if code != 0 {
		t.Fatalf("notify returned %d, stderr: %s", code, stderr.String())
	}
	eventPath := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	data, err := os.ReadFile(eventPath)
	if err != nil {
		t.Fatalf("notify did not write event log: %v", err)
	}
	if !strings.Contains(string(data), `"source":"copilot"`) || !strings.Contains(string(data), `"status":"done"`) {
		t.Fatalf("event log did not include expected event: %s", string(data))
	}
}

func TestNotifyFromHookAddsSafeContextWithoutTaskTitleByDefault(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	payload := `{"cwd":"/tmp/Mews","session_id":"abc123","prompt":"secret task details"}`
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"notify", "--source", "copilot", "--hook-event", "agentStop", "--status", "done"},
		strings.NewReader(payload),
		&stdout,
		&stderr,
	)

	if code != 0 {
		t.Fatalf("notify returned %d, stderr: %s", code, stderr.String())
	}
	eventPath := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	data, err := os.ReadFile(eventPath)
	if err != nil {
		t.Fatalf("notify did not write event log: %v", err)
	}
	content := string(data)
	for _, want := range []string{`"hook_event":"agentStop"`, `"session_id":"abc123"`, `"project":"Mews"`, `"cwd":"/tmp/Mews"`, `"message":"copilot done: Mews"`} {
		if !strings.Contains(content, want) {
			t.Fatalf("event log missing %s: %s", want, content)
		}
	}
	if strings.Contains(content, "secret task details") || strings.Contains(content, "task_title") {
		t.Fatalf("event log captured task title without opt-in: %s", content)
	}
}

func TestNotifyFromHookIncludesTruncatedTaskTitleWhenEnabled(t *testing.T) {
	home := t.TempDir()
	copilotHome := filepath.Join(home, ".copilot")
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", copilotHome)

	var setupOut bytes.Buffer
	var setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes", "--include-task-title"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}

	payload := `{"cwd":"/tmp/Mews","sessionId":"abc123","prompt":"fix the doctor command so users can see exactly which integration is broken and why"}`
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"notify", "--source", "copilot", "--hook-event", "agentStop", "--status", "done"},
		strings.NewReader(payload),
		&stdout,
		&stderr,
	)

	if code != 0 {
		t.Fatalf("notify returned %d, stderr: %s", code, stderr.String())
	}
	eventPath := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	data, err := os.ReadFile(eventPath)
	if err != nil {
		t.Fatalf("notify did not write event log: %v", err)
	}
	content := string(data)
	if !strings.Contains(content, `"task_title":"fix the doctor command`) {
		t.Fatalf("event log did not include task title after opt-in: %s", content)
	}
	if !strings.Contains(content, `"message":"copilot done: Mews - fix the doctor command`) {
		t.Fatalf("event log did not include task title in message: %s", content)
	}
}
