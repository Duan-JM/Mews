package cli

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

type bootstrapExitError int

func (e bootstrapExitError) Error() string {
	return fmt.Sprintf("exit status %d", e)
}

func (e bootstrapExitError) ExitCode() int {
	return int(e)
}

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

func TestRunCommandTruncatesLongEventMessage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	longArgument := strings.Repeat("x", 2000)
	var stdout, stderr bytes.Buffer
	code := Run(
		[]string{"run", "--", "sh", "-c", "exit 0", longArgument},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("Run returned %d, stderr: %s", code, stderr.String())
	}
	paths, err := store.Paths()
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.ReadEvents(paths.Events, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || len([]rune(got[1].Message)) > 1024 {
		t.Fatalf("long command event was not safely truncated: %#v", got)
	}
}

func TestRunCommandTerminatesProcessGroupWhenEventDeliveryFails(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	originalDeliver := deliverEventFn
	t.Cleanup(func() { deliverEventFn = originalDeliver })
	deliverEventFn = func(store.StorePaths, *events.Event, io.Writer) error {
		return errors.New("delivery failed")
	}

	marker := filepath.Join(t.TempDir(), "finished")
	var stdout, stderr bytes.Buffer
	code := Run(
		[]string{"run", "--", "sh", "-c", "sleep 1; touch \"$1\"", "sh", marker},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != 1 {
		t.Fatalf("Run returned %d, want 1", code)
	}
	time.Sleep(1200 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("command continued after delivery failure: %v", err)
	}
}

func TestBootstrapWithRetryHandlesLaunchdInputOutputRace(t *testing.T) {
	originalBootstrap := bootstrapLaunchAgent
	originalDelay := bootstrapRetryDelay
	t.Cleanup(func() {
		bootstrapLaunchAgent = originalBootstrap
		bootstrapRetryDelay = originalDelay
	})

	calls := 0
	bootstrapRetryDelay = 0
	bootstrapLaunchAgent = func() error {
		calls++
		if calls == 1 {
			return bootstrapExitError(5)
		}
		return nil
	}

	if err := bootstrapWithRetry(time.Second); err != nil {
		t.Fatalf("bootstrapWithRetry returned error: %v", err)
	}
	if calls != 2 {
		t.Fatalf("bootstrap calls = %d, want 2", calls)
	}
}

func TestBootstrapWithRetryDoesNotHidePermanentFailure(t *testing.T) {
	originalBootstrap := bootstrapLaunchAgent
	t.Cleanup(func() { bootstrapLaunchAgent = originalBootstrap })

	calls := 0
	bootstrapLaunchAgent = func() error {
		calls++
		return errors.New("Bootstrap failed: 125: Domain does not support specified action")
	}

	err := bootstrapWithRetry(time.Second)
	if err == nil || !strings.Contains(err.Error(), "Domain does not support") {
		t.Fatalf("bootstrapWithRetry error = %v", err)
	}
	if calls != 1 {
		t.Fatalf("bootstrap calls = %d, want 1", calls)
	}
}

func TestWaitForAgentStopAcceptsClosingSocketEOF(t *testing.T) {
	originalPing := pingAgent
	t.Cleanup(func() { pingAgent = originalPing })
	pingAgent = func(string) error {
		return io.EOF
	}

	if err := waitForAgentStop("/tmp/mews.sock", time.Second); err != nil {
		t.Fatalf("waitForAgentStop returned error: %v", err)
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
		!strings.Contains(string(hookData), "subagentStop") ||
		!strings.Contains(string(hookData), "hook") ||
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

func TestHistoryPrintsSessionReturnCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var notifyOut, notifyErr bytes.Buffer
	code := Run(
		[]string{
			"notify",
			"--source", "copilot",
			"--status", "done",
			"--session", "session-123",
			"--project", "Mews",
			"--message", "Agent stopped",
		},
		strings.NewReader(""),
		&notifyOut,
		&notifyErr,
	)
	if code != 0 {
		t.Fatalf("notify returned %d, stderr: %s", code, notifyErr.String())
	}

	var historyOut, historyErr bytes.Buffer
	code = Run([]string{"history"}, strings.NewReader(""), &historyOut, &historyErr)
	if code != 0 {
		t.Fatalf("history returned %d, stderr: %s", code, historyErr.String())
	}
	if !strings.Contains(historyOut.String(), "return: mw history --session 'session-123'") {
		t.Fatalf("history did not include return command: %q", historyOut.String())
	}
}

func TestSessionReturnCommandQuotesSingleQuotes(t *testing.T) {
	want := "mw history --session 'session'\\''1'"
	if got := sessionReturnCommand("session'1"); got != want {
		t.Fatalf("sessionReturnCommand() = %q, want %q", got, want)
	}
}

func TestHistoryFiltersBySession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	for _, session := range []string{"target-session", "other-session"} {
		var stdout, stderr bytes.Buffer
		code := Run(
			[]string{
				"notify",
				"--source", "copilot",
				"--status", "done",
				"--session", session,
				"--message", session,
			},
			strings.NewReader(""),
			&stdout,
			&stderr,
		)
		if code != 0 {
			t.Fatalf("notify %s returned %d, stderr: %s", session, code, stderr.String())
		}
	}

	var historyOut, historyErr bytes.Buffer
	code := Run([]string{"history", "--session", "target-session"}, strings.NewReader(""), &historyOut, &historyErr)
	if code != 0 {
		t.Fatalf("history returned %d, stderr: %s", code, historyErr.String())
	}
	if !strings.Contains(historyOut.String(), "target-session") {
		t.Fatalf("history did not include target session: %q", historyOut.String())
	}
	if strings.Contains(historyOut.String(), "other-session") {
		t.Fatalf("history included a different session: %q", historyOut.String())
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
