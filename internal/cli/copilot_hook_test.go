package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCopilotHookSuppressesToolCallLifecycleEvents(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	const parentSessionID = "18f53f95-467a-4f95-9ad8-29201d612f6a"
	subagentPayload := `{
		"sessionId":"` + parentSessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/subagent.jsonl"
	}`
	runCopilotHookForTest(t, "subagentStart", subagentPayload)
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
	runCopilotHookForTest(t, "subagentStop", subagentPayload)

	mainPayload := `{
		"sessionId":"` + parentSessionID + `",
		"cwd":"/tmp/Mews",
		"transcriptPath":"/tmp/subagent.jsonl"
	}`
	runCopilotHookForTest(t, "agentStop", mainPayload)

	events := readHookEvents(t, home)
	if len(events) != 2 {
		t.Fatalf("event count = %d, want subagent and main completion events: %#v", len(events), events)
	}
	if events[0]["hook_event"] != "subagentStop" || events[0]["agent_scope"] != "subagent" {
		t.Fatalf("first event = %#v, want silent subagent completion", events[0])
	}
	if events[1]["hook_event"] != "agentStop" || events[1]["agent_scope"] != "main" {
		t.Fatalf("second event = %#v, want main completion", events[1])
	}
	for _, event := range events {
		sessionID, _ := event["session_id"].(string)
		if isCopilotToolCallSessionID(sessionID) {
			t.Fatalf("nested tool-call session reached presentation history: %#v", event)
		}
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
