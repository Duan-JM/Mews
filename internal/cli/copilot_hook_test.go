package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Duan-JM/mews/internal/events"
	"github.com/Duan-JM/mews/internal/store"
)

func TestCopilotHookDefersMainCompletionUntilSubagentsStop(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const parentSessionID = "18f53f95-467a-4f95-9ad8-29201d612f6a"
	firstSubagent := `{
		"sessionId":"` + parentSessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/first-subagent.jsonl"
	}`
	secondSubagent := `{
		"sessionId":"` + parentSessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/second-subagent.jsonl"
	}`
	runCopilotHookForTest(t, "subagentStart", firstSubagent)
	runCopilotHookForTest(t, "subagentStart", secondSubagent)
	for _, nestedStopID := range []string{
		"call_qpS1YgQp6jkhN9x",
		"toolu_01M9aYrMjZk7wUp62AZM1Djw",
	} {
		runCopilotHookForTest(t, "agentStop", `{
			"sessionId":"`+nestedStopID+`",
			"cwd":"/tmp/Mews",
			"transcriptPath":null
		}`)
	}
	runCopilotHookForTest(t, "errorOccurred", `{
		"sessionId":"call_errorOccurred",
		"cwd":"/tmp/Mews",
		"recoverable":false,
		"error":{"message":"nested failure"}
	}`)
	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"`+parentSessionID+`",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/main.jsonl"
	}`)
	runCopilotHookForTest(t, "subagentStop", firstSubagent)

	events := readHookEvents(t, home)
	if len(events) != 2 {
		t.Fatalf("event count = %d, want running and first subagent stop: %#v", len(events), events)
	}
	if events[0]["hook_event"] != "subagentRunning" ||
		events[0]["status"] != "running" ||
		events[0]["agent_scope"] != "main" {
		t.Fatalf("first event = %#v, want primary subagent-running state", events[0])
	}
	if events[0]["message"] != "copilot subagents running: Mews" {
		t.Fatalf("subagent-running message = %#v", events[0]["message"])
	}
	if events[1]["hook_event"] != "subagentStop" || events[1]["agent_scope"] != "subagent" {
		t.Fatalf("second event = %#v, want silent first subagent completion", events[1])
	}

	runCopilotHookForTest(t, "subagentStop", secondSubagent)
	events = readHookEvents(t, home)
	if len(events) != 4 {
		t.Fatalf("event count = %d, want final subagent and deferred main completion: %#v", len(events), events)
	}
	if events[2]["hook_event"] != "subagentStop" || events[2]["agent_scope"] != "subagent" {
		t.Fatalf("third event = %#v, want silent final subagent completion", events[2])
	}
	if events[3]["hook_event"] != "agentStop" ||
		events[3]["status"] != "done" ||
		events[3]["agent_scope"] != "main" {
		t.Fatalf("fourth event = %#v, want deferred main completion", events[3])
	}
	for _, event := range events {
		sessionID, _ := event["session_id"].(string)
		if isCopilotToolCallSessionID(sessionID) {
			t.Fatalf("nested tool-call session reached presentation history: %#v", event)
		}
	}
}

func TestCopilotHookPromptSubmissionCancelsDeferredCompletion(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	subagentPayload := `{
		"sessionId":"` + sessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/subagent.jsonl"
	}`
	runCopilotHookForTest(t, "subagentStart", subagentPayload)
	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"`+sessionID+`",
		"cwd":"/tmp/Mews"
	}`)
	runCopilotHookForTest(t, "userPromptSubmitted", `{
		"sessionId":"`+sessionID+`",
		"cwd":"/tmp/Mews",
		"prompt":"continue"
	}`)
	runCopilotHookForTest(t, "subagentStop", subagentPayload)

	events := readHookEvents(t, home)
	if len(events) != 3 {
		t.Fatalf("event count = %d, want subagent-running, resumed, and subagent stop: %#v", len(events), events)
	}
	if events[1]["hook_event"] != "userPromptSubmitted" || events[1]["status"] != "running" {
		t.Fatalf("second event = %#v, want resumed main turn", events[1])
	}
	if events[2]["agent_scope"] != "subagent" {
		t.Fatalf("final event = %#v, want no stale main completion", events[2])
	}
}

func TestCopilotHookRestoresDeferredCompletionAfterEventFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	subagentPayload := `{
		"sessionId":"` + sessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/subagent.jsonl"
	}`
	runCopilotHookForTest(t, "subagentStart", subagentPayload)
	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"`+sessionID+`",
		"cwd":"/tmp/Mews"
	}`)

	configPath := filepath.Join(home, "Library", "Application Support", "Mews", "config.json")
	if err := os.WriteFile(configPath, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"hook", "copilot", "subagentStop"},
		strings.NewReader(subagentPayload),
		&stdout,
		&stderr,
	)
	if code != 2 || !strings.Contains(stderr.String(), "Invalid Copilot hook payload") {
		t.Fatalf("failed subagentStop returned %d, stderr: %s", code, stderr.String())
	}
	if err := os.Remove(configPath); err != nil {
		t.Fatal(err)
	}

	runCopilotHookForTest(t, "subagentStop", subagentPayload)
	events := readHookEvents(t, home)
	if len(events) != 3 ||
		events[2]["hook_event"] != "agentStop" ||
		events[2]["status"] != "done" {
		t.Fatalf("events after retry = %#v, want restored main completion", events)
	}
}

func TestCopilotHookReusesCompletionIDAcrossHookRetries(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const sessionID = "session-123"
	subagentPayload := `{
		"sessionId":"` + sessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/subagent.jsonl"
	}`
	runCopilotHookForTest(t, "subagentStart", subagentPayload)
	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"`+sessionID+`",
		"cwd":"/tmp/Mews"
	}`)

	originalDeliver := deliverEventFn
	t.Cleanup(func() { deliverEventFn = originalDeliver })
	var completionIDs []string
	failCompletion := true
	deliverEventFn = func(
		_ store.StorePaths,
		event *events.Event,
		_ io.Writer,
	) error {
		if event.HookEvent != "agentStop" {
			return nil
		}
		completionIDs = append(completionIDs, event.ID)
		if failCompletion {
			failCompletion = false
			return errors.New("connection closed after persistence")
		}
		return nil
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"hook", "copilot", "subagentStop"},
		strings.NewReader(subagentPayload),
		&stdout,
		&stderr,
	)
	if code != 1 {
		t.Fatalf("first subagentStop returned %d, want delivery failure: %s", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	code = Run(
		[]string{"hook", "copilot", "agentStop"},
		strings.NewReader(`{
			"sessionId":"`+sessionID+`",
			"cwd":"/tmp/Mews"
		}`),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("retried agentStop returned %d: %s", code, stderr.String())
	}
	if len(completionIDs) != 2 ||
		completionIDs[0] == "" ||
		completionIDs[0] != completionIDs[1] {
		t.Fatalf("completion IDs = %#v, want one stable ID across retry", completionIDs)
	}
}

func TestCopilotHookRecordsPromptSubmissionAsRunningWithoutPromptText(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const prompt = "private prompt that must not be persisted"
	runCopilotHookForTest(t, "userPromptSubmitted", `{
		"sessionId":"18f53f95-467a-4f95-9ad8-29201d612f6a",
		"cwd":"/tmp/Mews",
		"prompt":"`+prompt+`"
	}`)

	path := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(prompt)) {
		t.Fatal("prompt submission persisted prompt text without task-title opt-in")
	}
	events := readHookEvents(t, home)
	if len(events) != 1 ||
		events[0]["hook_event"] != "userPromptSubmitted" ||
		events[0]["status"] != "running" ||
		events[0]["agent_scope"] != "main" {
		t.Fatalf("events = %#v, want one primary running transition", events)
	}
}

func TestCopilotHookSuppressesNamedSubagentWithoutLifecycleMarker(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"session-123",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/general-purpose.jsonl",
		"agentName":"general-purpose"
	}`)

	path := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("named subagent wrote an event log: %v", err)
	}
}

func TestCopilotHookAcceptsMainStopWithoutTranscriptPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	runCopilotHookForTest(t, "agentStop", `{
		"sessionId":"session-123",
		"cwd":"/tmp/Mews"
	}`)

	events := readHookEvents(t, home)
	if len(events) != 1 || events[0]["agent_scope"] != "main" {
		t.Fatalf("events = %#v, want one main-agent completion", events)
	}
}

func TestCopilotHookRecordsRecoverableErrors(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	runCopilotHookForTest(t, "errorOccurred", `{
		"sessionId":"session-123",
		"cwd":"/tmp/Mews",
		"recoverable":true,
		"error":{"message":"temporary failure"}
	}`)

	events := readHookEvents(t, home)
	if len(events) != 1 {
		t.Fatalf("event count = %d, want 1", len(events))
	}
	recoverable, ok := events[0]["recoverable"].(bool)
	if !ok || !recoverable {
		t.Fatalf("recoverable = %#v, want true", events[0]["recoverable"])
	}
}

func runCopilotHookForTest(t *testing.T, event, payload string) {
	t.Helper()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := Run(
		[]string{"hook", "copilot", event},
		strings.NewReader(payload),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("Copilot %s hook returned %d, stderr: %s", event, code, stderr.String())
	}
}

func readHookEvents(t *testing.T, home string) []map[string]any {
	t.Helper()

	path := filepath.Join(home, "Library", "Application Support", "Mews", "events.jsonl")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read event log: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	events := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("decode event %q: %v", line, err)
		}
		events = append(events, event)
	}
	return events
}
