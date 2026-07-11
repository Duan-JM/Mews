package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/integrations"
	"github.com/Duan-JM/mews/internal/store"
)

func TestMain(m *testing.M) {
	_ = os.Setenv("MEWS_TESTING", "1")
	os.Exit(m.Run())
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
	originalNotifier := sendNotification
	t.Cleanup(func() { sendNotification = originalNotifier })
	var notified []events.Status
	sendNotification = func(event events.Event) error {
		notified = append(notified, event.Status)
		return nil
	}

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
	if len(notified) != 2 || notified[1] != events.StatusDone {
		t.Fatalf("notified statuses = %q, want running and done delivery", notified)
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
	deliverEventFn = func(store.StorePaths, events.Event, io.Writer) error {
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

func TestResetRequiresUndoWhenIntegrationsAreConfigured(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var setupOut, setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}

	var resetOut, resetErr bytes.Buffer
	if code := Run([]string{"reset", "--yes"}, strings.NewReader(""), &resetOut, &resetErr); code != 1 {
		t.Fatalf("reset returned %d, want 1", code)
	}
	if !strings.Contains(resetErr.String(), "Run `mw undo`") {
		t.Fatalf("reset did not explain required undo: %q", resetErr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if _, err := os.Stat(hookPath); err != nil {
		t.Fatalf("reset removed integration before undo: %v", err)
	}
}

func TestSetupCanBeRepeatedWithoutLosingUndoOwnership(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	for attempt := 0; attempt < 2; attempt++ {
		var stdout, stderr bytes.Buffer
		if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
			t.Fatalf("setup attempt %d returned %d, stderr: %s", attempt+1, code, stderr.String())
		}
	}
	var undoOut, undoErr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &undoOut, &undoErr); code != 0 {
		t.Fatalf("undo returned %d, stderr: %s", code, undoErr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("Copilot hook remains after repeated setup and undo: %v", err)
	}
}

func TestUndoUsesIntegrationStateWithoutSetupState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	if _, err := integrations.InstallAll("/opt/mews/bin/mw"); err != nil {
		t.Fatalf("InstallAll returned error: %v", err)
	}

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("undo returned %d, stderr: %s", code, stderr.String())
	}
	if _, configured, err := store.LoadIntegrationState(); err != nil || configured {
		t.Fatalf("integration state remains: configured=%v err=%v", configured, err)
	}
}

func TestLegacyUndoUsesRecordedCopilotPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	firstHome := filepath.Join(home, "copilot-a")
	t.Setenv("COPILOT_HOME", firstHome)
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	hookPath := filepath.Join(firstHome, "hooks", "mews.json")
	if err := os.MkdirAll(filepath.Dir(hookPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hookPath, legacyCopilotHookJSON(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSetupState(store.SetupState{
		Version:     1,
		SetupAt:     time.Now(),
		Agent:       "not packaged yet",
		Copilot:     "hooks installed",
		CopilotHook: hookPath,
		Claude:      "hooks not installed",
		UndoReady:   true,
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot-b"))
	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("legacy undo returned %d, stderr: %s", code, stderr.String())
	}
	if _, err := os.Stat(hookPath); !os.IsNotExist(err) {
		t.Fatalf("recorded legacy Copilot hook remains: %v", err)
	}
}

func TestUndoRefusesWhenCurrentIntegrationStateIsMissing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var setupOut, setupErr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &setupOut, &setupErr); code != 0 {
		t.Fatalf("setup returned %d, stderr: %s", code, setupErr.String())
	}
	if err := store.RemoveIntegrationState(); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"undo"}, strings.NewReader(""), &stdout, &stderr); code != 1 {
		t.Fatalf("undo returned %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "integration rollback state is missing") {
		t.Fatalf("undo did not explain missing rollback state: %q", stderr.String())
	}
	if _, configured, err := store.LoadSetupState(); err != nil || !configured {
		t.Fatalf("setup state was removed: configured=%v err=%v", configured, err)
	}
	for _, path := range []string{
		filepath.Join(home, "copilot", "hooks", "mews.json"),
		filepath.Join(home, "claude", "settings.json"),
		filepath.Join(home, "codex", "config.toml"),
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("integration was changed after failed undo: %s: %v", path, err)
		}
	}
}

func TestSetupMigratesRecordedLegacyCopilotHook(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("COPILOT_HOME", filepath.Join(home, "copilot"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))

	var stdout, stderr bytes.Buffer
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("initial setup returned %d, stderr: %s", code, stderr.String())
	}
	hookPath, _ := integrations.CopilotHookPath()
	if err := os.WriteFile(hookPath, legacyCopilotHookJSON(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.RemoveIntegrationState(); err != nil {
		t.Fatal(err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := Run([]string{"setup", "--yes"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("migration setup returned %d, stderr: %s", code, stderr.String())
	}
	data, err := os.ReadFile(hookPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "MEWS_MANAGED_INTEGRATION") {
		t.Fatalf("legacy hook was not migrated: %s", data)
	}
}

func legacyCopilotHookJSON() []byte {
	type hook struct {
		Type       string `json:"type"`
		Bash       string `json:"bash"`
		TimeoutSec int    `json:"timeoutSec"`
	}
	config := struct {
		Version int               `json:"version"`
		Hooks   map[string][]hook `json:"hooks"`
	}{
		Version: 1,
		Hooks:   make(map[string][]hook),
	}
	events := map[string][2]string{
		"agentStop":     {"done", "Copilot agent stopped"},
		"sessionEnd":    {"idle", "Copilot session ended"},
		"errorOccurred": {"failed", "Copilot error occurred"},
	}
	for event, values := range events {
		parts := []string{
			"/legacy/mw", "notify",
			"--source", "copilot",
			"--hook-event", event,
			"--status", values[0],
			"--message", values[1],
		}
		for index, part := range parts {
			parts[index] = strconv.Quote(part)
		}
		config.Hooks[event] = []hook{{
			Type:       "command",
			Bash:       strings.Join(parts, " ") + " >/dev/null",
			TimeoutSec: 5,
		}}
	}
	data, _ := json.Marshal(config)
	return data
}
